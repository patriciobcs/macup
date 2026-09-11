import AppKit
import Foundation
import Sparkle

/// How this copy of MacUp got onto the Mac, which decides who updates it.
enum InstallSource {
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

    private init() {
        source = InstallSource.detect()
        if source == .direct, ProcessInfo.processInfo.environment["MACUP_SCREENSHOTS"] == nil {
            controller = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        } else {
            controller = nil
        }
    }

    /// Opens Sparkle's own check dialog. No-op for Homebrew installs.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
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
