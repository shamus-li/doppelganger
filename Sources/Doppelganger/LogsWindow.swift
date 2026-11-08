import AppKit
import SwiftUI

/// One parsed line of a mount's log.
struct LogEntry: Identifiable, Sendable {
    enum Level: Sendable { case error, notice, info }
    let id: Int
    let mount: String
    let date: Date?
    let level: Level
    let message: String

    /// Parses `2026/10/26 12:37:03 ERROR : message`; other lines (such as stack traces) keep their text.
    static func parse(_ line: LogLine) -> LogEntry {
        guard let date = LogReader.date(of: line.text) else {
            return LogEntry(id: line.id, mount: line.mount, date: nil, level: line.isError ? .error : .info,
                            message: line.text)
        }
        let rest = line.text.dropFirst(20)
        let level: Level = line.isError ? .error : rest.hasPrefix("NOTICE") ? .notice : .info
        let message = rest.firstIndex(of: ":").map { rest[rest.index(after: $0)...] } ?? rest
        return LogEntry(id: line.id, mount: line.mount, date: date, level: level,
                        message: message.trimmingCharacters(in: .whitespaces))
    }
}

@MainActor
final class LogsModel: ObservableObject {
    @Published var entries: [LogEntry] = []
    @Published var errorsOnly = false
    @Published var query = ""
    @Published var selection = Set<LogEntry.ID>()
    @Published var showsMounts = false
    private var stamps: [LogReader.Stamp] = []

    var visible: [LogEntry] {
        entries.filter { entry in
            (!errorsOnly || entry.level == .error)
                && (query.isEmpty || entry.message.localizedCaseInsensitiveContains(query))
        }.reversed()
    }

    func reload() async {
        let mounts = MountStore.load()
        // Any change to a published value redraws the whole table, so only change what has changed.
        if showsMounts != (mounts.count > 1) { showsMounts = mounts.count > 1 }
        let old = stamps
        guard let (stamps, entries) = await Task.detached(operation: { () -> ([LogReader.Stamp], [LogEntry])? in
            let stamps = LogReader.stamps(of: mounts)
            return stamps == old ? nil : (stamps, LogReader.tail(of: mounts).map(LogEntry.parse))
        }).value else { return }
        self.stamps = stamps
        self.entries = entries
    }

    /// The selected lines as text, for ⌘C.
    var selectedLines: [String] { lines(selection) }

    func copy(_ ids: Set<LogEntry.ID>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines(ids).joined(separator: "\n"), forType: .string)
    }

    private func lines(_ ids: Set<LogEntry.ID>) -> [String] {
        entries.filter { ids.contains($0.id) }.map { entry in
            ([entry.date.map(LogsView.time)] + [showsMounts ? entry.mount : nil, entry.message]).compactMap { $0 }.joined(separator: "  ")
        }
    }
}

struct LogsView: View {
    @ObservedObject var model: LogsModel

    /// Today's lines show the time; older ones the date too.
    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .standard)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
    }

    var body: some View {
        Table(model.visible, selection: $model.selection) {
            TableColumn("Time") { entry in
                Text(entry.date.map(Self.time) ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 130, max: 180)
            TableColumn("Mount") { entry in
                Text(entry.mount).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 100, max: 160)
            .defaultVisibility(model.showsMounts ? .visible : .hidden)
            TableColumn("") { entry in
                if entry.level == .error {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                        .accessibilityLabel("Error")
                }
            }
            .width(16)
            TableColumn("Message") { entry in
                Text(entry.message)
                    .lineLimit(3)
                    .help(entry.message)
            }
        }
        .contextMenu(forSelectionType: LogEntry.ID.self) { ids in
            if !ids.isEmpty {
                Button("Copy") { model.copy(ids) }
            }
        }
        .copyable(model.selectedLines)
        .overlay {
            if model.visible.isEmpty {
                if model.errorsOnly && model.query.isEmpty {
                    ContentUnavailableView("No Errors", systemImage: "checkmark.circle")
                } else if !model.query.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                } else {
                    ContentUnavailableView("No Log Entries", systemImage: "doc.text")
                }
            }
        }
        .searchable(text: $model.query)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $model.errorsOnly) {
                    Text("All").tag(false)
                    Text("Errors").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem {
                Button("Show Log Files in Finder", systemImage: "folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Config.logsDir))
                }
                .help("Show Log Files in Finder")
            }
        }
        .frame(minWidth: 560, minHeight: 300)
    }
}

/// The logs window, created on first use and kept for reuse. It reads the logs only while it's open:
/// a closed window keeps its SwiftUI view, so a `.task` there would keep running.
@MainActor
final class LogsWindow: NSObject, NSWindowDelegate {
    private let model = LogsModel()
    private var window: NSWindow?
    private var polling: Task<Void, Never>?

    func show(errorsOnly: Bool) {
        model.errorsOnly = errorsOnly
        if window == nil {
            let hosting = NSHostingController(rootView: LogsView(model: model))
            hosting.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Doppelganger Logs"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 820, height: 520))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            // Puts back the size and place the window had last time, if it was shown before.
            window.setFrameAutosaveName("Logs")
            self.window = window
        }
        if polling == nil {
            polling = Task { [model] in
                while !Task.isCancelled {
                    await model.reload()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        polling?.cancel()
        polling = nil
    }
}
