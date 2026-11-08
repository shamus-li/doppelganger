import AppKit
import Observation
import ServiceManagement
import UserNotifications

enum MountState: Equatable {
    case setup, stopped, mounted, connecting, reconnecting, offline, error
}

/// What the menu shows for one mount.
struct MountInfo: Identifiable, Equatable {
    var config: MountConfig
    var id: MountConfig.ID { config.id }
    var state: MountState = .reconnecting
    var detail: String?
    /// When the server stopped answering.
    var offlineSince: Date?
}

/// Everything gathered in one poll, off the main actor.
private struct Snapshot: Sendable {
    var configs: [MountConfig] = []
    var mountTable = MountTable()
    /// Whether each mount's folder is set up, checked here because it can mean a look at the folder.
    var ready: [UUID: Bool] = [:]
    var outdated: Set<UUID> = []
    var busy: Set<UUID> = []
    var reconnecting: Set<UUID> = []
    var failures: [UUID: String] = [:]
    var fuseMissing = false
    /// The saved list is damaged or gone, as opposed to never having been saved.
    var listLost = false
    var phases: [UUID: ServiceStatus.Phase] = [:]
    var serviceStatus: SMAppService.Status = .notRegistered
    var logErrors: [LogLine]?
    /// The service is registered but hasn't reported for a while, so what the menu shows may be stale.
    var serviceStuck = false

    static func take(withLog: Bool) -> Snapshot {
        var s = Snapshot()
        let saved = MountStore.saved()
        s.configs = saved ?? []
        s.mountTable = MountTable.current()
        s.ready = Dictionary(uniqueKeysWithValues: s.configs.map { ($0.id, FolderSetup.isReady($0, mounts: s.mountTable)) })
        let status = ServiceStatus.load()
        s.phases = status.phases
        s.outdated = status.outdated
        s.busy = status.busy
        s.reconnecting = status.reconnecting
        s.failures = status.failures
        s.fuseMissing = MacFUSE.current() == .missing
        s.listLost = saved == nil && (FileManager.default.fileExists(atPath: MountStore.file()) || !status.phases.isEmpty)
        s.serviceStatus = Service.agent.status
        // It reports every 5 s; a check of an unreachable server or a restart can delay that by ~15 s.
        if s.serviceStatus == .enabled, let saved = status.savedAt { s.serviceStuck = Date().timeIntervalSince(saved) > 30 }
        if withLog { s.logErrors = LogReader.unresolvedErrors(in: LogReader.tail(of: s.configs)) }
        return s
    }
}

/// Per-mount bookkeeping between polls.
private final class MountTracker {
    var notMountedSince: Date?
    var offlineSince: Date?
    /// When it stopped being available; a short outage isn't worth telling the user about.
    var downSince: Date?
    var everMounted = false
    var dropNotified = false
    /// When Reconnect was chosen: what it causes in the next minute doesn't notify.
    var reconnectedAt: Date?
}

@MainActor @Observable
final class Monitor {
    private(set) var mounts: [MountInfo] = []
    private(set) var errorsLastHour = 0
    private(set) var working = false
    private(set) var actionError: String?
    /// The background service can't run until the user allows it.
    private(set) var serviceNeedsApproval = false
    private(set) var serviceStuck = false
    private(set) var fuseMissing = false
    private(set) var listLost = false
    /// The /home change waiting for its helper to be allowed and run.
    private(set) var pendingChange: FolderSetup.Change?
    private(set) var setupNeeded = false
    private(set) var setupDetail: String?

    /// Something on the Setup page has to be done before the mounts can work.
    var setupIncomplete: Bool { setupNeeded || fuseMissing || serviceNeedsApproval }

    /// The state the menu bar icon shows: whatever most needs attention.
    var overallState: MountState {
        let states = mounts.map(\.state)
        for state in [MountState.error, .setup, .offline, .reconnecting, .connecting, .mounted] where states.contains(state) {
            return state
        }
        return serviceNeedsApproval ? .error : .stopped
    }

    /// True while the menu is open, which makes polling faster.
    var panelOpen = false {
        didSet { if panelOpen { sleeper?.cancel() } }
    }

    @ObservationIgnored private var lastLog = Date.distantPast
    @ObservationIgnored private var lastLogErrors: [UUID: String] = [:]
    @ObservationIgnored private var trackers: [UUID: MountTracker] = [:]
    @ObservationIgnored private var sleeper: Task<Void, Never>?
    @ObservationIgnored private var wokeAt = Date.distantPast
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Mounts already asked about being in use, until they stop being in use.
    @ObservationIgnored private var askedBusy = Set<UUID>()

    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wokeAt = Date() }
            Service.wake()
        }
        Task {
            do { try await Service.updateIfChanged() } catch { actionError = error.localizedDescription }
            await loop()
        }
    }

    private func loop() async {
        while true {
            await refresh()
            let interval: Duration = panelOpen ? .seconds(1) : .seconds(10)
            let sleep = Task { _ = try? await Task.sleep(for: interval) }
            sleeper = sleep
            await sleep.value
        }
    }

    func refresh() async {
        let now = Date()
        // Reading the logs costs more than the rest, so it runs less often.
        let logDue = now.timeIntervalSince(lastLog) >= (panelOpen ? 2 : 60)
        if logDue { lastLog = now }
        let snapshot = await Task.detached { Snapshot.take(withLog: logDue) }.value
        apply(snapshot, at: Date())
    }

    private func apply(_ s: Snapshot, at now: Date) {
        if let errors = s.logErrors {
            errorsLastHour = errors.count
            lastLogErrors = Dictionary(errors.map { ($0.mountID, LogReader.message(ofLogLine: $0.text)) }) { $1 }
        }
        // Everything looks stale or down for a moment after sleep, and it's expected.
        let justWoke = now.timeIntervalSince(wokeAt) < 30
        fuseMissing = s.fuseMissing
        listLost = s.listLost
        serviceStuck = s.serviceStuck && !justWoke
        setupNeeded = s.ready.values.contains(false)

        // The service is registered once and stays registered; each mount's settings steer it.
        if !Service.isRegistered(s.serviceStatus), pendingChange == nil, !working {
            do { try Service.register() } catch { actionError = error.localizedDescription }
        }
        serviceNeedsApproval = s.serviceStatus == .requiresApproval

        if let change = pendingChange {
            track(change)
        }

        trackers = trackers.filter { id, _ in s.configs.contains { $0.id == id } }
        var events: [(config: MountConfig, event: Event, detail: String?)] = []
        let infos = s.configs.map { config in
            let tracker = trackers[config.id] ?? MountTracker()
            trackers[config.id] = tracker
            let info = info(for: config, tracker: tracker, snapshot: s, now: now, justWoke: justWoke)
            if justWoke {
                tracker.downSince = nil
            } else if let previous = mounts.first(where: { $0.id == config.id })?.state,
               let event = transition(from: previous, to: info.state, tracker: tracker, now: now) {
                events.append((config, event, info.detail))
            }
            return info
        }
        mounts = infos
        askedBusy.formIntersection(s.busy)
        for id in s.busy.subtracting(askedBusy) {
            guard let config = s.configs.first(where: { $0.id == id }) else { continue }
            askedBusy.insert(id)
            Task { self.askToUnmount(config) }
        }
        // Mounts on one server usually drop together: one notification per server, which the next
        // one for that server replaces, so "reconnected" takes the place of "disconnected".
        for host in Set(events.map(\.config.host)) {
            for event in [Event.dropped, .failed, .recovered] {
                let matching = events.filter { $0.config.host == host && $0.event == event }
                guard !matching.isEmpty else { continue }
                let paths = ListFormatter.localizedString(byJoining: matching.map(\.config.localPath))
                let plural = matching.count > 1
                switch event {
                case .dropped: notify(host, "\(host) disconnected", "\(paths) \(plural ? "are" : "is") unavailable.", level: .passive)
                case .recovered: notify(host, "\(host) reconnected", "\(paths) \(plural ? "are" : "is") available again.", level: .passive)
                case .failed: notify(host, "\(paths) can't mount", matching[0].detail ?? "The mount isn't coming up.", level: .active)
                }
            }
        }
    }

    private func info(for config: MountConfig, tracker: MountTracker, snapshot s: Snapshot, now: Date, justWoke: Bool) -> MountInfo {
        var info = MountInfo(config: config)
        let mounted = s.mountTable[config.realLocalPath] == MountSupervisor.fileSystemType
        if mounted {
            tracker.notMountedSince = nil
            tracker.everMounted = true
        } else if tracker.notMountedSince == nil || justWoke {
            tracker.notMountedSince = now
        }
        if s.phases[config.id] == .waiting {
            tracker.offlineSince = tracker.offlineSince ?? now
        } else {
            tracker.offlineSince = nil
        }

        if s.ready[config.id] != true || s.fuseMissing {
            info.state = .setup
        } else if s.busy.contains(config.id) {
            info.state = .mounted
            info.detail = "In use"
        } else if serviceNeedsApproval || !config.enabled {
            info.state = .stopped
        } else if serviceStuck {
            info.state = .error
            info.detail = "The background service isn't responding."
        } else if s.phases[config.id] == .waiting {
            // A mount stays up while its server isn't answering; files in it can't be reached until it is.
            info.state = .offline
            info.offlineSince = tracker.offlineSince
        } else if s.reconnecting.contains(config.id) {
            info.state = .reconnecting
        } else if s.phases[config.id] == .failed {
            info.state = .error
            info.detail = s.failures[config.id] ?? "The mount isn't coming up."
        } else if mounted {
            info.state = .mounted
            if s.outdated.contains(config.id) { info.detail = "Updates once nothing is using it" }
        } else if let since = tracker.notMountedSince, now.timeIntervalSince(since) > 60 {
            info.state = .error
            info.detail = lastLogErrors[config.id] ?? "The mount isn't coming up."
        } else {
            info.state = tracker.everMounted ? .reconnecting : .connecting
        }
        return info
    }

    private enum Event { case dropped, failed, recovered }

    /// What a change of state is worth telling the user about, if anything.
    private func transition(from previous: MountState, to state: MountState, tracker: MountTracker, now: Date) -> Event? {
        if let reconnected = tracker.reconnectedAt {
            // It may never come back, and then "can't mount" must still be said.
            if state == .mounted || now.timeIntervalSince(reconnected) > 60 { tracker.reconnectedAt = nil } else { return nil }
        }
        switch state {
        case .mounted:
            tracker.downSince = nil
            guard tracker.dropNotified else { return nil }
            tracker.dropNotified = false
            return .recovered
        case .stopped:
            tracker.downSince = nil
            tracker.dropNotified = false
            return nil
        case .offline, .reconnecting, .connecting:
            // Being offline is normal: only an outage that lasts while the Mac is awake gets a quiet notice.
            let since = tracker.downSince ?? now
            tracker.downSince = since
            guard tracker.everMounted, now.timeIntervalSince(since) > 120, !tracker.dropNotified else { return nil }
            tracker.dropNotified = true
            return .dropped
        case .error:
            guard previous != .error, !tracker.dropNotified else { return nil }
            tracker.dropNotified = true
            return .failed
        case .setup:
            return nil
        }
    }

    private func notify(_ id: String, _ title: String, _ body: String, level: UNNotificationInterruptionLevel) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = level
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: Actions

    func setUp() { change(.apply) }

    func undoSetUp() {
        perform {
            // Stop the service (it unmounts on the way out); the helper only removes empty folders.
            if Service.isRegistered(Service.agent.status) { try await Service.unregister() }
            self.change(.undo)
        }
    }

    private func change(_ change: FolderSetup.Change) {
        actionError = nil
        do {
            try FolderSetup.start(change)
            pendingChange = change
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func track(_ change: FolderSetup.Change) {
        guard let result = FolderSetup.result() else {
            setupDetail = FolderSetup.needsApproval(change)
                ? "Allow Doppelganger in System Settings › General › Login Items to finish."
                : nil
            return
        }
        pendingChange = nil
        setupDetail = nil
        actionError = result
        Task { await FolderSetup.finish(change) }
    }

    func mount(_ id: MountConfig.ID) { perform { try Service.setEnabled(true, for: id) } }
    func unmount(_ id: MountConfig.ID) { perform { try Service.setEnabled(false, for: id) } }

    func reconnectAll() {
        let targets = mounts.filter { $0.config.enabled && $0.state != .setup }
        for mount in targets { trackers[mount.id]?.reconnectedAt = Date() }
        perform { for mount in targets { Service.reconnect(mount.config) } }
    }

    func restartService() { perform { await Service.restart() } }

    /// The full text of the last error, which is cleared once read.
    func showActionError() {
        guard let message = actionError else { return }
        let alert = NSAlert()
        alert.messageText = "That Didn't Work"
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
        actionError = nil
    }

    /// Unmounting failed because something is using the mount: the user decides whether to interrupt it.
    private func askToUnmount(_ config: MountConfig) {
        let alert = NSAlert()
        alert.messageText = "\(config.localPath) Is in Use"
        alert.informativeText = "A program has a file or folder open there. Unmounting anyway will interrupt it."
        alert.addButton(withTitle: "Cancel")
        let force = alert.addButton(withTitle: "Unmount Anyway")
        force.hasDestructiveAction = true
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            Service.forceUnmount(config)
        } else {
            mount(config.id)
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        actionError = nil
        Task {
            do {
                try await action()
            } catch {
                actionError = error.localizedDescription
            }
            working = false
            await refresh()
        }
    }
}
