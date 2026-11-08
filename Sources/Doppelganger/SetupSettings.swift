import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

enum MacFUSE: Sendable {
    case loaded, installed, missing

    /// macFUSE's kernel extension adds its sysctl values once it's loaded, which needs the user's approval.
    static func current() -> MacFUSE {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("vfs.generic.macfuse.control.tunables_initialized", &value, &size, nil, 0) == 0 { return .loaded }
        return FileManager.default.fileExists(atPath: "/Library/Filesystems/macfuse.fs") ? .installed : .missing
    }
}

/// What the Setup page checks. Read when Settings opens and whenever the app becomes active, which is
/// when the user comes back from System Settings.
@MainActor
final class SetupModel: ObservableObject {
    @Published private(set) var service = SMAppService.Status.notRegistered
    @Published private(set) var fuse = MacFUSE.missing
    @Published private(set) var notifications = UNAuthorizationStatus.notDetermined
    @Published private(set) var fullDiskAccess = false
    /// Mount folders outside the home folder, which need the root helper to create.
    @Published private(set) var rootFolders: [String] = []
    @Published var confirmingUndo = false
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        service = Service.agent.status
        fuse = MacFUSE.current()
        fullDiskAccess = FolderSetup.hasFullDiskAccess()
        rootFolders = MountStore.load().filter(\.needsRootSetup).map(\.localPath)
        Task { notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    }

    func allowNotifications() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            reload()
        }
    }

    static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security")!
    static let notificationSettings = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!
    static let macFUSE = URL(string: "https://macfuse.github.io")!
}

struct SetupSettings: View {
    @ObservedObject var model: SetupModel
    let monitor: Monitor

    var body: some View {
        Form {
            Section {
                SettingsRow(title: "Background Service", detail: model.service == .enabled ? nil : "Keeps folders mounted when the app is closed.") {
                    switch model.service {
                    case .enabled: done("On")
                    case .requiresApproval: Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    default: Text("Starting…").foregroundStyle(.secondary)
                    }
                }
                SettingsRow(title: "macFUSE", detail: fuseDetail) {
                    switch model.fuse {
                    case .loaded: done("Allowed")
                    case .installed: open("Open Privacy & Security…", SetupModel.privacySettings)
                    case .missing: open("Get macFUSE…", SetupModel.macFUSE)
                    }
                }
                SettingsRow(title: "Notifications", detail: notificationsAllowed ? nil : "Alerts you when a mount fails or a server stays offline.") {
                    switch model.notifications {
                    case .authorized, .provisional: done("Allowed")
                    case .notDetermined: Button("Allow…") { model.allowNotifications() }
                    default: open("Open Notifications…", SetupModel.notificationSettings)
                    }
                }
            }
            if !model.rootFolders.isEmpty {
                let folders = ListFormatter.localizedString(byJoining: model.rootFolders)
                Section {
                    SettingsRow(title: "Full Disk Access", detail: model.fullDiskAccess ? nil : "Needed to create folders outside your home folder.") {
                        if model.fullDiskAccess {
                            done("Allowed")
                        } else {
                            open("Open Full Disk Access…", FolderSetup.fullDiskAccessSettings)
                        }
                    }
                    SettingsRow(title: "Mount Folders", detail: monitor.setupDetail ?? (monitor.setupNeeded ? "Creates \(folders) on this Mac." : nil)) {
                        if !monitor.setupNeeded {
                            done("Done")
                            Button("Undo…") { model.confirmingUndo = true }
                                .disabled(!model.fullDiskAccess || monitor.pendingChange != nil || monitor.working)
                        } else if monitor.pendingChange != nil {
                            Text("Setting up…").foregroundStyle(.secondary)
                        } else {
                            Button("Set Up…") { monitor.setUp() }
                                .disabled(!model.fullDiskAccess || monitor.working)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Undo Mount Folder Setup?", isPresented: $model.confirmingUndo) {
            Button("Undo Setup", role: .destructive) { monitor.undoSetUp() }
        } message: {
            Text("Every mount will be unmounted and its folder removed from this Mac. Files on the server aren't changed.")
        }
    }

    private var notificationsAllowed: Bool {
        [.authorized, .provisional].contains(model.notifications)
    }

    private var fuseDetail: String? {
        switch model.fuse {
        case .loaded: nil
        case .missing: "Lets macOS mount folders from a server."
        case .installed: "If folders can't mount, allow it and restart your Mac."
        }
    }

    private func done(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func open(_ title: String, _ url: URL) -> some View {
        Button(title) { NSWorkspace.shared.open(url) }
    }
}
