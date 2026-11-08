import AppKit
import Observation
import ServiceManagement

/// The menu bar extra: a standard menu that updates in place while it's open.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let monitor: Monitor
    private let showLogs: (_ errorsOnly: Bool) -> Void
    private let showSettings: (SettingsWindow.Pane) -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var actions: [String: () -> Void] = [:]
    private var isOpen = false

    init(monitor: Monitor, showLogs: @escaping (_ errorsOnly: Bool) -> Void, showSettings: @escaping (SettingsWindow.Pane) -> Void) {
        self.monitor = monitor
        self.showLogs = showLogs
        self.showSettings = showSettings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        observe()
    }

    private func observe() {
        withObservationTracking { render() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        guard menu == self.menu else { return }
        monitor.panelOpen = true
        render()
        isOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu == self.menu else { return }
        isOpen = false
        monitor.panelOpen = false
    }

    // MARK: Rendering

    private struct Entry {
        enum Kind { case header, separator, item }
        var id: String
        var kind = Kind.item
        var title = ""
        var subtitle: String?
        var image: NSImage?
        var enabled = true
        var checked = false
        var key = ""
        var action: (() -> Void)?
        var submenu: [Entry]?
        var toolTip: String?
        var badge: String?
        /// Replaces the item above it while Option is held.
        var isAlternate = false
    }

    private func render() {
        let state = monitor.overallState
        statusItem.button?.image = state.icon
        statusItem.button?.toolTip = "Doppelganger, \(state.title)"
        statusItem.button?.appearsDisabled = state == .stopped
        actions = [:]
        apply(entries(), to: menu)
    }

    /// Updates the existing items in place. Rows are added or removed only while the menu is closed,
    /// so an open menu never changes size.
    private func apply(_ entries: [Entry], to menu: NSMenu) {
        let sameLayout = menu.items.count == entries.count
            && zip(menu.items, entries).allSatisfy { $0.identifier?.rawValue == $1.id }
        if !sameLayout, !isOpen {
            menu.removeAllItems()
            for entry in entries {
                let item: NSMenuItem = switch entry.kind {
                case .separator: .separator()
                case .header: .sectionHeader(title: entry.title)
                case .item: NSMenuItem(title: entry.title, action: #selector(choose(_:)), keyEquivalent: entry.key)
                }
                item.identifier = NSUserInterfaceItemIdentifier(entry.id)
                item.target = self
                menu.addItem(item)
            }
        }
        let entriesByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in menu.items {
            guard let id = item.identifier?.rawValue, let entry = entriesByID[id], entry.kind == .item else { continue }
            if item.title != entry.title { item.title = entry.title }
            if item.subtitle != entry.subtitle { item.subtitle = entry.subtitle }
            item.image = entry.image
            item.isEnabled = entry.enabled
            item.state = entry.checked ? .on : .off
            item.toolTip = entry.toolTip
            item.isAlternate = entry.isAlternate
            if entry.isAlternate { item.keyEquivalentModifierMask = entry.key.isEmpty ? .option : [.command, .option] }
            if item.badge?.stringValue != entry.badge { item.badge = entry.badge.map(NSMenuItemBadge.init(string:)) }
            actions[entry.id] = entry.action
            if let children = entry.submenu {
                let submenu = item.submenu ?? NSMenu()
                submenu.autoenablesItems = false
                item.submenu = submenu
                apply(children, to: submenu)
            } else {
                item.submenu = nil
            }
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let id = sender.identifier?.rawValue else { return }
        actions[id]?()
    }

    private func entries() -> [Entry] {
        var entries = problemEntries()
        if !entries.isEmpty { entries.append(Entry(id: "sep-problems", kind: .separator)) }
        for (index, mount) in monitor.mounts.enumerated() {
            entries += rowEntries(mount, key: index < 9 ? String(index + 1) : "")
        }
        if monitor.mounts.isEmpty {
            entries.append(Entry(id: "add-mount", title: "Add a Mount…", action: { [showSettings] in showSettings(.mounts) }))
        } else {
            entries.append(Entry(id: "sep-mounts", kind: .separator))
            // Reconnecting also unsticks a mount that looks fine but isn't answering.
            entries.append(Entry(id: "reconnect", title: reconnectTitle, enabled: canReconnect && !monitor.working, key: "r",
                                 action: { [monitor] in monitor.reconnectAll() },
                                 toolTip: "Starts a new connection to the server. Open files and Terminal windows keep working."))
            entries.append(Entry(id: "mount-menu", title: "Mount", submenu: monitor.mounts.map(mountChoice)))
        }
        entries.append(Entry(id: "sep-app", kind: .separator))
        // Errors from the last hour show as a badge; with any, the logs open on the errors.
        let errors = monitor.errorsLastHour
        entries.append(Entry(id: "logs", title: "Show Logs", key: "l",
                             action: { [showLogs] in showLogs(errors > 0) },
                             badge: errors > 0 ? "\(errors) error\(errors == 1 ? "" : "s")" : nil))
        entries.append(Entry(id: "settings", title: "Settings…", key: ",", action: { [showSettings] in showSettings(.mounts) }))
        entries.append(Entry(id: "about", title: "About Doppelganger", action: {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        }))
        entries.append(Entry(id: "sep-quit", kind: .separator))
        entries.append(Entry(id: "quit", title: "Quit Doppelganger", key: "q", action: { NSApp.terminate(nil) }))
        return entries
    }

    private var reconnectTitle: String {
        let hosts = Set(monitor.mounts.filter { $0.config.enabled && $0.state != .setup }.map(\.config.host))
        return hosts.count == 1 ? "Reconnect to \(hosts.first!)" : "Reconnect All"
    }

    private var canReconnect: Bool {
        monitor.mounts.contains { $0.config.enabled && $0.state != .setup }
    }

    /// What's wrong and needs the user, each row starting the fix when it's clicked.
    private func problemEntries() -> [Entry] {
        var entries: [Entry] = []
        if monitor.serviceNeedsApproval {
            entries.append(Entry(id: "allow-service", title: "Allow Background Service…",
                                 action: { SMAppService.openSystemSettingsLoginItems() }))
        }
        if monitor.serviceStuck {
            entries.append(Entry(id: "restart-service", title: "Restart Background Service", enabled: !monitor.working,
                                 action: { [monitor] in monitor.restartService() }))
        }
        if monitor.listLost {
            entries.append(Entry(id: "list-lost", title: "Saved Mounts Can't Be Read…",
                                 subtitle: "Mounts that are up stay up.", action: {
                                     NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Config.supportDir)])
                                 }))
        }
        if monitor.setupNeeded || monitor.fuseMissing {
            entries.append(Entry(id: "finish-setup", title: "Finish Setup…", subtitle: monitor.setupDetail,
                                 action: { [showSettings] in showSettings(.setup) }))
        }
        if let error = monitor.actionError {
            let line = error.split(whereSeparator: \.isNewline).first.map(String.init) ?? error
            entries.append(Entry(id: "action-error", title: line.count > 60 ? line.prefix(60) + "…" : line,
                                 action: { [monitor] in monitor.showActionError() }, toolTip: error))
        }
        return entries
    }

    /// A mount's row, whose click does the most useful thing for its state, and its Option alternate.
    private func rowEntries(_ mount: MountInfo, key: String) -> [Entry] {
        let root = URL(fileURLWithPath: mount.config.localPath, isDirectory: true)
        let id = mount.id.uuidString
        let image = dot(mount.state.color)
        var action: (() -> Void)?
        switch mount.state {
        // Without isDirectory, this asks the file system, which freezes the menu while the server is silent.
        case .mounted: action = { NSWorkspace.shared.open(root, configuration: NSWorkspace.OpenConfiguration()) }
        case .error: action = { [showLogs] in showLogs(true) }
        case .setup: action = { [showSettings] in showSettings(.setup) }
        case .stopped, .connecting, .reconnecting, .offline: break
        }
        return [
            Entry(id: "row-\(id)", title: mount.config.localPath, subtitle: subtitle(mount), image: image,
                  enabled: action != nil, key: key, action: action),
            Entry(id: "terminal-\(id)", title: "Open \(mount.config.localPath) in Terminal", image: image,
                  enabled: mount.state == .mounted, key: key,
                  action: {
                      let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                      NSWorkspace.shared.open([root], withApplicationAt: terminal,
                                              configuration: NSWorkspace.OpenConfiguration())
                  }, isAlternate: true),
        ]
    }

    /// Only what's out of the ordinary: a mounted row needs no words.
    private func subtitle(_ mount: MountInfo) -> String? {
        switch mount.state {
        case .mounted: return mount.detail
        case .offline:
            guard let since = mount.offlineSince else { return mount.state.title }
            let time = Calendar.current.isDateInToday(since) ? since.formatted(date: .omitted, time: .shortened)
                : since.formatted(date: .abbreviated, time: .shortened)
            return "Offline since \(time)"
        default: return ([mount.state.title] + [mount.detail].compactMap { $0 }).joined(separator: "\n")
        }
    }

    private func mountChoice(_ mount: MountInfo) -> Entry {
        let id = mount.id
        return Entry(id: "choice-\(id.uuidString)", title: mount.config.localPath,
                     enabled: !monitor.working && mount.state != .setup, checked: mount.config.enabled,
                     action: { [monitor] in
                         if mount.config.enabled { monitor.unmount(id) } else { monitor.mount(id) }
                     })
    }

    // MARK: Formatting

    private func dot(_ color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(scale: .small).applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}

extension MountState {
    var title: String {
        switch self {
        case .mounted: "Mounted"
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .offline: "Offline"
        case .stopped: "Not Mounted"
        case .error: "Can't Mount"
        case .setup: "Setup Needed"
        }
    }

    var icon: NSImage {
        switch self {
        case .mounted: icon(filled: true)
        case .connecting, .reconnecting: icon(filled: false, badge: .reconnecting)
        case .stopped: icon(filled: false)
        case .offline: icon(filled: false, badge: .offline)
        case .error: icon(filled: false, badge: .error)
        case .setup: icon(filled: false, badge: .setup)
        }
    }

    private func icon(filled: Bool, badge: MenuBarIcon.Badge? = nil) -> NSImage {
        MenuBarIcon.image(filled: filled, badge: badge, description: "Doppelganger, \(title)")
    }

    var color: NSColor {
        switch self {
        case .mounted: .systemGreen
        case .connecting, .reconnecting: .systemYellow
        case .offline: .systemOrange
        case .stopped, .setup: .tertiaryLabelColor
        case .error: .systemRed
        }
    }
}
