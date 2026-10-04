import SwiftUI

/// One executable, two programs: the menu bar app, and `macup` in a terminal. Which one is decided
/// before anything of the app starts, so a command-line run never puts an icon in the menu bar.
@main
enum Entry {
    @MainActor
    static func main() {
        restartFromRealPathIfLinked()
        switch CommandLineRequest.parse(CommandLine.arguments) {
        case .app: MacupApp.main()
        case .run(let request): CommandLineTool.start(request)
        case .invalid(let message): CommandLineTool.fail(message)
        }
    }

    /// Started through a link (Homebrew's `macup`, or the one Settings installs), the executable cannot
    /// see the app around it, and the scripts, the settings and the version all come from there. So it
    /// starts again from its real path, keeping the name it was called by.
    private static func restartFromRealPathIfLinked() {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var path = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&path, &size) == 0, let real = realpath(path, nil) else { return }
        defer { free(real) }
        guard strcmp(real, path) != 0 else { return }
        execv(real, CommandLine.unsafeArgv)
    }
}
