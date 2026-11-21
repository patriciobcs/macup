import Foundation

extension InstallationDiscovery {
    func npmInstallations(existing: inout ScanResult) async -> [InstalledItem] {
        let npm = environment.executable("npm")
        let primaryResult = npm == nil ? nil : try? await environment.execute(npm ?? "", ["prefix", "-g"])
        let primary = primaryResult?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefixes = npmPrefixes(primary)
        var visited: Set<String> = []
        var items: [InstalledItem] = []
        for prefix in prefixes where !prefix.isEmpty {
            let root = URL(fileURLWithPath: prefix).resolvingSymlinksInPath()
            guard visited.insert(root.path).inserted else { continue }
            let modules = root.appendingPathComponent("lib/node_modules")
            let packages = environment.children(modules).flatMap { directory in
                directory.lastPathComponent.hasPrefix("@") ? environment.children(directory) : [directory]
            }
            let active = root.path == URL(fileURLWithPath: primary).resolvingSymlinksInPath().path
            var outdated: [String: Any] = [:]
            var checkError: String?
            if !active, !packages.isEmpty, let npm {
                do {
                    let checked = try await environment.execute(
                        npm, ["outdated", "--global", "--prefix", root.path, "--json"], timeout: 45)
                    guard let data = checked.stdout.data(using: .utf8),
                        let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                        document["error"] == nil, checked.status == 0 || checked.status == 1
                    else { throw DiscoveryError.invalid("npm could not check this prefix") }
                    outdated = document
                } catch { checkError = error.localizedDescription }
            } else if npm == nil && !packages.isEmpty {
                checkError = "npm is missing; restore the owning runtime to manage this prefix"
            }
            if let checkError { failures.append("\(root.path): \(checkError)") }
            for package in packages {
                guard let document = environment.object(package.appendingPathComponent("package.json")),
                    let name = document["name"] as? String, let current = document["version"] as? String,
                    validNpmName(name)
                else { continue }
                let reference = await npmReference(package: package, root: root, name: name, npm: npm, active: active)
                var item = InstalledItem(
                    manager: .npm, name: name, version: current, reference: reference,
                    state: active ? .active : .inactive,
                    note: active ? "Current npm prefix" : "Another npm prefix; update only when selected")
                if active {
                    if let index = existing.packages.firstIndex(where: { $0.manager == .npm && $0.name == name }) {
                        // Keep custom commands for the active prefix. Scoped actions are needed only
                        // when the active manager cannot see the installation being changed.
                        item.latest = existing.packages[index].latest
                    } else if existing.reports.contains(where: { $0.manager == .npm && $0.status == .ok }) {
                        item.latest = current
                    }
                } else {
                    item.latest = (outdated[name] as? [String: Any])?["latest"] as? String
                    if item.latest == nil, checkError == nil { item.latest = current }
                    if let checkError { item.note = "Could not check this prefix: \(checkError)" }
                    if !hasLinkedExecutable(document, root: root) {
                        item.state = .orphaned
                        item.note = "No command link in this prefix; may be a leftover installation"
                    }
                }
                if environment.owner(of: package.path) == "Homebrew" {
                    item.state = .managed
                    item.latest = nil
                    item.reference.owner = "Homebrew"
                    item.reference.update = nil
                    item.reference.remove = nil
                    item.note = "Bundled with a Homebrew formula; update its owning formula"
                } else if (try? FileManager.default.destinationOfSymbolicLink(atPath: package.path)) != nil {
                    item.state = .manual
                    item.latest = nil
                    item.reference.update = nil
                    item.note = "Linked checkout; update it through its source project"
                }
                if active, let index = existing.packages.firstIndex(where: { $0.manager == .npm && $0.name == name }) {
                    if item.reference.update == nil {
                        existing.packages.remove(at: index)
                    } else {
                        existing.packages[index].installation = item.reference
                    }
                }
                items.append(item)
            }
        }
        return items
    }

    private func npmReference(
        package: URL, root: URL, name: String, npm: String?, active: Bool
    ) async -> InstallationReference {
        let action = npm.map {
            InstallationAction(
                executable: $0, arguments: ["install", "--global", "--prefix", root.path, "\(name)@latest"],
                environment: ["npm_config_prefix": root.path, "PATH": environment.variables["PATH"] ?? ""],
                manualOnly: !active)
        }
        let remove = npm.map {
            InstallationAction(
                executable: $0, arguments: ["uninstall", "--global", "--prefix", root.path, name],
                environment: ["npm_config_prefix": root.path, "PATH": environment.variables["PATH"] ?? ""],
                title: "Remove")
        }
        var reference = packageReference(
            path: package, root: root, owner: "npm", name: name, action: action,
            remove: remove, isDefault: active)
        reference.publicPackage = await publicNpmPackage(name, executable: npm, root: root)
        return reference
    }

    private func npmPrefixes(_ primary: String) -> [String] {
        var prefixes = [primary, environment.system("opt/homebrew").path, environment.system("usr/local").path]
        let nvm =
            environment.variables["NVM_DIR"].map { URL(fileURLWithPath: $0) }
            ?? environment.home.appendingPathComponent(".nvm")
        let data =
            environment.variables["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? environment.home.appendingPathComponent(".local/share")
        for root in [nvm.appendingPathComponent("versions/node"), data.appendingPathComponent("node")] {
            prefixes += environment.children(root).map(\.path)
        }
        if let custom = environment.variables["NPM_CONFIG_PREFIX"] ?? environment.variables["npm_config_prefix"] {
            prefixes.append(custom)
        }
        return prefixes + [
            environment.home.appendingPathComponent(".npm-global").path,
            environment.home.appendingPathComponent(".local").path,
        ]
    }

    func validNpmName(_ name: String) -> Bool {
        name.range(of: #"^(?:@[a-zA-Z0-9_.-]+/)?[a-zA-Z0-9_][a-zA-Z0-9_.-]*$"#, options: .regularExpression) != nil
    }

    private func publicNpmPackage(_ name: String, executable: String?, root: URL) async -> Bool {
        guard let executable else { return false }
        let scope = name.hasPrefix("@") ? String(name.split(separator: "/")[0]) + ":registry" : "registry"
        let key = root.path + ":" + scope
        if let cached = publicNpmSources[key] { return cached }
        let result = try? await environment.execute(executable, ["config", "get", scope, "--prefix", root.path])
        let value = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isPublic: Bool
        if result?.status == 0, value == "undefined", scope != "registry" {
            isPublic = await publicNpmPackage("unscoped", executable: executable, root: root)
        } else {
            let url = URL(string: value)
            isPublic = result?.status == 0 && url?.scheme == "https" && url?.host == "registry.npmjs.org"
        }
        publicNpmSources[key] = isPublic
        return isPublic
    }

    private func hasLinkedExecutable(_ package: [String: Any], root: URL) -> Bool {
        let names: [String]
        if let bins = package["bin"] as? [String: String] {
            names = Array(bins.keys)
        } else if package["bin"] is String, let name = package["name"] as? String {
            names = [String(name.split(separator: "/").last ?? "")]
        } else {
            return true
        }  // libraries are intentional even without command links
        return names.contains { name in
            let link = root.appendingPathComponent("bin").appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: link.path)
        }
    }
}
