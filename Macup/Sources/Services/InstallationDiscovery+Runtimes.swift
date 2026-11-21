import Foundation

extension InstallationDiscovery {
    func runtimes() async -> [InstalledItem] {
        var items = await nodeRuntimes()
        items += await pythonRuntimes()
        items += javaRuntimes()
        return items
    }

    private func nodeRuntimes() async -> [InstalledItem] {
        var paths: [URL] = []
        if let current = environment.executable("node") {
            paths.append(URL(fileURLWithPath: current).resolvingSymlinksInPath())
        }
        for root in [
            environment.home.appendingPathComponent(".local/share/node"),
            environment.home.appendingPathComponent(".nvm/versions/node"),
        ] {
            paths += environment.children(root).map { $0.appendingPathComponent("bin/node") }
        }
        var visited: Set<String> = []
        var items: [InstalledItem] = []
        for path in paths where FileManager.default.isExecutableFile(atPath: path.path) {
            let canonical = path.resolvingSymlinksInPath()
            guard visited.insert(canonical.path).inserted,
                let output = try? await environment.execute(canonical.path, ["--version"]),
                let current = version(output.stdout)
            else { continue }
            let owner = environment.owner(of: canonical.path)
            let root = canonical.deletingLastPathComponent().deletingLastPathComponent()
            var item = InstalledItem(
                manager: .runtimes, name: "Node.js \(current.split(separator: ".")[0])", version: current,
                reference: packageReference(
                    path: canonical, root: root, owner: owner ?? "Node.js distribution", name: "node", action: nil),
                state: owner == nil ? .active : .managed)
            if owner == nil {
                do {
                    item.latest = try await latestNode(current)
                    let architectures = BinaryArchitecture.read(canonical)
                    let architecture =
                        architectures.contains(hostArchitecture) ? hostArchitecture : architectures.min()
                    if let latest = item.latest, let architecture {
                        item.reference.update = InstallationAction(
                            kind: .nodePatch, executable: canonical.path, arguments: [latest, architecture],
                            title: "Update Runtime")
                        item.note =
                            "Keeps this Node major and npm prefix; verifies the vendor checksum and signing identity"
                    }
                } catch {
                    item.note = error.localizedDescription
                    failures.append("Node.js: \(item.note)")
                }
            }
            items.append(item)
        }
        return items
    }

    func latestNode(_ current: String) async throws -> String? {
        let major = current.split(separator: ".").first.map(String.init) ?? ""
        let versions = try await json("https://nodejs.org/dist/index.json") as? [[String: Any]] ?? []
        return versions.compactMap { row -> String? in
            guard let value = row["version"] as? String else { return nil }
            let clean = value.hasPrefix("v") ? String(value.dropFirst()) : value
            guard clean.split(separator: ".").first.map(String.init) == major, !clean.contains("-") else { return nil }
            return clean
        }.max { Version.compare($0, $1) == .orderedAscending }
    }

    private func pythonRuntimes() async -> [InstalledItem] {
        guard let uv = environment.executable("uv") else { return [] }
        do {
            let installed = try await environment.execute(
                uv, ["python", "list", "--only-installed", "--output-format", "json"])
            let available = try? await environment.execute(
                uv, ["python", "list", "--all-versions", "--only-downloads", "--output-format", "json"])
            guard installed.status == 0,
                let installedData = installed.stdout.data(using: .utf8),
                let rows = try JSONSerialization.jsonObject(with: installedData) as? [[String: Any]]
            else { throw DiscoveryError.invalid("uv could not list managed Python versions") }
            let candidates =
                available?.status == 0
                ? (available?.stdout.data(using: .utf8).flatMap {
                    (try? JSONSerialization.jsonObject(with: $0)) as? [[String: Any]]
                } ?? []) : []
            if candidates.isEmpty { failures.append("uv could not check available Python downloads") }
            let absolute = rows.map { row in
                var row = row
                if let path = row["path"] as? String { row["path"] = environment.fileURL(path).path }
                return row
            }
            return pythonItems(absolute, available: candidates, executable: uv)
        } catch {
            failures.append("Managed Python: \(error.localizedDescription)")
            return []
        }
    }

    private func pythonItems(_ rows: [[String: Any]], available: [[String: Any]], executable: String) -> [InstalledItem]
    {
        let root =
            environment.variables["UV_PYTHON_INSTALL_DIR"].map { URL(fileURLWithPath: $0) }
            ?? (environment.variables["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? environment.home.appendingPathComponent(".local/share")).appendingPathComponent("uv/python")
        var grouped: [String: [[String: Any]]] = [:]
        for row in rows {
            guard let current = row["version"] as? String, let path = row["path"] as? String,
                URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(
                    root.resolvingSymlinksInPath().path + "/")
            else { continue }
            let minor = current.split(separator: ".").prefix(2).joined(separator: ".")
            let flavor = ["implementation", "arch", "variant"].map { row[$0] as? String ?? "" }.joined(separator: ":")
            grouped[minor + ":" + flavor, default: []].append(row)
        }
        return grouped.keys.sorted().compactMap { group in
            let minor = String(group.split(separator: ":")[0])
            guard let rows = grouped[group],
                let newest = rows.max(by: {
                    Version.compare($0["version"] as? String ?? "", $1["version"] as? String ?? "") == .orderedAscending
                }), let current = newest["version"] as? String, let path = newest["path"] as? String
            else { return nil }
            let latest = available.compactMap { row -> String? in
                guard let candidate = row["version"] as? String, candidate.hasPrefix(minor + "."),
                    !candidate.contains("-")
                else { return nil }
                guard
                    ["implementation", "arch", "variant", "os", "libc"].allSatisfy({
                        (row[$0] as? String ?? "") == (newest[$0] as? String ?? "")
                    })
                else { return nil }
                return candidate
            }.max { Version.compare($0, $1) == .orderedAscending }
            let implementation = newest["implementation"] as? String ?? "cpython"
            let variant = newest["variant"] as? String ?? "default"
            let action =
                implementation == "cpython" && variant == "default"
                    && (newest["arch"] as? String).map { $0 == (hostArchitecture == "arm64" ? "aarch64" : "x86_64") }
                        != false
                ? InstallationAction(
                    executable: executable, arguments: ["python", "upgrade", minor], title: "Update Runtime") : nil
            var reference = packageReference(
                path: URL(fileURLWithPath: path), root: root, owner: "uv", name: "python", action: action)
            reference.identityPath = root.appendingPathComponent(group).path
            return InstalledItem(
                manager: .runtimes, name: "Python \(minor)", version: current,
                reference: reference,
                latest: latest, note: "Managed Python patch updates; project version pins are unchanged")
        }
    }

    private func javaRuntimes() -> [InstalledItem] {
        var items: [InstalledItem] = []
        for root in [
            environment.system("Library/Java/JavaVirtualMachines"),
            environment.home.appendingPathComponent("Library/Java/JavaVirtualMachines"),
        ] {
            for directory in environment.children(root) where directory.pathExtension == "jdk" {
                let file = directory.appendingPathComponent("Contents/Home/release")
                guard let release = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let fields = release.split(separator: "\n").reduce(into: [String: String]()) { result, line in
                    let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
                    if pair.count == 2 {
                        result[pair[0]] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    }
                }
                guard let current = fields["JAVA_VERSION"] else { continue }
                let major = current.hasPrefix("1.8.") ? "8" : String(current.split(separator: ".").first ?? "")
                let vendor = fields["IMPLEMENTOR"] ?? "Java vendor"
                let url =
                    vendor.lowercased().contains("oracle") || current.hasPrefix("1.8.")
                    ? "https://www.oracle.com/java/technologies/downloads/#java\(major)"
                    : "https://adoptium.net/temurin/releases/?version=\(major)"
                let owner = environment.owner(of: directory.path)
                let action =
                    owner == nil ? InstallationAction(kind: .openURL, executable: url, title: "Open Vendor") : nil
                items.append(
                    InstalledItem(
                        manager: .runtimes, name: "Java \(major)", version: current,
                        reference: packageReference(
                            path: directory, root: root, owner: vendor, name: "java", action: action),
                        state: owner == nil ? .manual : .managed,
                        note: owner.map { "Updated by \($0)" }
                            ?? "\(vendor) · \(fields["OS_ARCH"] ?? "unknown architecture"); vendor installation required"
                    ))
            }
        }
        return items
    }
}
