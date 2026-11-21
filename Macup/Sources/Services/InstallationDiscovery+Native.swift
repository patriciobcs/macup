import Foundation

extension InstallationDiscovery {
    func nativeCLIs() async -> [InstalledItem] {
        var items: [InstalledItem] = []
        for name in ["claude", "devin"] {
            guard let executable = environment.executable(name),
                let output = try? await environment.execute(executable, ["--version"]),
                let current = version(output.stdout)
            else { continue }
            let owner = environment.owner(of: executable)
            let action =
                owner == nil
                ? InstallationAction(executable: executable, arguments: ["update"], manualOnly: name == "devin") : nil
            var reference = packageReference(
                path: URL(fileURLWithPath: executable).resolvingSymlinksInPath(),
                root: URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent(),
                owner: owner ?? "Native installer", name: name, action: action, isDefault: true)
            reference.identityPath = executable
            var item = InstalledItem(
                manager: .tools, name: name, version: current, reference: reference,
                state: owner == nil ? .active : .managed)
            if owner == nil { item = await nativeCLIVersion(item) }
            items.append(item)
        }
        return items
    }

    private func nativeCLIVersion(_ original: InstalledItem) async -> InstalledItem {
        var item = original
        do {
            if item.name == "claude" {
                let settings =
                    environment.object(environment.home.appendingPathComponent(".claude/settings.json")) ?? [:]
                let settingsEnvironment = settings["env"] as? [String: String] ?? [:]
                if settingsEnvironment["DISABLE_UPDATES"] == "1" || environment.variables["DISABLE_UPDATES"] == "1" {
                    item.reference.update = nil
                    item.note = "Updates disabled by Claude's settings"
                    item.state = .manual
                    return item
                }
                let configured = settings["autoUpdatesChannel"] as? String ?? "latest"
                let channel = configured == "stable" ? "stable" : "latest"
                item.latest = try await text("https://downloads.claude.ai/claude-code-releases/\(channel)")
                if let minimum = settings["minimumVersion"] as? String, let latest = item.latest,
                    Version.isNewer(minimum, than: latest)
                {
                    item.latest = nil
                    item.note = "The release channel is below Claude's minimumVersion pin"
                }
                item.note = item.note.isEmpty ? "\(channel.capitalized) release channel" : item.note
            } else {
                let manifest = try await json("https://static.devin.ai/cli/current/manifest.json") as? [String: Any]
                item.latest = manifest?["version"] as? String
                item.note = "Native Devin distribution; update only when selected"
            }
            guard let latest = item.latest, version(latest) == latest else {
                if item.latest != nil { throw DiscoveryError.invalid("Invalid native CLI release version") }
                return item
            }
        } catch {
            item.latest = nil
            item.note = "Could not check \(item.name): \(error.localizedDescription)"
            failures.append(item.note)
        }
        return item
    }

    func orbStack() async -> [InstalledItem] {
        let standard = environment.system("Applications/OrbStack.app")
            .appendingPathComponent("Contents/MacOS/bin/orbctl").path
        guard let executable = environment.executable("orbctl") ?? environment.executable(standard) else { return [] }
        let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        let owner =
            environment.owner(of: executable)
            ?? (resolved.path.contains(".app/") ? homebrewAppOwner(standardAppRoot(resolved.path)) : nil)
        guard let output = try? await environment.execute(executable, ["version"]),
            let current = version(output.stdout)
        else {
            failures.append("Could not read the OrbStack version")
            return []
        }
        let action = owner == nil ? InstallationAction(executable: executable, arguments: ["update"]) : nil
        let root =
            resolved.path.contains(".app/") ? standardAppRoot(resolved.path) : resolved.deletingLastPathComponent()
        let reference = packageReference(
            path: resolved, root: root,
            owner: owner ?? "OrbStack", name: "OrbStack", action: action, isDefault: true)
        var item = InstalledItem(
            manager: .orbstack, name: "OrbStack", version: current, reference: reference,
            state: owner == nil ? .active : .managed)
        if owner == nil {
            do {
                let check = try await environment.execute(executable, ["update", "--check"])
                if check.status == 0 {
                    item.latest = current
                } else if check.status == 3 {
                    item.latest = versions(check.combined).filter { Version.isNewer($0, than: current) }
                        .max { Version.compare($0, $1) == .orderedAscending }
                    if item.latest == nil {
                        // The CLI's exit status is authoritative even when it omits the target label.
                        item.latest = "Available"
                        item.reference.release = "available-after-\(current)"
                        item.updateAvailable = true
                        item.note = "OrbStack reports an update; its updater chooses the matching build"
                    }
                } else {
                    throw DiscoveryError.invalid(check.stderr.isEmpty ? "OrbStack update check failed" : check.stderr)
                }
            } catch {
                item.note = error.localizedDescription
                failures.append("OrbStack: \(item.note)")
            }
        }
        return [item]
    }

    private func standardAppRoot(_ path: String) -> URL {
        let prefix = path.components(separatedBy: ".app/")[0] + ".app"
        return URL(fileURLWithPath: prefix)
    }

    func versions(_ output: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)+(?:[-+][A-Za-z0-9.-]+)?"#) else {
            return []
        }
        let text = output as NSString
        return pattern.matches(in: output, range: NSRange(location: 0, length: text.length)).map {
            text.substring(with: $0.range)
        }
    }
}
