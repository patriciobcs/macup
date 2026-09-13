import Foundation

/// Whether this process is a test run or a screenshot render rather than a person using the app.
///
/// Anything that asks the user for permission has to be skipped in those runs. There is nobody to
/// answer the prompt, so the request does not fail — it simply never returns, and takes the run with
/// it: a notification request that waits forever, or Sparkle's update window waiting for a click.
/// A build made for either run also carries build number 1, which is older than anything published.
enum AutomatedRun {
    static var isActive: Bool {
        let env = ProcessInfo.processInfo.environment
        // XCTest sets the first for every test process; the second is this app's own render mode.
        return env["XCTestConfigurationFilePath"] != nil || env["MACUP_SCREENSHOTS"] != nil
    }
}
