import Foundation
import ServiceManagement

/// Creates mount folders outside the user's home folder, which needs root: under /home it frees /home
/// from the automounter; for new top-level names such as /scratch, and for /home where macOS no longer
/// provides it, it adds a synthetic link at /
/// (see synthetic.conf(5)) pointing into the data volume. It runs as root through a helper the user
/// allows in System Settings › General › Login Items.
enum FolderSetup {
    enum Change: String, Sendable {
        case apply, undo

        var helper: SMAppService { .daemon(plistName: "com.shamusli.Doppelganger.folders-\(rawValue).plist") }
    }

    static let logFile = Config.logsDir + "/setup.log"
    private static let dataVolume = "/System/Volumes/Data"

    /// True when the mount's folder can be mounted on. Folders in the user's home the service creates itself.
    /// Never looks inside a mounted folder: a busy or unreachable mount would make the check fail or hang.
    static func isReady(_ mount: MountConfig, mounts: MountTable) -> Bool {
        guard mount.needsRootSetup else { return true }
        if mounts[mount.realLocalPath] != nil { return true }
        var info = stat()
        if mount.topLevel == "home", mounts[Config.dataHome] == "autofs" { return false }
        // Since macOS 27.2 nothing provides /home, so it needs a synthetic link like any new name.
        if lstat("/" + mount.topLevel, &info) != 0 { return false }
        guard stat(mount.realLocalPath, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
    }

    /// macOS lets the helper edit files in /etc only when the app it belongs to has Full Disk Access.
    /// The TCC database is readable exactly when that access is granted.
    static func hasFullDiskAccess() -> Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    static let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Registers the helper; launchd runs it once the user allows it.
    static func start(_ change: Change) throws {
        try? FileManager.default.removeItem(atPath: logFile)
        let helper = change.helper
        try helper.register()
        if helper.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    static func needsApproval(_ change: Change) -> Bool { change.helper.status == .requiresApproval }

    /// The helper runs at every startup while registered, so remove it once it has run.
    static func finish(_ change: Change) async { try? await change.helper.unregister() }

    /// The helper's result once it has run: nil for success, otherwise what went wrong.
    static func result() -> String?? {
        guard let log = try? String(contentsOfFile: logFile, encoding: .utf8) else { return .none }
        return .some(log == "done" ? nil : log)
    }

    // MARK: Helper (runs as root)

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Entry point for `--root-helper apply|undo`. Reports to the setup log of the user who owns the app.
    static func runHelper(_ argument: String) -> Int32 {
        guard let change = Change(rawValue: argument),
              let owner = try? FileManager.default.attributesOfItem(atPath: Bundle.main.bundlePath)[.ownerAccountName] as? String,
              let user = getpwnam(owner)
        else { return 64 }
        let uid = user.pointee.pw_uid
        let home = String(cString: user.pointee.pw_dir)
        let mounts = MountStore.load(home: home).filter(\.needsRootSetup)
        var result = "done"
        do {
            switch change {
            case .apply: try apply(mounts, owner: uid)
            case .undo: try undo(mounts)
            }
        } catch {
            result = error.localizedDescription
        }
        // The log is in a folder the user controls, so write it with the user's rights: as root, a link
        // put in its place would turn the write into one anywhere on the Mac.
        guard setegid(user.pointee.pw_gid) == 0, seteuid(uid) == 0 else { return 1 }
        let logs = home + "/Library/Logs/Doppelganger"
        try? FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logs + "/setup.log", contents: Data(result.utf8))
        return result == "done" ? 0 : 1
    }

    private static let autoMaster = "/etc/auto_master"
    // Named before the app was renamed; the file is already in /etc on this Mac.
    private static let syntheticManifest = "/etc/synthetic.d/mount-manager"

    private static func apply(_ mounts: [MountConfig], owner: uid_t) throws {
        try mounts.forEach(checkSafe)
        if mounts.contains(where: { $0.topLevel == "home" }) {
            try editAutoMaster(disablingHomeMap)
            try reloadAutomounter()
        }
        for mount in mounts where !FileManager.default.fileExists(atPath: mount.realLocalPath) {
            let folder = mount.realLocalPath
            // Folders above the mount point stay root's; the mount point itself belongs to the user.
            try FileManager.default.createDirectory(atPath: (folder as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
            // Read-only while unmounted, so nothing written while offline lands on this Mac.
            guard chown(folder, owner, gid_t(20)) == 0, chmod(folder, 0o555) == 0 else {
                throw Failure(message: "Couldn't prepare \(mount.localPath): \(String(cString: strerror(errno)))")
            }
        }
        // /home gets a link too when macOS no longer provides it (or the link is already ours).
        let names = Set(mounts.map(\.topLevel))
            .filter { $0 != "home" || MountConfig.isAvailableTopLevel($0) }.sorted()
        guard !names.isEmpty else { return }
        try writeSynthetic(syntheticEntries(for: names))
        // Creates the links now instead of at the next startup.
        let result = run("/System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util", ["-t"])
        let missing = names.filter { !FileManager.default.fileExists(atPath: "/" + $0) }
        guard missing.isEmpty else {
            let paths = missing.map { "/" + $0 }.joined(separator: " and ")
            throw Failure(message: "Restart your Mac to finish creating \(paths). (\(result.output))")
        }
    }

    /// mounts.json is the user's to edit, so root only works on plain paths, under /home or a new
    /// top-level name, whose existing folders above the mount point are root's and not links.
    /// Otherwise a crafted path could have root create and hand over a folder anywhere.
    /// Those folders must also be on the data volume itself, not inside a mount, and writable only by
    /// root, so nothing can replace one with a link between this check and the folders being created.
    private static func checkSafe(_ mount: MountConfig) throws {
        let refuse = Failure(message: "Doppelganger won't set up \(mount.localPath). Choose a different local folder in Settings.")
        guard mount.hasPlainPath, mount.topLevel == "home" || MountConfig.isAvailableTopLevel(mount.topLevel) else { throw refuse }
        var volume = stat()
        guard stat(dataVolume, &volume) == 0 else { throw refuse }
        var folder = dataVolume
        for part in mount.localPath.split(separator: "/").dropLast() {
            folder += "/" + part
            var info = stat()
            if lstat(folder, &info) != 0 { break }
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == 0, info.st_mode & 0o022 == 0,
                  info.st_dev == volume.st_dev
            else { throw refuse }
        }
    }

    private static func undo(_ mounts: [MountConfig]) throws {
        try mounts.forEach(checkSafe)
        // rmdir refuses a non-empty folder, so nothing is deleted if a mount is still up.
        for mount in mounts where rmdir(mount.realLocalPath) != 0 && errno != ENOENT {
            throw Failure(message: "Couldn't remove \(mount.localPath): \(String(cString: strerror(errno)))")
        }
        for name in Set(mounts.map(\.topLevel)).subtracting(["home"]) {
            rmdir(dataVolume + "/" + name)
        }
        // The links at / disappear at the next startup.
        if unlink(syntheticManifest) != 0 && errno != ENOENT {
            throw Failure(message: "Couldn't remove \(syntheticManifest): \(String(cString: strerror(errno)))")
        }
        try editAutoMaster(restoringHomeMap)
        try reloadAutomounter()
    }

    /// The manifest lines: each name becomes a link at / into the data volume.
    static func syntheticEntries(for names: [String]) -> String {
        "# Mount points created by Doppelganger\n" + names.map { "\($0)\tSystem/Volumes/Data/\($0)\n" }.joined()
    }

    private static func writeSynthetic(_ text: String) throws {
        try FileManager.default.createDirectory(atPath: (syntheticManifest as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        if (try? String(contentsOfFile: syntheticManifest, encoding: .utf8)) != text {
            try text.write(toFile: syntheticManifest, atomically: false, encoding: .utf8)
        }
    }

    private static func editAutoMaster(_ edit: (String) -> String) throws {
        let text = try String(contentsOfFile: autoMaster, encoding: .utf8)
        let edited = edit(text)
        if edited != text { try edited.write(toFile: autoMaster, atomically: false, encoding: .utf8) }
    }

    private static func reloadAutomounter() throws {
        let result = run("/usr/sbin/automount", ["-vc"])
        guard result.status == 0 else { throw Failure(message: "automount: \(result.output)") }
    }

    private static var homeMapLine: Regex<AnyRegexOutput> { try! Regex(#"^/home\s+auto_home(\s|$)"#) }

    /// Comments out the `/home auto_home …` line of auto_master.
    static func disablingHomeMap(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.prefixMatch(of: homeMapLine) != nil ? "#" + $0 : String($0) }
            .joined(separator: "\n")
    }

    /// Restores the line `disablingHomeMap` commented out.
    static func restoringHomeMap(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("#") && $0.dropFirst().prefixMatch(of: homeMapLine) != nil ? String($0.dropFirst()) : String($0) }
            .joined(separator: "\n")
    }
}

/// The mount table, read without touching any mount.
struct MountTable: Sendable {
    /// Mount point → the file system types mounted there, oldest first. Only the last one is visible;
    /// the others are hidden under it, such as a mount left behind by a killed sshfs.
    private var types: [String: [String]] = [:]

    static func current() -> MountTable {
        var table = MountTable()
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return table }
        for entry in UnsafeBufferPointer(start: buffer, count: Int(count)) {
            var entry = entry
            let point = withUnsafeBytes(of: &entry.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let type = withUnsafeBytes(of: &entry.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            table.types[point, default: []].append(type)
        }
        return table
    }

    /// The type of the file system visible at `path`, if one is mounted there.
    subscript(path: String) -> String? { types[path]?.last }

    /// How many file systems of `type` are mounted at `path`, visible or hidden.
    func count(of type: String, at path: String) -> Int { types[path]?.count { $0 == type } ?? 0 }
}
