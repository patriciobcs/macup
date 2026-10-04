import SwiftUI

/// Settings row for `macup` in a terminal: where it is, and a button to put it on the PATH.
struct CommandLineToolRow: View {
    @Environment(UpdateStore.self) private var store
    @State private var state: CommandLineInstaller.State?
    @State private var error: String?

    private var executable: URL? { Bundle.main.executableURL }

    var body: some View {
        LabeledContent {
            switch state {
            case .notInstalled(let link, _):
                Button("Install") { change { try CommandLineInstaller.install(executable: $0, at: link) } }
                    .controlSize(.small)
            case .installed(let link):
                Button("Remove") { change { _ in try CommandLineInstaller.remove(link) } }.controlSize(.small)
            case .byHomebrew, .taken, nil:
                EmptyView()
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Command line tool")
                Text(detail).font(.caption).foregroundStyle(error == nil ? .secondary : Color.red)
                    .textSelection(.enabled)
            }
        }
        .task { await refresh() }
    }

    private var detail: String {
        if let error { return error }
        let tilde = { (url: URL) in url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        switch state {
        case nil: return "Run MacUp from a terminal: macup status, macup upgrade."
        case .notInstalled(let link, true):
            return "Run MacUp from a terminal: macup status, macup upgrade. Installs a link at \(tilde(link))."
        case .notInstalled(let link, false):
            return "Installs a link at \(tilde(link)). That folder is not on your PATH yet, so add it to your shell "
                + "profile to type macup."
        case .installed(let link): return "Installed at \(tilde(link)). Try macup status in a terminal."
        case .byHomebrew(let link): return "Installed by Homebrew at \(tilde(link)). Try macup status in a terminal."
        case .taken(let link): return "\(tilde(link)) is another program called macup, so MacUp leaves it alone."
        }
    }

    private func change(_ body: (URL) throws -> Void) {
        guard let executable else { return }
        do {
            try body(executable)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        Task { await refresh() }
    }

    private func refresh() async {
        let path = await ShellEnvironment.shared.userPATH()
        state = CommandLineInstaller.state(path: path, homebrewInstall: store.installSource == .homebrew)
    }
}
