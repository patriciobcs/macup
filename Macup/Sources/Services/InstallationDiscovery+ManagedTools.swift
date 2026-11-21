import Foundation

extension InstallationDiscovery {
    func managedInstallations(_ manager: Manager) async -> [InstalledItem] {
        switch manager {
        case .extensions: await githubExtensions()
        case .dotnet: await dotnetTools()
        case .dart: await dartTools()
        case .nixprofile: await nixProfiles()
        case .asdf: await asdfRuntimes()
        case .volta: await voltaTools()
        default: []
        }
    }

    private func githubExtensions() async -> [InstalledItem] {
        guard let gh = environment.executable("gh") else { return [] }
        do {
            let listing = try await environment.execute(gh, ["extension", "list"])
            guard listing.status == 0 else { throw DiscoveryError.invalid(listing.stderr) }
            var items: [InstalledItem] = []
            for line in listing.stdout.split(separator: "\n") {
                let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard
                    let repository = fields.first(where: {
                        $0.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
                    })
                else { continue }
                let current = fields.compactMap { version($0) }.first ?? "Unknown"
                let name = String(repository.split(separator: "/").last ?? "")
                let root =
                    environment.variables["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
                    ?? environment.home.appendingPathComponent(".local/share")
                let directory = root.appendingPathComponent("gh/extensions/\(name)")
                let action = InstallationAction(
                    executable: gh, arguments: ["extension", "upgrade", name], manualOnly: false)
                let remove = InstallationAction(
                    executable: gh, arguments: ["extension", "remove", name], title: "Remove")
                var item = InstalledItem(
                    manager: .extensions, name: name, version: current,
                    reference: packageReference(
                        path: directory, root: root, owner: "GitHub CLI", name: repository, action: action,
                        remove: remove))
                let metadata = try await environment.execute(gh, ["api", "repos/\(repository)"])
                let document = parseObject(metadata.stdout)
                if document?["archived"] as? Bool == true {
                    item.state = .manual
                    item.reference.update = nil
                    item.note = "The extension's repository is archived; review removal instead of updating"
                } else {
                    let release = try await environment.execute(gh, ["api", "repos/\(repository)/releases/latest"])
                    if let tag = parseObject(release.stdout)?["tag_name"] as? String { item.latest = version(tag) }
                    if release.status != 0 { item.note = "GitHub could not report a release for this extension" }
                }
                items.append(item)
            }
            return items
        } catch {
            failures.append("GitHub extensions: \(error.localizedDescription)")
            return []
        }
    }

    private func dotnetTools() async -> [InstalledItem] {
        guard let dotnet = environment.executable("dotnet") else { return [] }
        do {
            let listing = try await environment.execute(dotnet, ["tool", "list", "--global"])
            guard listing.status == 0 else { throw DiscoveryError.invalid(listing.stderr) }
            let root = environment.home.appendingPathComponent(".dotnet/tools")
            var items: [InstalledItem] = []
            for row in versionedRows(listing.stdout) {
                let directory = root.appendingPathComponent(".store/\(row.name.lowercased())")
                let action = InstallationAction(
                    executable: dotnet, arguments: ["tool", "update", "--global", row.name], manualOnly: false)
                let remove = InstallationAction(
                    executable: dotnet, arguments: ["tool", "uninstall", "--global", row.name], title: "Remove")
                var item = InstalledItem(
                    manager: .dotnet, name: row.name, version: row.version,
                    reference: packageReference(
                        path: directory, root: root, owner: ".NET CLI", name: row.name, action: action, remove: remove))
                if await hasCustomNugetSources(dotnet) {
                    item.note = "Uses configured NuGet sources; check and update with the .NET CLI"
                    item.reference.update?.manualOnly = true
                } else {
                    do {
                        let document =
                            try await json("https://api.nuget.org/v3-flatcontainer/\(row.name.lowercased())/index.json")
                            as? [String: Any]
                        item.latest = stableMaximum(document?["versions"] as? [String] ?? [])
                    } catch {
                        item.note = "Could not check this tool: \(error.localizedDescription)"
                        failures.append(item.note)
                    }
                }
                items.append(item)
            }
            return items
        } catch {
            failures.append(".NET global tools: \(error.localizedDescription)")
            return []
        }
    }

    private func hasCustomNugetSources(_ executable: String) async -> Bool {
        let roots = [
            environment.home.appendingPathComponent(".nuget/NuGet/NuGet.Config"),
            environment.home.appendingPathComponent(".config/NuGet/NuGet.Config"),
            environment.home.appendingPathComponent("NuGet.Config"),
            environment.home.appendingPathComponent("nuget.config"),
        ]
        if roots.contains(where: { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            let sources =
                text.components(separatedBy: "<packageSources").dropFirst().joined()
                .components(separatedBy: "</packageSources>").first ?? ""
            guard sources.contains("<add") else { return false }
            // A configured feed can also be a local directory. Do not assume public NuGet when the
            // user supplied their own source list.
            return true
        }) {
            return true
        }
        // Include machine-level NuGet configs too. An unrecognised source listing stays native.
        guard
            let result = try? await environment.execute(executable, ["nuget", "list", "source", "--format", "short"]),
            result.status == 0
        else { return true }
        let enabled = result.stdout.split(separator: "\n").filter { $0.hasPrefix("E ") }.map {
            String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return enabled.isEmpty || enabled.contains { $0 != "https://api.nuget.org/v3/index.json" }
    }

    private func dartTools() async -> [InstalledItem] {
        guard let dart = environment.executable("dart") else { return [] }
        do {
            let listing = try await environment.execute(dart, ["pub", "global", "list"])
            guard listing.status == 0 else { throw DiscoveryError.invalid(listing.stderr) }
            let cache =
                environment.variables["PUB_CACHE"].map { URL(fileURLWithPath: $0) }
                ?? environment.home.appendingPathComponent(".pub-cache")
            let host = environment.variables["PUB_HOSTED_URL"] ?? "https://pub.dev"
            var items: [InstalledItem] = []
            for row in versionedRows(listing.stdout) {
                let directory = cache.appendingPathComponent("global_packages/\(row.name)")
                let local = listing.stdout.split(separator: "\n").contains {
                    $0.hasPrefix(row.name + " ")
                        && ($0.lowercased().contains("from path") || $0.lowercased().contains("from git"))
                }
                let action =
                    local
                    ? nil
                    : InstallationAction(
                        executable: dart, arguments: ["pub", "global", "activate", row.name], manualOnly: false)
                let remove = InstallationAction(
                    executable: dart, arguments: ["pub", "global", "deactivate", row.name], title: "Remove")
                var item = InstalledItem(
                    manager: .dart, name: row.name, version: row.version,
                    reference: packageReference(
                        path: directory, root: cache, owner: "Dart Pub", name: row.name, action: action, remove: remove),
                    state: local ? .manual : .active)
                if !local {
                    do {
                        let document =
                            try await json(
                                host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                                    + "/api/packages/\(row.name)") as? [String: Any]
                        item.latest = (document?["latest"] as? [String: Any])?["version"] as? String
                    } catch {
                        item.note = "Could not check this tool: \(error.localizedDescription)"
                        failures.append(item.note)
                    }
                } else {
                    item.note = "Activated from a checkout; update through its source project"
                }
                items.append(item)
            }
            return items
        } catch {
            failures.append("Dart global tools: \(error.localizedDescription)")
            return []
        }
    }

    func parseObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func versionedRows(_ text: String) -> [(name: String, version: String)] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2,
                fields[0].range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil,
                version(fields[1]) == fields[1]
            else { return nil }
            return (fields[0], fields[1])
        }
    }

    func stableMaximum(_ versions: [String]) -> String? {
        versions.filter { !$0.contains("-") && version($0) == $0 }
            .max { Version.compare($0, $1) == .orderedAscending }
    }
}
