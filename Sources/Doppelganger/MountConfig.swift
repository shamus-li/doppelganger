import Foundation

/// One remote folder mounted on this Mac, as set up in Settings.
struct MountConfig: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    /// A host from the user's ssh config (or any name ssh can reach).
    var host: String
    var remotePath: String
    var localPath: String
    var readOnly = false
    /// Whether the user wants it mounted; Mount and Unmount change this.
    var enabled = true

    /// Short and stable, for this mount's file names.
    var key: String { String(id.uuidString.prefix(8)).lowercased() }
    var logFile: String { Config.logsDir + "/\(key).log" }
    /// Asks the service to restart this mount (Reconnect).
    var reconnectRequest: String { Config.supportDir + "/\(key).reconnect" }
    /// Asks the service to unmount this mount even though something is using it.
    var forceUnmountRequest: String { Config.supportDir + "/\(key).force-unmount" }
    /// The running sshfs, so a restarted service can take it over instead of unmounting.
    var sshfsRecord: String { Config.supportDir + "/\(key).sshfs.json" }
    /// What sshfs writes to stderr; the service copies it into the log with times.
    var sshfsErrors: String { Config.supportDir + "/\(key).sshfs-errors" }

    /// Mount folders outside /Users (such as /home/… or /scratch) need root to create; see `FolderSetup`.
    var needsRootSetup: Bool { !localPath.hasPrefix("/Users/") }
    /// The first folder of the local path, such as `home` or `scratch`.
    var topLevel: String { localPath.split(separator: "/").first.map(String.init) ?? "" }
    /// Where the mount appears in the mount table: folders outside /Users live on the data volume,
    /// reached through /home or a synthetic link at /.
    var realLocalPath: String { needsRootSetup ? "/System/Volumes/Data" + localPath : localPath }

    /// What's wrong with the settings, if anything, given the other mounts.
    func problem(among mounts: [MountConfig]) -> String? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter an SSH host." }
        // sshfs would read such a host as one of its own options.
        if host.hasPrefix("-") || host.contains(where: \.isWhitespace) { return "The SSH host can't start with - or contain spaces." }
        if !remotePath.hasPrefix("/") { return "The path must start with /." }
        if !localPath.hasPrefix("/") || topLevel.isEmpty { return "The path must start with /." }
        if !hasPlainPath { return "The path can't contain empty parts, . or .., commas or line breaks." }
        if localPath.hasPrefix("/Users/"), !localPath.hasPrefix(Config.home + "/") {
            return "Paths under /Users must be inside your home folder."
        }
        if needsRootSetup, topLevel != "home", !Self.isAvailableTopLevel(topLevel) {
            return "/\(topLevel) already exists on this Mac, so it can't be mounted at the same path."
        }
        if mounts.contains(where: { $0.id != id && $0.localPath == localPath }) {
            return "Another mount already uses \(localPath)."
        }
        return nil
    }

    /// Every part of the local path is a real folder name, so the path means what it says. Commas would
    /// split sshfs's options, and line breaks would add lines to the synthetic link file.
    var hasPlainPath: Bool {
        localPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            .allSatisfy { part in
                !part.isEmpty && part != "." && part != ".."
                    && !part.unicodeScalars.contains { $0 == "," || CharacterSet.controlCharacters.contains($0) }
            }
    }

    /// A top-level name is usable when nothing exists there yet, or it's already a link into the data volume.
    static func isAvailableTopLevel(_ name: String) -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/" + name) else {
            return !FileManager.default.fileExists(atPath: "/" + name)
        }
        return target == "System/Volumes/Data/" + name
    }
}

/// The saved list of mounts, shared by the app and the background service.
enum MountStore {
    static func file(home: String = Config.home) -> String {
        home + "/Library/Application Support/Doppelganger/mounts.json"
    }

    /// Nil when there's no readable list, because none was saved yet or the file is damaged or gone.
    static func saved(home: String = Config.home) -> [MountConfig]? {
        FileManager.default.contents(atPath: file(home: home)).flatMap { try? JSONDecoder().decode([MountConfig].self, from: $0) }
    }

    static func load(home: String = Config.home) -> [MountConfig] { saved(home: home) ?? [] }

    static func save(_ mounts: [MountConfig]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(atPath: Config.supportDir, withIntermediateDirectories: true)
        try encoder.encode(mounts).write(to: URL(fileURLWithPath: file()), options: .atomic)
    }
}

/// What the service is doing with each mount, written by the service and read by the app.
struct ServiceStatus: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        /// The user unmounted it.
        case stopped
        /// The server isn't answering; the service checks again every few seconds.
        case waiting
        /// sshfs is running.
        case running
        /// sshfs keeps ending; `failures` says why.
        case failed
    }

    var phases: [UUID: Phase] = [:]
    /// Mounts whose sshfs is an older build than the app's; the service restarts each once nothing uses it.
    var outdated: Set<UUID> = []
    /// Mounts the user asked to unmount but that something is using.
    var busy: Set<UUID> = []
    /// Mounts whose Reconnect hasn't finished yet.
    var reconnecting: Set<UUID> = []
    /// Why each failed mount can't come up, in words for the user.
    var failures: [UUID: String] = [:]
    /// The build the service is running, so the app can tell when an update needs a restart.
    var build = currentBuild
    /// When the service last wrote this; it writes every few seconds while it works.
    var savedAt: Date?

    /// When this process's executable was built, read once at launch: after an update the file on disk
    /// changes but a running process keeps the old code.
    static let currentBuild = (try? FileManager.default.attributesOfItem(atPath: Bundle.main.executablePath ?? "")[.modificationDate]
        as? Date)?.timeIntervalSince1970

    static var file: String { Config.supportDir + "/status.json" }

    /// A status that can't be read, such as one written by an older service, has no known build.
    static func load() -> ServiceStatus {
        if let data = FileManager.default.contents(atPath: file), let status = try? JSONDecoder().decode(ServiceStatus.self, from: data) {
            return status
        }
        var unknown = ServiceStatus()
        unknown.build = nil
        return unknown
    }

    func save() {
        var status = self
        status.savedAt = Date()
        guard let data = try? JSONEncoder().encode(status) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.file), options: .atomic)
    }
}
