import AppKit
import UserNotifications

@main
enum Entry {
    static func main() {
        // launchd runs this same executable for the background service and, as root, for the /home
        // change; running the app's own code is what lets its Full Disk Access cover that change.
        let arguments = CommandLine.arguments
        if arguments.count == 2, arguments[1] == "--service" { MountService.run() }
        if arguments.count == 3, arguments[1] == "--root-helper" { exit(FolderSetup.runHelper(arguments[2])) }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Monitor?
    private var statusMenu: StatusMenu?
    private let logsWindow = LogsWindow()
    private var settingsWindow: SettingsWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = mainMenu()
        let monitor = Monitor()
        self.monitor = monitor
        let settingsWindow = SettingsWindow(monitor: monitor)
        self.settingsWindow = settingsWindow
        statusMenu = StatusMenu(monitor: monitor,
                                showLogs: { [logsWindow] errorsOnly in logsWindow.show(errorsOnly: errorsOnly) },
                                showSettings: { pane in settingsWindow.show(pane) })
        Task {
            await monitor.refresh()
            let notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if monitor.setupIncomplete || notifications == .notDetermined { settingsWindow.show(.setup) }
        }
    }

    @objc private func openSettings(_ sender: Any?) { settingsWindow?.show(.mounts) }

    /// Never on screen, since the app has no menu bar of its own, but it's where windows get ⌘W, text
    /// fields ⌘C and ⌘V, and the app ⌘Q and ⌘,.
    private func mainMenu() -> NSMenu {
        let app = NSMenu(title: "Doppelganger")
        app.addItem(withTitle: "About Doppelganger", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Doppelganger", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        let main = NSMenu()
        for menu in [app, file, edit, window] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        return main
    }
}

