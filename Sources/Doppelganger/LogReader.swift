import Foundation
import Synchronization

struct LogLine: Identifiable, Sendable {
    let id: Int
    let mountID: UUID
    /// The mount's local path.
    var mount = ""
    let text: String
    let isError: Bool
}

enum LogReader {
    /// A log's size and modification time: while they stay the same, the log hasn't changed.
    struct Stamp: Equatable, Sendable {
        let mount: String
        let path: String
        let size: Int64
        let modified: timespec

        static func == (a: Stamp, b: Stamp) -> Bool {
            a.mount == b.mount && a.path == b.path && a.size == b.size
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }

    static func stamps(of mounts: [MountConfig]) -> [Stamp] {
        mounts.map { mount in
            var info = stat()
            let found = stat(mount.logFile, &info) == 0
            return Stamp(mount: mount.localPath, path: mount.logFile, size: found ? info.st_size : -1,
                         modified: found ? info.st_mtimespec : timespec())
        }
    }

    /// The menu and the logs window both ask every 2 s, almost always for logs that haven't changed.
    private static let last = Mutex<(stamps: [Stamp], lines: [LogLine])?>(nil)

    /// The last part of every mount's log, merged in time order.
    static func tail(of mounts: [MountConfig]) -> [LogLine] {
        let stamps = stamps(of: mounts)
        if let last = last.withLock({ $0 }), last.stamps == stamps { return last.lines }
        let lines = read(mounts)
        last.withLock { $0 = (stamps, lines) }
        return lines
    }

    private static func read(_ mounts: [MountConfig]) -> [LogLine] {
        let lines = mounts.flatMap { mount in
            tail(of: mount.logFile).map { (mount, $0) }
        }
        // Lines without a timestamp (such as a stack trace) keep their place after the line before them.
        var lastDate = Date.distantPast
        let dated = lines.map { mount, text in
            if let date = date(of: text) { lastDate = date }
            return (lastDate, mount, text)
        }
        return dated.enumerated()
            .sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
            .enumerated()
            .map { index, entry in
                LogLine(id: index, mountID: entry.element.1.id, mount: entry.element.1.localPath, text: entry.element.2,
                        isError: isError(Substring(entry.element.2)))
            }
    }

    /// Reads roughly the last `bytes` of one log.
    private static func tail(of path: String, bytes: Int = 256 * 1024) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() } // likely cut mid-line
        return lines
    }

    static func isError(_ line: Substring) -> Bool { line.contains(" ERROR : ") }

    /// Log lines start with `2026/10/26 12:37:03`, in local time. Read digit by digit: a DateFormatter
    /// takes about 50 µs a line, and the menu reads thousands of lines every 2 s while it's open.
    static func date(of line: String) -> Date? {
        let bytes = Array(line.utf8.prefix(19))
        guard bytes.count == 19 else { return nil }
        func number(_ range: Range<Int>) -> Int32? {
            var value: Int32 = 0
            for byte in bytes[range] {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
                value = value * 10 + Int32(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard bytes[4] == UInt8(ascii: "/"), bytes[7] == UInt8(ascii: "/"), bytes[10] == UInt8(ascii: " "),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19)
        else { return nil }
        var time = tm()
        time.tm_year = year - 1900
        time.tm_mon = month - 1
        time.tm_mday = day
        time.tm_hour = hour
        time.tm_min = minute
        time.tm_sec = second
        time.tm_isdst = -1
        return Date(timeIntervalSince1970: TimeInterval(mktime(&time)))
    }

    /// `2026/10/26 12:37:03 ERROR : read: Connection reset by peer` → `read: Connection reset by peer`
    static func message(ofLogLine line: String) -> String {
        line.range(of: " ERROR : ").map { String(line[$0.upperBound...]) } ?? line
    }

    /// Error lines from the last hour that are still unresolved, oldest first: errors before a mount
    /// last came up (the service logs "Mounted") are over and don't count. `lines` are in time order.
    static func unresolvedErrors(in lines: [LogLine], now: Date = Date()) -> [LogLine] {
        // Reading a date takes a few µs, and the logs hold thousands of old errors: stop at the first that's over an hour old.
        let old = lines.lastIndex { line in
            (line.isError || line.text.hasSuffix(" NOTICE: Mounted"))
                && date(of: line.text).map { now.timeIntervalSince($0) >= 3600 } ?? false
        }
        let lines = lines[(old.map { $0 + 1 } ?? 0)...]
        var lastMounted: [UUID: Date] = [:]
        for line in lines where line.text.hasSuffix(" NOTICE: Mounted") {
            if let date = date(of: line.text) { lastMounted[line.mountID] = date }
        }
        return lines.filter { line in
            guard line.isError, let date = date(of: line.text) else { return false }
            return now.timeIntervalSince(date) < 3600 && date >= lastMounted[line.mountID] ?? .distantPast
        }
    }
}
