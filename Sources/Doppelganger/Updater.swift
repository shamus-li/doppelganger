import AppKit
import Observation
import Sparkle

/// Checks the GitHub releases for a newer build (Sparkle, with the feed and key in Info.plist), downloads
/// it in the background, and offers it in the status menu instead of in Sparkle's windows.
@MainActor
@Observable
final class Updater: NSObject, SPUUserDriver {
    /// The version of a downloaded update waiting for the user to restart into it.
    private(set) var ready: String?
    private(set) var checking = false
    /// The result of a check the user asked for, until the menu has shown it.
    private(set) var status: String?
    @ObservationIgnored private var install: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var version: String?
    @ObservationIgnored private var updater: SPUUpdater!

    override init() {
        super.init()
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
        do { try updater.start() } catch { status = error.localizedDescription }
    }

    func checkForUpdates() {
        status = nil
        updater.checkForUpdates()
    }

    func restartToUpdate() { install?(.install) }

    func clearStatus() { status = nil }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { checking = true }

    /// Downloads a new update right away; one downloaded earlier waits for the user.
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        checking = false
        version = appcastItem.displayVersionString
        if state.stage == .notDownloaded {
            reply(.install)
        } else {
            offer(reply)
        }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { offer(reply) }

    private func offer(_ reply: @escaping (SPUUserUpdateChoice) -> Void) {
        install = reply
        ready = version
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        checking = false
        status = "Doppelganger is up to date."
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        checking = false
        status = error.localizedDescription
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }

    func dismissUpdateInstallation() {
        checking = false
        install = nil
        ready = nil
    }
}
