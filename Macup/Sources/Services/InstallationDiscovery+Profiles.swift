import Foundation

extension InstallationDiscovery {
    func nixProfiles() async -> [InstalledItem] {
        guard let nix = environment.executable("nix") else { return [] }
        var profiles = [
            environment.home.appendingPathComponent(".nix-profile"),
            environment.home.appendingPathComponent(".local/state/nix/profiles/profile"),
        ]
        if let custom = environment.variables["NIX_PROFILE"], custom.hasPrefix("/") {
            profiles.insert(URL(fileURLWithPath: custom), at: 0)
        }
        var visited: Set<String> = []
        var items: [InstalledItem] = []
        for profile in profiles where FileManager.default.fileExists(atPath: profile.path) {
            if FileManager.default.fileExists(atPath: profile.appendingPathComponent("manifest.nix").path),
                !FileManager.default.fileExists(atPath: profile.appendingPathComponent("manifest.json").path)
            {
                continue
            }
            guard visited.insert(profile.resolvingSymlinksInPath().path).inserted else { continue }
            do {
                let listing = try await environment.execute(
                    nix, ["profile", "list", "--profile", profile.path, "--json"])
                guard listing.status == 0, let document = parseObject(listing.stdout) else {
                    throw DiscoveryError.invalid("Nix could not list this profile")
                }
                let entries =
                    document["elements"] as? [String: [String: Any]]
                    ?? document.compactMapValues { $0 as? [String: Any] }
                for (selector, value) in entries.sorted(by: { $0.key < $1.key }) {
                    guard !selector.isEmpty, !selector.hasPrefix("-") else { continue }
                    let path = (value["storePaths"] as? [String])?.first ?? profile.path
                    let current = version(URL(fileURLWithPath: path).lastPathComponent) ?? "Pinned"
                    let original = value["originalUrl"] as? String ?? ""
                    let pinned =
                        original.isEmpty || original.contains("rev=")
                        || original.range(of: #"/[a-fA-F0-9]{40}(?:[?/#]|$)"#, options: .regularExpression) != nil
                    let action =
                        pinned
                        ? nil
                        : InstallationAction(
                            executable: nix,
                            arguments: ["profile", "upgrade", "--profile", profile.path, "--", selector],
                            title: "Upgrade Profile")
                    let remove = InstallationAction(
                        executable: nix, arguments: ["profile", "remove", "--profile", profile.path, "--", selector],
                        title: "Remove")
                    var item = InstalledItem(
                        manager: .nixprofile, name: selector, version: current,
                        reference: packageReference(
                            path: profile, root: profile.deletingLastPathComponent(), owner: "Nix profile",
                            name: selector, action: action,
                            remove: remove),
                        state: .manual,
                        note: pinned
                            ? "Pinned profile reference; update its pin explicitly"
                            : "Updates only this profile entry; project flake.lock files are unchanged")
                    guard !pinned else {
                        items.append(item)
                        continue
                    }
                    let check = try await environment.execute(
                        nix, ["profile", "upgrade", "--profile", profile.path, "--dry-run", "--", selector])
                    if check.status == 0 {
                        let stem =
                            URL(fileURLWithPath: path).lastPathComponent.components(separatedBy: "-" + current).first
                            ?? ""
                        let package = stem.split(separator: "-", maxSplits: 1).last.map(String.init) ?? selector
                        let candidates = check.combined.components(separatedBy: package + "-").dropFirst()
                            .compactMap { version($0) }.filter { Version.isNewer($0, than: current) }
                        item.latest = stableMaximum(candidates)
                    } else {
                        item.note = "Could not preview this profile update: \(check.stderr)"
                    }
                    items.append(item)
                }
            } catch { failures.append("Nix profile \(profile.lastPathComponent): \(error.localizedDescription)") }
        }
        return items
    }

    func asdfRuntimes() async -> [InstalledItem] {
        guard let asdf = environment.executable("asdf") else { return [] }
        do {
            let listing = try await environment.execute(asdf, ["current"])
            guard listing.status == 0 else { throw DiscoveryError.invalid(listing.stderr) }
            let root =
                environment.variables["ASDF_DATA_DIR"].map { URL(fileURLWithPath: $0) }
                ?? environment.home.appendingPathComponent(".asdf")
            let sdkVersion = try? await environment.execute(asdf, ["version"])
            let modern = Version.compare(version(sdkVersion?.stdout ?? "") ?? "0", "0.16") != .orderedAscending
            var items: [InstalledItem] = []
            for row in versionedRows(listing.stdout) {
                let series = runtimeSeries(row.name, version: row.version)
                let lookup = try? await environment.execute(asdf, ["latest", row.name, series])
                let candidate = lookup?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let latest =
                    lookup?.status == 0 && version(candidate) == candidate && candidate.hasPrefix(series)
                    ? candidate : nil
                if latest == nil { failures.append("Could not check asdf \(row.name)") }
                let action = latest.map { target in
                    let select = InstallationCommand(
                        executable: asdf,
                        arguments: modern ? ["set", "-u", row.name, target] : ["global", row.name, target])
                    return InstallationAction(
                        executable: asdf, arguments: ["install", row.name, target],
                        title: "Update Runtime", followUp: [select])
                }
                let path = root.appendingPathComponent("installs/\(row.name)/\(row.version)")
                var reference = packageReference(path: path, root: root, owner: "asdf", name: row.name, action: action)
                reference.identityPath = root.appendingPathComponent("installs/\(row.name)").path
                items.append(
                    InstalledItem(
                        manager: .asdf, name: row.name, version: row.version,
                        reference: reference,
                        latest: latest,
                        note: "Updates the home tool selection; project .tool-versions files are unchanged"))
            }
            return items
        } catch {
            failures.append("asdf: \(error.localizedDescription)")
            return []
        }
    }

    func voltaTools() async -> [InstalledItem] {
        guard let volta = environment.executable("volta") else { return [] }
        do {
            let listing = try await environment.execute(volta, ["list", "--default", "--format", "plain"])
            guard listing.status == 0 else { throw DiscoveryError.invalid(listing.stderr) }
            let root =
                environment.variables["VOLTA_HOME"].map { URL(fileURLWithPath: $0) }
                ?? environment.home.appendingPathComponent(".volta")
            var items: [InstalledItem] = []
            for line in listing.stdout.split(separator: "\n") {
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard let specification = fields.first(where: { $0.contains("@") && !$0.hasPrefix("(") }),
                    let delimiter = specification.lastIndex(of: "@")
                else { continue }
                let name = String(specification[..<delimiter])
                let current = String(specification[specification.index(after: delimiter)...])
                guard validNpmName(name), version(current) == current else { continue }
                let latest: String?
                if name == "node" {
                    latest = try await latestNode(current)
                } else {
                    // Native npm preserves private registries, authentication and mirror settings.
                    let lookup = environment.executable("npm")
                    let response =
                        lookup == nil
                        ? nil : try? await environment.execute(lookup ?? "", ["view", name, "version", "--json"])
                    let value =
                        response?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
                    latest = response?.status == 0 && version(value) == value ? value : nil
                }
                let action = latest.map {
                    InstallationAction(
                        executable: volta, arguments: ["install", "\(name)@\($0)"], title: "Update Runtime")
                }
                items.append(
                    InstalledItem(
                        manager: .volta, name: name, version: current,
                        reference: packageReference(path: root, root: root, owner: "Volta", name: name, action: action),
                        latest: latest, note: "Updates Volta's home selection; project package.json pins are unchanged")
                )
            }
            return items
        } catch {
            failures.append("Volta: \(error.localizedDescription)")
            return []
        }
    }

    private func runtimeSeries(_ name: String, version current: String) -> String {
        let components = current.split(separator: ".")
        return components.prefix(["python", "ruby", "golang"].contains(name) ? 2 : 1).joined(separator: ".") + "."
    }
}
