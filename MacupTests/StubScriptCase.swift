import AppKit
import SwiftUI
import XCTest

@testable import Macup

/// Base for tests that drive the store end to end against stub scripts rather than real package
/// managers: the subprocess, the log streaming and the history writing are all real, and only the
/// manager at the far end is fake, because the alternative is changing packages on whoever runs them.
@MainActor
class StubScriptCase: XCTestCase {
    var directory = URL(fileURLWithPath: "/tmp")
    let settings = Preferences.shared
    struct SavedPreferences {
        var minAge: Double
        var securityMinAge: Double
        var ignored: Set<String>
        var hideSystem: Bool
        var disabled: Set<Manager>
        var auto: Bool
        var autoInterval: Double
        var notify: Bool
    }
    var saved: SavedPreferences?

    override func setUpWithError() throws {
        // Preferences is the real singleton, and "eligible" depends on it: pin the thresholds so these
        // tests do not depend on what the person running them has configured.
        saved = SavedPreferences(
            minAge: settings.minAgeHours, securityMinAge: settings.securityMinAgeHours,
            ignored: settings.ignoredPackages, hideSystem: settings.hideSystemPackages,
            disabled: settings.disabledManagers, auto: settings.autoUpdate,
            autoInterval: settings.autoUpdateIntervalHours, notify: settings.notificationsEnabled)
        settings.minAgeHours = 0
        settings.securityMinAgeHours = 0
        settings.ignoredPackages = []
        settings.hideSystemPackages = true
        settings.autoUpdate = false
        settings.autoUpdateIntervalHours = 24
        settings.notificationsEnabled = false
        settings.disabledManagers = []
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macup-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A package whose name contains "boom" fails, which is how each test picks the outcome.
        try script(
            "macup-upgrade",
            """
            print "$ upgrading $2"
            [[ "$2" == *boom* ]] && { print "Error: could not upgrade $2" >&2; exit 1 }
            print "upgraded $2"
            """)
        try script(
            "macup-remove",
            """
            print "$ removing $2"
            [[ "$2" == *boom* ]] && { print "Error: could not remove $2" >&2; exit 1 }
            print "removed $2"
            """)
        try script(
            "macup-setup",
            """
            print "$ installing $1"
            [[ "$1" == mas ]] && { print "installed"; exit 0 }
            print "Error: unknown tool" >&2; exit 1
            """)
        // The rescan that follows every action. MACUP_TEST_STILL_OUTDATED keeps one npm package
        // outdated, marked as system-owned so it is skipped for release dates and no registry is
        // contacted.
        try script(
            "macup-scan",
            #"""
            # What to report is read from files beside this script, never from the environment: the app
            # caches the login shell's variables for the life of the process, so anything set here
            # would leak into every later test.
            here=${0:A:h}
            # Every call is recorded, so a test can tell one scan of everything from a scan per manager.
            print -r -- "$*" >> "$here/scan-calls"
            admin=$(cat "$here/admin" 2>/dev/null)
            for m in "$@"; do
              if [[ "$m" == "$admin" ]]; then printf 'M\t%s\tok\tadmin\n' "$m"
              else printf 'M\t%s\tok\t\n' "$m"; fi
            done
            still=$(cat "$here/still-outdated" 2>/dev/null)
            [[ -n "$still" ]] && printf 'P\tnpm\t%s\t1.0.0\t2.0.0\tsystem-global\t\t0\n' "$still"
            # MacUp's own cask, still outdated after an upgrade rescans. Marked system-owned purely so
            # the registry is not asked for a release date during a test.
            [[ -e "$here/outdated-macup" ]] \
              && printf 'P\tbrew\tmacup\t1.0.0\t99.0.0\tsystem-cask\t\t0\n'
            # A rustup toolchain carries its own release date, so nothing is looked up on the network.
            [[ -e "$here/outdated-rustup" ]] \
              && printf 'P\trustup\tstable\t1.0.0\t2.0.0\ttoolchain\t2020-01-01\t0\n'
            """#)
        setenv("MACUP_SCRIPT_DIR", directory.path, 1)
    }

    override func tearDownWithError() throws {
        if let saved {
            settings.minAgeHours = saved.minAge
            settings.securityMinAgeHours = saved.securityMinAge
            settings.ignoredPackages = saved.ignored
            settings.hideSystemPackages = saved.hideSystem
            settings.disabledManagers = saved.disabled
            settings.autoUpdate = saved.auto
            settings.autoUpdateIntervalHours = saved.autoInterval
            settings.notificationsEnabled = saved.notify
        }
        unsetenv("MACUP_SCRIPT_DIR")
        try? FileManager.default.removeItem(at: directory)
    }

    func script(_ name: String, _ body: String) throws {
        let url = directory.appendingPathComponent("\(name).sh")
        try "#!/bin/zsh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// The scan reports this npm package as still outdated after an action, so a failure recorded
    /// against it is not cleared by the rescan.
    func keepOutdated(_ name: String) throws {
        try name.write(to: directory.appendingPathComponent("still-outdated"), atomically: true, encoding: .utf8)
    }

    /// The scan keeps reporting MacUp's own cask as outdated, as Homebrew would until it is upgraded.
    func reportOutdatedSelfCask() throws {
        try "".write(to: directory.appendingPathComponent("outdated-macup"), atomically: true, encoding: .utf8)
    }

    /// The scan reports an outdated rustup toolchain, which carries its own date and so needs no registry.
    func reportOutdatedToolchain() throws {
        try "".write(to: directory.appendingPathComponent("outdated-rustup"), atomically: true, encoding: .utf8)
    }

    /// What the scan was asked to check, one line per call, in order.
    func scanCalls() -> [String] {
        let url = directory.appendingPathComponent("scan-calls")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// The scan reports this manager as needing an administrator password.
    func markNeedsAdmin(_ manager: Manager) throws {
        try manager.rawValue.write(
            to: directory.appendingPathComponent("admin"), atomically: true, encoding: .utf8)
    }

    /// Updating MacUp itself is stubbed out by default: the real path either restarts the app or opens
    /// Sparkle's window, neither of which belongs in a test run.
    func store(
        installSource: InstallSource? = nil, selfUpdate: (@MainActor () async -> Void)? = nil
    )
        -> UpdateStore
    {
        UpdateStore(
            persist: false, directory: directory, installSource: installSource,
            selfUpdate: selfUpdate ?? {})
    }

    func pkg(_ name: String, manager: Manager = .npm, kind: String = "global") -> OutdatedPackage {
        var p = OutdatedPackage(
            manager: manager, name: name, installed: "1.0.0", latest: "2.0.0", kind: kind, extra: "")
        p.releaseDate = Date().addingTimeInterval(-40 * 3600)
        p.dateSource = .registry
        return p
    }
}
