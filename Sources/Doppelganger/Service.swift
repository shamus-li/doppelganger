import Foundation
import ServiceManagement

/// The background service bundled in the app (`MountService`, run by launchd), and the app's login item.
enum Service {
    static var agent: SMAppService { .agent(plistName: Config.agentPlist) }
    /// A service that was never registered reports `.notFound`, not `.notRegistered`.
    static func isRegistered(_ status: SMAppService.Status) -> Bool { status == .enabled || status == .requiresApproval }
    private static var target: String { "gui/\(getuid())/\(Config.agentLabel)" }

    /// Saves the mounts and wakes the service so it applies them now instead of at its next check.
    static func save(_ mounts: [MountConfig]) throws {
        try MountStore.save(mounts)
        wake()
    }

    /// Mount or unmount one mount; the service keeps this choice across restarts and logins.
    static func setEnabled(_ enabled: Bool, for id: MountConfig.ID) throws {
        var mounts = MountStore.load()
        guard let index = mounts.firstIndex(where: { $0.id == id }) else { return }
        mounts[index].enabled = enabled
        try save(mounts)
    }

    /// Restarts one mount's sshfs.
    static func reconnect(_ mount: MountConfig) {
        FileManager.default.createFile(atPath: mount.reconnectRequest, contents: nil)
        wake()
    }

    /// Has the service act now, and check servers again.
    static func wake() { signal("SIGUSR1") }

    /// launchctl takes a few tens of milliseconds, so it runs off the main thread.
    private static func signal(_ name: String) {
        let target = target
        DispatchQueue.global().async { _ = run("/bin/launchctl", ["kill", name, target]) }
    }

    static func register() throws {
        try agent.register()
        UserDefaults.standard.set(bundledDefinition, forKey: registeredDefinitionKey)
    }

    static func unregister() async throws { try await agent.unregister() }

    /// Starts the service again, leaving the mounts up for the new one to take over.
    static func restart() async {
        let request = MountService.handoverRequest
        FileManager.default.createFile(atPath: request, contents: nil)
        let target = target
        await Task.detached { _ = run("/bin/launchctl", ["kickstart", "-k", target]) }.value
        try? FileManager.default.removeItem(atPath: request)
    }

    /// Unmounts a mount that something is using.
    static func forceUnmount(_ mount: MountConfig) {
        FileManager.default.createFile(atPath: mount.forceUnmountRequest, contents: nil)
        wake()
    }

    /// Brings the service up to date with this copy of the app. launchd keeps the definition and the app's
    /// location it read at registration, so a changed plist or a moved app needs registering again; a
    /// service still running an older build is asked to hand over (SIGUSR2), and launchd starts it again
    /// from the new one. Either way the new service takes over the mounts that are up.
    static func updateIfChanged() async throws {
        guard isRegistered(agent.status) else { return }
        if UserDefaults.standard.data(forKey: registeredDefinitionKey) != bundledDefinition {
            // Unregistering ends the service with SIGTERM, which unmounts; this file asks it to hand over instead.
            let request = MountService.handoverRequest
            FileManager.default.createFile(atPath: request, contents: nil)
            try await unregister()
            // The service removes the file as it reads it. If no service was running, nothing will.
            for _ in 0..<50 where FileManager.default.fileExists(atPath: request) {
                try await Task.sleep(for: .milliseconds(100))
            }
            try? FileManager.default.removeItem(atPath: request)
            try register()
        } else if ServiceStatus.load().build != ServiceStatus.currentBuild {
            signal("SIGUSR2")
        }
    }

    private static let registeredDefinitionKey = "registeredServiceDefinition"
    private static var bundledDefinition: Data? {
        FileManager.default.contents(atPath: Bundle.main.bundlePath + "/Contents/Library/LaunchAgents/" + Config.agentPlist)
            .map { $0 + Data(Bundle.main.bundlePath.utf8) }
    }

    /// "Start at login" opens the app at login; mounting follows each mount's own state.
    static var loginItem: SMAppService { .mainApp }
}
