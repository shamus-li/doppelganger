import AppKit
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    /// What's saved and running.
    @Published private(set) var saved: [MountConfig] = []
    /// The mount being edited in the sheet; it's saved only with Save.
    @Published var editing: MountConfig?
    @Published var error: String?
    @Published var confirmingRemoval = false
    @Published var loginError: String?
    @Published var opensAtLogin = Service.loginItem.status == .enabled

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try Service.loginItem.register() } else { try Service.loginItem.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        opensAtLogin = Service.loginItem.status == .enabled
    }

    /// Hosts from ~/.ssh/config, offered as suggestions.
    let sshHosts: [String] = {
        guard let text = try? String(contentsOfFile: Config.home + "/.ssh/config", encoding: .utf8) else { return [] }
        return text.split(separator: "\n").flatMap { line -> [String] in
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.first?.lowercased() == "host" else { return [] }
            return words.dropFirst().map(String.init).filter { !$0.contains("*") && !$0.contains("?") }
        }
    }()

    func reload() {
        saved = MountStore.load()
        opensAtLogin = Service.loginItem.status == .enabled
    }

    var isNew: Bool { editing.map { mount in !saved.contains { $0.id == mount.id } } ?? false }
    var problem: String? { editing?.problem(among: saved) }

    /// A form that's still being filled in isn't wrong yet.
    var visibleProblem: String? {
        guard let editing, !editing.host.isEmpty, !editing.remotePath.isEmpty else { return nil }
        return problem
    }

    /// Saving a changed sshfs command restarts the mount, even if something is using it.
    var saveRestarts: Bool {
        guard let editing, let current = saved.first(where: { $0.id == editing.id }) else { return false }
        return MountSupervisor.arguments(for: current) != MountSupervisor.arguments(for: editing)
    }

    func add() {
        editing = MountConfig(host: "", remotePath: "", localPath: "")
    }

    // Both start from the saved file, not `saved`: Mount and Unmount in the menu change it while this window is open.
    func save() {
        guard var mount = editing, problem == nil else { return }
        var mounts = MountStore.load()
        if let index = mounts.firstIndex(where: { $0.id == mount.id }) {
            mount.enabled = mounts[index].enabled
            mounts[index] = mount
        } else {
            mounts.append(mount)
        }
        write(mounts)
    }

    func remove() {
        guard let mount = editing else { return }
        write(MountStore.load().filter { $0.id != mount.id })
    }

    private func write(_ mounts: [MountConfig]) {
        do {
            try Service.save(mounts)
            saved = mounts
            editing = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A title and detail line beside a vertically centered control, as in System Settings.
struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            control
        }
    }
}

private struct MountsSettings: View {
    @ObservedObject var model: SettingsModel
    let monitor: Monitor

    var body: some View {
        Form {
            Section {
                ForEach(model.saved) { mount in
                    SettingsRow(title: mount.localPath, detail: mount.host) {
                        if let state = monitor.mounts.first(where: { $0.id == mount.id })?.state {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Color(nsColor: state.color))
                                .accessibilityLabel(state.title)
                                .help(state.title)
                        }
                        Button("Edit…") { model.editing = mount }
                            .accessibilityLabel("Edit \(mount.localPath)")
                    }
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Add Mount…") { model.add() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(item: $model.editing) { mount in
            MountEditor(model: model, original: mount)
        }
    }
}

private struct MountEditor: View {
    @ObservedObject var model: SettingsModel
    /// The mount the sheet opened with; still drawn for a moment after Cancel clears `editing`.
    let original: MountConfig

    private var mount: Binding<MountConfig> {
        Binding(get: { model.editing ?? original }, set: { model.editing = $0 })
    }

    /// The server's path, which is also where the folder appears on this Mac.
    private var path: Binding<String> {
        Binding(get: { mount.wrappedValue.remotePath }, set: {
            mount.wrappedValue.remotePath = $0
            mount.wrappedValue.localPath = $0
        })
    }

    /// Hosts containing what's typed so far; all of them while the field is empty.
    private var matchingHosts: [String] {
        let typed = mount.wrappedValue.host
        return model.sshHosts.filter { typed.isEmpty || ($0 != typed && $0.localizedCaseInsensitiveContains(typed)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(model.isNew ? "New Mount" : original.localPath)
                .font(.headline)
                .padding(.top)
            Form {
                TextField("SSH Host:", text: mount.host, prompt: Text("Host from ~/.ssh/config"))
                    .textInputSuggestions(matchingHosts, id: \.self) { host in
                        Text(host).textInputCompletion(host)
                    }
                TextField("Path:", text: path, prompt: Text("/home/user"))
                Toggle("Read only", isOn: mount.readOnly)
                if let message = model.visibleProblem ?? (model.saveRestarts ? "Saving restarts this mount, which interrupts anything using it." : nil) {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(model.visibleProblem == nil ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.columns)
            .padding(.horizontal, 20)
            .padding(.top, 12)

            HStack {
                if !model.isNew {
                    Button("Remove Mount…", role: .destructive) { model.confirmingRemoval = true }
                }
                if let message = model.error {
                    Text(message).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { model.editing = nil }
                    .keyboardShortcut(.cancelAction)
                Button(model.isNew ? "Add" : "Save") { model.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.problem != nil)
            }
            .padding()
        }
        .frame(width: 480)
        .confirmationDialog("Remove \(model.editing?.localPath ?? "")?", isPresented: $model.confirmingRemoval) {
            Button("Remove", role: .destructive) { model.remove() }
        } message: {
            Text("It will be unmounted. Files on the server aren't changed.")
        }
    }

}

private struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
                if let message = model.loginError {
                    Text(message).font(.subheadline).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The settings window, created on first use and kept for reuse.
@MainActor
final class SettingsWindow {
    /// In the order of the window's tabs.
    enum Pane: Int { case mounts, setup, general }

    private let model = SettingsModel()
    private let setup = SetupModel()
    private let monitor: Monitor
    private var window: NSWindow?
    private var tabs: NSTabViewController?

    init(monitor: Monitor) { self.monitor = monitor }

    func show(_ pane: Pane) {
        if window == nil {
            // Tabs in the toolbar, as in other Mac apps' settings windows.
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            for (title, symbol, view) in [
                ("Mounts", "externaldrive", AnyView(MountsSettings(model: model, monitor: monitor))),
                ("Setup", "checkmark.shield", AnyView(SetupSettings(model: setup, monitor: monitor))),
                ("General", "gearshape", AnyView(GeneralSettings(model: model))),
            ] {
                let hosting = NSHostingController(rootView: view)
                hosting.sizingOptions = .preferredContentSize
                hosting.title = title
                let item = NSTabViewItem(viewController: hosting)
                item.label = title
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
            self.tabs = tabs
        }
        tabs?.selectedTabViewItemIndex = pane.rawValue
        model.reload()
        setup.reload()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
