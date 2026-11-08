import Foundation
import Testing
@testable import Doppelganger

@Test func countsOnlyRecentErrorLines() throws {
    let now = try #require(LogReader.date(of: "2026/10/26 13:00:00"))
    let mount = UUID()
    let lines = [
        "2026/10/26 11:30:00 ERROR : old: failed",
        "2026/10/26 12:37:03 ERROR : read: Connection reset by peer",
        "2026/10/26 12:41:00 NOTICE: gpu-cluster isn't answering",
    ].enumerated().map { LogLine(id: $0.offset, mountID: mount, text: $0.element, isError: LogReader.isError(Substring($0.element))) }
    let errors = LogReader.unresolvedErrors(in: lines, now: now)
    #expect(errors.map(\.id) == [1])
    #expect(LogReader.message(ofLogLine: errors[0].text) == "read: Connection reset by peer")
}

// /etc/auto_master as shipped on this Mac (macOS 27.0.1).
private let autoMaster = """
    #
    # Automounter master map
    #
    +auto_master\t\t# Use directory service
    #/net\t\t\t-hosts\t\t-nobrowse,hidefromfinder,nosuid
    /home\t\t\tauto_home\t-nobrowse,hidefromfinder
    /Network/Servers\t-fstab
    /-\t\t\t-static

    """

@Test func commentsOutOnlyTheHomeMap() {
    let edited = FolderSetup.disablingHomeMap(autoMaster)
    #expect(edited == autoMaster.replacingOccurrences(of: "\n/home\t", with: "\n#/home\t"))
    #expect(FolderSetup.disablingHomeMap(edited) == edited)
}

@Test func restoresTheHomeMapAndLeavesOtherCommentsAlone() {
    let restored = FolderSetup.restoringHomeMap(FolderSetup.disablingHomeMap(autoMaster))
    #expect(restored == autoMaster)
    #expect(restored.contains("#/net"))
}

@Test func errorsBeforeTheMountCameUpAreResolved() throws {
    let now = try #require(LogReader.date(of: "2026/10/26 16:00:00"))
    // Two mounts may share a name; they're told apart by ID.
    let scratch = UUID(), share = UUID()
    let lines = [
        (scratch, "2026/10/26 15:47:14 ERROR : remote host has disconnected"),
        (scratch, "2026/10/26 15:49:10 NOTICE: Mounted"),
        (share, "2026/10/26 15:47:14 ERROR : remote host has disconnected"),
        (scratch, "2026/10/26 15:55:00 ERROR : read: Connection reset by peer"),
    ].enumerated().map { LogLine(id: $0.offset, mountID: $0.element.0, mount: "gpu-cluster", text: $0.element.1,
                                 isError: LogReader.isError(Substring($0.element.1))) }
    #expect(LogReader.unresolvedErrors(in: lines, now: now).map(\.id) == [2, 3])
}

@Test func rejectsLocalPathsThatLeaveTheirFolder() {
    func mount(_ path: String) -> MountConfig { MountConfig(host: "h", remotePath: "/r", localPath: path) }
    for path in ["/home/../etc/x", "/home/./x", "/home//x", "/scratch/"] {
        #expect(!mount(path).hasPlainPath, "\(path)")
        #expect(mount(path).problem(among: []) != nil, "\(path)")
    }
    #expect(mount("/home/alex").hasPlainPath)
}

// Lines ssh wrote to the logs when the server stopped answering.
@Test func sshTimeoutsAreConnectionLoss() {
    for line in [
        "Read from remote host 100.105.146.41: Operation timed out",
        "Connection to 100.105.146.41 port 22 timed out",
        "Connection timed out during banner exchange",
        "ssh_dispatch_run_fatal: Connection to 100.105.146.41 port 22: Operation timed out",
    ] {
        #expect(MountSupervisor.isConnectionLoss(Substring(line)), "\(line)")
    }
    #expect(!MountSupervisor.isConnectionLoss("read: Permission denied"))
}
