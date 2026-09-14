import Foundation
import Observation

/// The commands the scripts would run, read from the scripts once and kept for the settings window.
///
/// Separate from UpdateStore because nothing about scanning or updating depends on it: it exists so a
/// person can see what MacUp is about to run on their machine, and put something else in its place.
@Observable @MainActor
final class CommandCatalog {
    static let shared = CommandCatalog()

    private(set) var book = CommandBook()
    private var loaded = false

    /// Read on first use rather than at launch: it costs a subprocess, and only the settings window
    /// ever needs it.
    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        book = await ScriptRunner.commands()
    }

    /// The command in force for a manager and phase: what the user put there, or the built-in one.
    func command(_ phase: CommandPhase, _ manager: Manager, settings: Preferences) -> String {
        settings.commandOverrides[CommandBook.storeKey(phase, manager)]
            ?? book[manager].defaults[phase] ?? ""
    }

    func isChanged(_ phase: CommandPhase, _ manager: Manager, settings: Preferences) -> Bool {
        settings.commandOverrides[CommandBook.storeKey(phase, manager)] != nil
    }

    /// Stores a replacement, or forgets it when it is empty or the same as the built-in one, so that
    /// "Reset" and "type the default back in" end up in the same place.
    func setCommand(
        _ text: String, _ phase: CommandPhase, _ manager: Manager, settings: Preferences
    ) {
        let key = CommandBook.storeKey(phase, manager)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == book[manager].defaults[phase] {
            settings.commandOverrides.removeValue(forKey: key)
        } else {
            settings.commandOverrides[key] = trimmed
        }
    }
}
