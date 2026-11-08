import Foundation

/// Paths and names that don't change.
enum Config {
    /// `/home` is a symlink to this directory, owned by the automounter until the one-time setup.
    static let dataHome = "/System/Volumes/Data/home"

    static let agentPlist = "com.shamusli.Doppelganger.service.plist"
    static let agentLabel = "com.shamusli.Doppelganger.service"

    /// From the user database; launchd doesn't set HOME for the service.
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let supportDir = home + "/Library/Application Support/Doppelganger"
    static let logsDir = home + "/Library/Logs/Doppelganger"
}
