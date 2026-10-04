import Foundation

/// Puts `macup` on the PATH for a downloaded copy, as a link to the app's own executable. A Homebrew
/// install already has one: the cask links it.
enum CommandLineInstaller {
    enum State: Equatable {
        /// Nothing called macup on the PATH. `onPath` says whether the suggested folder is on it.
        case notInstalled(suggested: URL, onPath: Bool)
        /// A link to MacUp that this app can remove again.
        case installed(URL)
        /// Homebrew's link, which Homebrew owns.
        case byHomebrew(URL)
        /// Something else called macup comes first on the PATH, and is left alone.
        case taken(URL)
    }

    static let name = CommandLineRequest.toolName

    /// The user's own bin folder first: it needs no password and is nobody else's. Homebrew's comes
    /// after, since a link of ours there would stand in the way of the cask's own.
    static func candidates(home: String) -> [String] {
        ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    static func state(
        path: String, home: String = NSHomeDirectory(), homebrewInstall: Bool, fileManager: FileManager = .default
    ) -> State {
        let entries = path.split(separator: ":").map(String.init)
        for dir in entries {
            let link = URL(fileURLWithPath: dir).appendingPathComponent(name)
            guard fileManager.fileExists(atPath: link.path) else { continue }
            guard pointsAtMacUp(link) else { return .taken(link) }
            let fromHomebrew =
                homebrewInstall && ["/opt/homebrew/bin", "/usr/local/bin"].contains(dir)
                && (try? fileManager.destinationOfSymbolicLink(atPath: link.path))?.contains("/Applications/") == true
            return fromHomebrew ? .byHomebrew(link) : .installed(link)
        }
        let writable = candidates(home: home).first { dir in
            entries.contains(dir)
                && (fileManager.isWritableFile(atPath: dir)
                    || (dir.hasPrefix(home) && !fileManager.fileExists(atPath: dir)))
        }
        let dir = writable ?? candidates(home: home)[0]
        return .notInstalled(suggested: URL(fileURLWithPath: dir).appendingPathComponent(name), onPath: writable != nil)
    }

    /// Whether this file leads to a MacUp executable, this copy or another one.
    static func pointsAtMacUp(_ link: URL) -> Bool {
        let real = link.resolvingSymlinksInPath().path
        return real.hasSuffix(".app/Contents/MacOS/MacUp")
    }

    static func install(executable: URL, at link: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: executable)
    }

    /// Only ever a link: a real file called macup is somebody else's.
    static func remove(_ link: URL, fileManager: FileManager = .default) throws {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil else { return }
        try fileManager.removeItem(at: link)
    }
}
