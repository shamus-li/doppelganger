import Foundation
import Network
import Security
import Synchronization

/// The background service: the app's executable started by launchd with `--service`.
/// For each configured mount it keeps sshfs serving while the user wants it mounted. A mount stays up
/// while the server is unreachable: sshfs reconnects on the next use once the server answers again.
enum MountService {
    /// Seconds between rounds of work.
    static let checkInterval: TimeInterval = 5

    /// Written by the app before it unregisters the service to register a changed definition. The SIGTERM
    /// that follows then leaves the mounts to the next service instead of unmounting them; the service
    /// removes the file as it reads it.
    static var handoverRequest: String { Config.supportDir + "/handover" }

    private static let wake = DispatchSemaphore(value: 0)
    private static let signals = DispatchQueue(label: "signals")
    // Touched only by the main loop, except `terminating`, which a signal handler sets before waking it.
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
    nonisolated(unsafe) private static var terminating = false
    nonisolated(unsafe) private static var handingOver = false
    nonisolated(unsafe) private static var checkAgain = false
    private static let network = NWPathMonitor()

    static func run() -> Never {
        try? FileManager.default.createDirectory(atPath: Config.supportDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.createDirectory(atPath: Config.logsDir, withIntermediateDirectories: true)
        // SIGTERM (logout, unregistering) unmounts and stops; SIGUSR2 (the app was updated) stops and leaves
        // the mounts to the next run; SIGUSR1 means the settings or wanted state changed, or the Mac woke.
        handle(SIGTERM) {
            terminating = true
            wake.signal()
        }
        handle(SIGUSR2) {
            handingOver = true
            wake.signal()
        }
        handle(SIGUSR1) {
            checkAgain = true
            wake.signal()
        }
        network.pathUpdateHandler = { _ in
            checkAgain = true
            wake.signal()
        }
        network.start(queue: signals)

        var supervisors: [UUID: MountSupervisor] = [:]
        let probes = Probes()
        while true {
            // Without a readable list, what's running stays as it is.
            let configs = MountStore.saved() ?? supervisors.values.map(\.config)
            for config in configs {
                if let existing = supervisors[config.id] {
                    // Mount and Unmount don't change the sshfs command; step() handles them.
                    if MountSupervisor.arguments(for: existing.config) == MountSupervisor.arguments(for: config) {
                        existing.config = config
                        continue
                    }
                    existing.stop()
                }
                supervisors[config.id] = MountSupervisor(config: config)
            }
            for id in supervisors.keys where !configs.contains(where: { $0.id == id }) {
                supervisors.removeValue(forKey: id)?.stop()
            }
            if terminating {
                if (try? FileManager.default.removeItem(atPath: handoverRequest)) != nil {
                    handingOver = true
                } else {
                    for supervisor in supervisors.values {
                        supervisor.stop()
                        supervisor.log("Stopped")
                    }
                    exit(0)
                }
            }
            if handingOver {
                for supervisor in supervisors.values { supervisor.copyErrors() }
                exit(0)
            }

            if checkAgain {
                checkAgain = false
                for supervisor in supervisors.values { supervisor.checkSoon() }
            }
            let mounts = MountTable.current()
            // One check per server, shared by its mounts. Checks run in the background and wake this loop
            // when they finish, so a silent server doesn't hold up Mount, Unmount or Reconnect.
            for host in Set(supervisors.values.filter { $0.needsCheck(mounts) }.map(\.config.host)) {
                probes.start(host) { wake.signal() }
            }
            let answers = probes.finished()

            var status = ServiceStatus()
            for supervisor in supervisors.values {
                status.phases[supervisor.config.id] = supervisor.step(answering: answers[supervisor.config.host], mounts: mounts)
                if supervisor.runsOtherSshfs { status.outdated.insert(supervisor.config.id) }
                if supervisor.busy { status.busy.insert(supervisor.config.id) }
                if supervisor.isReconnecting { status.reconnecting.insert(supervisor.config.id) }
                status.failures[supervisor.config.id] = supervisor.failure
            }
            status.save()
            _ = wake.wait(timeout: .now() + checkInterval)
        }
    }

    private static func handle(_ signal: Int32, _ action: @escaping @Sendable () -> Void) {
        Darwin.signal(signal, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signal, queue: signals)
        source.setEventHandler(handler: action)
        source.resume()
        sources.append(source)
    }
}

/// Checks of whether servers' ssh ports answer, run in the background.
final class Probes: Sendable {
    private let state = Mutex<(running: Set<String>, finished: [String: Bool])>(([], [:]))

    /// Starts checking `host` unless a check of it is running or its answer hasn't been collected yet;
    /// `done` runs when it finishes.
    func start(_ host: String, done: @escaping @Sendable () -> Void) {
        guard state.withLock({ $0.finished[host] == nil && $0.running.insert(host).inserted }) else { return }
        DispatchQueue.global().async {
            let answered = Self.answers(host)
            self.state.withLock {
                $0.running.remove(host)
                $0.finished[host] = answered
            }
            done()
        }
    }

    /// The checks that finished since the last call: host → whether it answered.
    func finished() -> [String: Bool] {
        state.withLock { state in
            defer { state.finished = [:] }
            return state.finished
        }
    }

    /// Whether the host's ssh port accepts a connection within 3 seconds. The address comes from the
    /// user's ssh config, read each time so a change to it applies.
    private static func answers(_ host: String) -> Bool {
        var settings: [String: String] = [:]
        for line in run("/usr/bin/ssh", ["-G", host]).output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { settings[String(parts[0])] = String(parts[1]) }
        }
        let port = settings["port"].flatMap { NWEndpoint.Port($0) } ?? 22
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 3
        let connection = NWConnection(to: .hostPort(host: NWEndpoint.Host(settings["hostname"] ?? host), port: port),
                                      using: NWParameters(tls: nil, tcp: tcp))
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ready = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready = true; done.signal()
            case .failed, .waiting: done.signal()
            default: break
            }
        }
        connection.start(queue: .global())
        _ = done.wait(timeout: .now() + 3.5)
        connection.cancel()
        return ready
    }
}

/// Keeps one mount in the state its settings ask for.
final class MountSupervisor {
    /// Built by sshfs/build.sh and copied into the app by `make app`.
    static let sshfs = Bundle.main.bundleURL.appending(path: "Contents/MacOS/sshfs")
    /// The file system type macFUSE gives its mounts.
    static let fileSystemType = "macfuse"

    var config: MountConfig
    private var process: Sshfs?
    private var startedAt = Date.distantPast
    private var mountLogged = false
    /// Starts that ended within a minute in a row; each doubles the wait before the next one.
    private var quickExits = 0
    private var nextStart = Date.distantPast
    private var answering = true
    /// Failed checks in a row. One alone doesn't count: a busy server or network misses one now and then,
    /// and the next check, 5 s later, usually succeeds.
    private var failedChecks = 0
    private var checkedAt = Date.distantPast
    /// How much of sshfs's error output is already in the log.
    private var errorsCopied: UInt64 = 0
    /// The sshfs taken over from an earlier service isn't the app's current one: an older build, or one
    /// started from where the app used to be, which a later service couldn't recognize once that copy is deleted.
    private(set) var runsOtherSshfs = false
    private var restartTriedAt = Date.distantPast
    /// The user asked to unmount, but something is using the mount.
    private(set) var busy = false
    /// Why sshfs keeps ending, until the mount comes up.
    private(set) var failure: String?
    /// The last thing sshfs said that wasn't about losing the connection.
    private var lastError: String?
    /// Set by Reconnect: done once sshfs answers a lookup, and it's restarted if that takes too long.
    private var reconnectCheck: (answered: DispatchSemaphore, deadline: Date)?
    var isReconnecting: Bool { reconnectCheck != nil }

    init(config: MountConfig) {
        self.config = config
        if let record = Sshfs.Record.load(for: config), let running = Sshfs(adopting: record) {
            if record.arguments == Self.arguments(for: config) {
                // An earlier run of the service left this mount up for us (an update).
                process = running
                runsOtherSshfs = record.build != Sshfs.build || record.executable != Self.sshfs.path
                mountLogged = MountTable.current()[config.realLocalPath] == Self.fileSystemType
                errorsCopied = (try? FileManager.default.attributesOfItem(atPath: config.sshfsErrors)[.size] as? UInt64) ?? 0
                return
            }
            // Its settings changed while no service ran. It may not be mounted yet; mounting before it
            // ends would stack the two.
            log("Stopping the sshfs started with the old settings")
            running.terminate()
        }
        try? FileManager.default.removeItem(atPath: config.sshfsRecord)
        clearMountPoint()
    }

    /// The server's ssh port is checked every 5 s while the mount is down or the server isn't answering,
    /// and every 30 s otherwise, so the server's ssh log isn't filled with connection attempts. It isn't
    /// checked while sshfs has an established connection, whose keepalives already show the server
    /// answers, nor for a mount that's off or waiting for folder setup: step() wouldn't take the answer,
    /// and each finished check would start the next at once.
    func needsCheck(_ mounts: MountTable) -> Bool {
        guard config.enabled, FolderSetup.isReady(config, mounts: mounts), process?.isConnected != true
        else { return false }
        let interval: TimeInterval = process != nil && answering && failedChecks == 0 ? 30 : 5
        return Date().timeIntervalSince(checkedAt) >= interval
    }

    /// Forgets when the server was last checked, for when the network has just changed.
    func checkSoon() { checkedAt = .distantPast }

    /// Does one round of work and reports where the mount stands. `answering` is the result of a check
    /// of the server that finished since the last round, if any.
    func step(answering answered: Bool?, mounts: MountTable) -> ServiceStatus.Phase {
        let answered = process?.isConnected == true ? true : answered
        copyErrors()
        busy = false
        if FileManager.default.fileExists(atPath: config.reconnectRequest) {
            try? FileManager.default.removeItem(atPath: config.reconnectRequest)
            reconnect()
        }
        // Folders outside the user's home wait for the one-time setup in the app.
        guard config.enabled, FolderSetup.isReady(config, mounts: mounts) else {
            let forced = (try? FileManager.default.removeItem(atPath: config.forceUnmountRequest)) != nil
            if process != nil {
                // The app asks before an Unmount interrupts whatever is using the mount.
                if !config.enabled, !forced, unmount(config.realLocalPath, 0) != 0, errno == EBUSY {
                    busy = true
                    return .running
                }
                log("Unmounting")
                stop()
            }
            failure = nil
            return .stopped
        }
        if let check = reconnectCheck {
            if check.answered.wait(timeout: .now()) == .success {
                reconnectCheck = nil
            } else if Date() >= check.deadline {
                reconnectCheck = nil
                log("sshfs isn't answering; restarting it")
                // A plain unmount would wait on the stuck sshfs.
                process?.terminate()
                ended()
            }
        }
        if let exited = process, !exited.isRunning {
            quickExits = Date().timeIntervalSince(startedAt) < 60 ? quickExits + 1 : 0
            let delay = quickExits > 0 ? min(5 * pow(2, Double(quickExits - 1)), 60) : 0
            nextStart = Date().addingTimeInterval(delay)
            log("sshfs stopped unexpectedly" + (exited.exitDescription.map { " (\($0))" } ?? "") + "; "
                + (delay > 0 ? "retrying in \(Int(delay)) s" : "restarting"))
            ended()
            if quickExits > 0, let lastError { failure = Self.plainFailure(lastError, host: config.host, path: config.remotePath) }
        }
        if let answered {
            checkedAt = Date()
            failedChecks = answered ? 0 : failedChecks + 1
            let nowAnswering = answered || (answering && failedChecks < 2)
            if nowAnswering != answering {
                log(nowAnswering ? "\(config.host) is answering again" : "\(config.host) isn't answering")
            }
            answering = nowAnswering
        }
        guard answering else { return .waiting }
        if process != nil { restartIfUnused(mounts) }
        if process == nil, Date() >= nextStart { start() }
        // Read again: this round may have cleared the folder or started sshfs since `mounts` was read.
        if process != nil, !mountLogged, MountTable.current()[config.realLocalPath] == Self.fileSystemType {
            mountLogged = true
            failure = nil
            log("Mounted")
        }
        return failure == nil ? .running : .failed
    }

    /// Restarts sshfs when it isn't the app's current one, or when a mount left behind by a killed
    /// sshfs is hidden under it (it would show once this one goes away). Only while nothing uses the mount.
    private func restartIfUnused(_ mounts: MountTable) {
        let reason = runsOtherSshfs ? "the app has a different sshfs"
            : mounts.count(of: Self.fileSystemType, at: config.realLocalPath) > 1 ? "an old mount is hidden under it"
            : nil
        guard let reason, Date().timeIntervalSince(restartTriedAt) >= 60 else { return }
        restartTriedAt = Date()
        // A plain unmount fails while anything has a file or folder open in the mount.
        guard unmount(config.realLocalPath, 0) == 0 else { return }
        log("Restarting sshfs: \(reason)")
        if process?.waitForExit(seconds: 5) == false { process?.terminate() }
        ended()
    }

    // MARK: sshfs

    /// The sshfs command line for these settings.
    static func arguments(for config: MountConfig) -> [String] {
        // ssh gives up on a silent server after about 15 s, and sshfs reconnects on the next use.
        // AES-GCM is the fastest cipher on Apple silicon; the ^ only moves it to the front of ssh's list.
        let ssh = "ssh -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2"
            + " -o Ciphers=^aes128-gcm@openssh.com -o Compression=no"
        var options = [
            "ssh_command=" + ssh, "reconnect",
            // Changes made on the server show up within 5 s; sshfs/patches/invalidate-changed.patch
            // makes macOS drop a changed file's cached contents too.
            "cache_timeout=5",
            // Keeps macOS's "Server connections interrupted" dialog away; the app notifies instead.
            // The mount also doesn't show as a separate volume in Finder's sidebar.
            "nobrowse",
            // macOS can't store file attributes on the server; without this it writes a ._name file
            // beside every file it creates.
            "noappledouble",
            // sshfs 3 refuses to follow links whose target is absolute or contains "..".
            "no_contain_symlinks",
            // Reads in 1 MB pieces instead of 64 KB.
            "iosize=1048576",
            // Finder names the folder after the mount's volume, "macFUSE Volume 0 (sshfs)" by default.
            "volname=" + (config.localPath as NSString).lastPathComponent,
        ]
        if config.readOnly { options.append("ro") }
        return ["\(config.host):\(config.remotePath)", config.localPath, "-f", "-o", options.joined(separator: ",")]
    }

    private func start() {
        // Mounting over a leftover mount would hide it until the new one goes away.
        guard clearMountPoint() else {
            nextStart = Date().addingTimeInterval(30)
            return
        }
        if !config.needsRootSetup, !FileManager.default.fileExists(atPath: config.localPath) {
            try? FileManager.default.createDirectory(atPath: config.localPath, withIntermediateDirectories: true)
            // Only the mount folder is read-only while unmounted, so nothing written there lands on this Mac.
            chmod(config.localPath, 0o555)
        }
        let process = Process()
        process.executableURL = Self.sshfs
        process.arguments = Self.arguments(for: config)
        // launchd doesn't set HOME for agents registered through SMAppService.
        process.environment = ProcessInfo.processInfo.environment.merging(["HOME": Config.home]) { $1 }
        // sshfs only writes problems to stderr. It goes to a file rather than a pipe, so sshfs outlives
        // this service when it restarts for an update; copyErrors() moves it into the log with times.
        let errors = open(config.sshfsErrors, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard errors >= 0 else {
            log("Couldn't open \(config.sshfsErrors): \(String(cString: strerror(errno)))")
            return
        }
        process.standardError = FileHandle(fileDescriptor: errors, closeOnDealloc: true)
        errorsCopied = 0
        lastError = nil
        do {
            try process.run()
            self.process = Sshfs(process)
            Sshfs.Record(pid: process.processIdentifier, arguments: process.arguments ?? []).save(for: config)
            startedAt = Date()
            mountLogged = false
            runsOtherSshfs = false
        } catch {
            log("Couldn't start sshfs: \(error.localizedDescription)")
        }
    }

    func stop() {
        if let process, process.isRunning {
            // sshfs exits once its folder is unmounted. Something still using the mount keeps it busy,
            // and then it's forced: the user asked to unmount, and sshfs keeps no unsaved data.
            if unmount(config.realLocalPath, 0) != 0 { _ = unmount(config.realLocalPath, MNT_FORCE) }
            if !process.waitForExit(seconds: 5) { process.terminate() }
        }
        reconnectCheck = nil
        failure = nil
        ended()
    }

    /// Forgets the sshfs that has ended and clears what it left behind.
    private func ended() {
        process = nil
        try? FileManager.default.removeItem(atPath: config.sshfsRecord)
        copyErrors()
        try? FileManager.default.removeItem(atPath: config.sshfsErrors)
        clearMountPoint()
    }

    /// Ends sshfs's ssh connection. sshfs connects again for the lookup below and repeats what was in
    /// flight, so open files and shells in the mount keep working. If the lookup gets no answer, sshfs
    /// itself is stuck, and the next rounds restart it.
    private func reconnect() {
        guard let process, process.isRunning else { return }
        log("Reconnecting")
        for ssh in process.connections { kill(ssh, SIGTERM) }
        // A name never looked up before, so no cache can answer it for sshfs.
        let path = config.realLocalPath + "/.doppelganger-reconnect-" + UUID().uuidString
        let answered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var info = stat()
            _ = lstat(path, &info)
            answered.signal()
        }
        reconnectCheck = (answered, Date().addingTimeInterval(30))
    }

    /// Copies the complete lines sshfs has written to stderr since the last call into the log.
    func copyErrors() {
        guard let file = FileHandle(forReadingAtPath: config.sshfsErrors) else { return }
        defer { try? file.close() }
        guard (try? file.seek(toOffset: errorsCopied)) != nil, let data = try? file.readToEnd(),
              let end = data.lastIndex(of: UInt8(ascii: "\n"))
        else { return }
        let text = String(decoding: data[...end], as: UTF8.self)
        // ssh ends its lines with \r\n, which Swift counts as one Character, so split on any line break.
        for line in text.split(whereSeparator: \.isNewline) {
            let isLoss = Self.isConnectionLoss(line)
            if !isLoss { lastError = String(line) }
            Self.append((isLoss ? "NOTICE: " : "ERROR : ") + line, to: config.logFile)
        }
        errorsCopied += UInt64(end - data.startIndex + 1)
    }

    /// What ssh and sshfs say when the server stops answering or can't be reached. Being offline is
    /// normal: sshfs reconnects by itself, and the service already notes when the server stops answering.
    static func isConnectionLoss(_ line: Substring) -> Bool {
        let prefixes = ["remote host has disconnected", "Timeout, server ", "ssh: connect to host ",
                        "ssh: Could not resolve hostname ", "kex_exchange_identification: ", "Connection closed by ",
                        "client_loop: "]
        // ssh's timeouts read "Read from remote host …: Operation timed out", "Connection to … port 22
        // timed out", "Connection timed out during banner exchange" and so on.
        let phrases = ["timed out", "Connection reset by peer", "Broken pipe"]
        return prefixes.contains { line.hasPrefix($0) } || phrases.contains { line.contains($0) }
    }

    /// What sshfs's or ssh's last complaint means, and what to do about it.
    static func plainFailure(_ line: String, host: String, path: String) -> String {
        if line.contains("Permission denied") { return "The server refused the login. Run “ssh \(host)” in Terminal to check." }
        if line.contains("Host key verification failed") || line.contains("REMOTE HOST IDENTIFICATION") {
            return "The server's identity changed. Run “ssh \(host)” in Terminal to review it."
        }
        if line.contains("No such file or directory"), line.contains(path) { return "\(path) doesn't exist on \(host)." }
        if line.localizedCaseInsensitiveContains("macfuse") || line.contains("fuse device") {
            return "macFUSE isn't loaded. Check Settings › Setup."
        }
        return line
    }

    /// Unmounts every macFUSE mount at the mount folder, hidden ones too. With no sshfs of ours serving
    /// it, any mount there is left from a killed one: it fails every access. False if one couldn't go.
    @discardableResult
    private func clearMountPoint() -> Bool {
        for _ in 0..<MountTable.current().count(of: Self.fileSystemType, at: config.realLocalPath) {
            if unmount(config.realLocalPath, MNT_FORCE) != 0 {
                log("Couldn't unmount \(config.localPath): \(String(cString: strerror(errno)))")
                return false
            }
        }
        return true
    }

    // MARK: Log

    /// Appends a line to this mount's log.
    func log(_ message: String) { Self.append("NOTICE: \(message)", to: config.logFile) }

    /// Log lines start with the local time, as in `2026/10/26 12:37:03 NOTICE: Mounted`.
    private static func append(_ text: String, to path: String) {
        var now = time(nil)
        var local = tm()
        localtime_r(&now, &local)
        var stamp = [CChar](repeating: 0, count: 20)
        strftime(&stamp, stamp.count, "%Y/%m/%d %H:%M:%S", &local)
        let line = stamp.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } + " \(text)\n"
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        _ = line.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }
}

/// An sshfs this service started, or one an earlier run of the service left running.
final class Sshfs {
    let pid: pid_t
    /// Nil when taken over: only the process that started sshfs can collect its exit status.
    private let child: Process?
    private let executable: String

    init(_ child: Process) {
        self.child = child
        pid = child.processIdentifier
        executable = MountSupervisor.sshfs.path
    }

    /// The sshfs a record names, if it's still running.
    init?(adopting record: Record) {
        child = nil
        pid = record.pid
        executable = record.executable
        guard isRunning else { return nil }
    }

    /// A taken-over process is checked by its program too, since its process ID could be reused.
    var isRunning: Bool { child?.isRunning ?? (Self.path(of: pid) == executable) }
    var exitDescription: String? { child.map { "status \($0.terminationStatus)" } }

    /// Waits up to `seconds` for sshfs to exit; true if it did.
    @discardableResult
    func waitForExit(seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while isRunning, Date() < deadline { usleep(100_000) }
        return !isRunning
    }

    /// Asks sshfs to exit, which also unmounts it, and kills it if it hasn't within 5 s.
    func terminate() {
        guard isRunning else { return }
        kill(pid, SIGTERM)
        if !waitForExit(seconds: 5) {
            kill(pid, SIGKILL)
            waitForExit(seconds: 1)
        }
    }

    /// Whether sshfs has an ssh connection that has lasted 30 s. ssh gives up on a server that stays
    /// silent through its connect timeout (5 s) or its keepalives (about 15 s), so such a connection shows
    /// the server is answering without opening another one.
    var isConnected: Bool {
        connections.contains { ssh in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return proc_pidinfo(ssh, PROC_PIDTBSDINFO, 0, &info, size) == size
                && time(nil) - time_t(info.pbi_start_tvsec) >= 30
        }
    }

    /// The ssh processes sshfs runs for its connection to the server.
    var connections: [pid_t] {
        var pids = [pid_t](repeating: 0, count: 16)
        let count = Int(proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, min(count, pids.count))).filter { Self.path(of: $0)?.hasSuffix("/ssh") == true }
    }

    private static func path(of pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The code signature's hash of the app's sshfs program, so a newer service can tell that a running
    /// sshfs is an older build. A hash of the whole file would change at every signing, which records the time.
    static let build: String? = {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(MountSupervisor.sshfs as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }()

    /// The running sshfs, so a restarted service can take it over instead of unmounting.
    struct Record: Codable {
        let pid: pid_t
        let arguments: [String]
        var executable = MountSupervisor.sshfs.path
        var build: String? = Sshfs.build

        func save(for config: MountConfig) {
            try? JSONEncoder().encode(self).write(to: URL(fileURLWithPath: config.sshfsRecord), options: .atomic)
        }

        static func load(for config: MountConfig) -> Record? {
            FileManager.default.contents(atPath: config.sshfsRecord).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        }
    }
}
