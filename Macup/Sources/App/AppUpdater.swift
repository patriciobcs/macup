import AppKit
import Foundation
import Sparkle

/// How this copy of MacUp got onto the Mac, which decides who updates it.
enum InstallSource: Equatable {
    /// Installed with `brew install --cask macup`: Homebrew owns updates, Sparkle stays off.
    case homebrew
    /// Downloaded directly: Sparkle updates it, the brew cask (if any) is not involved.
    case direct

    /// Homebrew installs the cask's app into /Applications and keeps its metadata in the Caskroom. Both
    /// must hold: a downloaded copy running from elsewhere stays on Sparkle even if a cask exists.
    static func detect(bundlePath: String = Bundle.main.bundlePath) -> InstallSource {
        let caskrooms = ["/opt/homebrew/Caskroom/macup", "/usr/local/Caskroom/macup"]
        let hasCask = caskrooms.contains { FileManager.default.fileExists(atPath: $0) }
        let inApplications = bundlePath.hasPrefix("/Applications/")
        return hasCask && inApplications ? .homebrew : .direct
    }
}

/// Sparkle wrapper. The updater is only created for direct installs.
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    let source: InstallSource
    private let controller: SPUStandardUpdaterController?
    /// Sparkle keeps its delegate weakly, so the probe lives here.
    private let probe = UpdateProbe()

    private init() {
        source = InstallSource.detect()
        // Never in a test or a render: Sparkle would find the published release newer than this build
        // and wait at its update window for a click that is not coming. See AutomatedRun.
        if source == .direct, !AutomatedRun.isActive {
            controller = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: probe, userDriverDelegate: nil)
        } else {
            controller = nil
        }
        probe.onUpdateFound = { Task { @MainActor in AppUpdater.shared.checkForUpdates() } }
    }

    /// Whether a real Sparkle updater is running behind this. False for Homebrew copies, and for any
    /// automated run.
    var hasLiveUpdater: Bool { controller != nil }

    /// Opens Sparkle's own check dialog. No-op for Homebrew installs.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    /// Checks without a window of its own, and opens Sparkle's usual one only when there is an update to
    /// offer, never to say that MacUp is already up to date. A probe rather than a background check:
    /// Sparkle reserves those for its own schedule, and may hold what they find back as a reminder.
    func checkForUpdatesQuietly() {
        guard let updater = controller?.updater, !updater.sessionInProgress else { return }
        probe.begin()
        updater.checkForUpdateInformation()
    }

    /// Starts a fresh copy of the (just replaced) app bundle and quits this one.
    static func relaunch() {
        // The path is passed as an argument, never interpolated into the shell string.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// Turns a quiet probe into Sparkle's usual window, but only when the probe found an update. Sparkle
/// reports every kind of check here, including its own scheduled ones, which are left alone.
final class UpdateProbe: NSObject, SPUUpdaterDelegate {
    var onUpdateFound: (() -> Void)?
    private var probing = false
    private var found = false

    func begin() {
        probing = true
        found = false
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { noteFound() }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        finished(updateCheck)
    }

    func noteFound() { if probing { found = true } }

    /// Whether the probe that just ended found something worth showing.
    @discardableResult
    func finished(_ check: SPUUpdateCheck) -> Bool {
        guard check == .updateInformation, probing else { return false }
        probing = false
        guard found else { return false }
        found = false
        onUpdateFound?()
        return true
    }
}
