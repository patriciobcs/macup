import Foundation

struct AppProvider: Codable {
    var bundleID: String
    var github: String?
    var tagPrefix: String?
    var feed: String?
    var architectureFeeds: [String: String]?
    var vendor: String?
}

extension InstallationDiscovery {
    func desktopApps() async -> [InstalledItem] {
        let providers = appProviders()
        var items: [InstalledItem] = []
        var details: [String: [String: Any]] = [:]
        let roots = [environment.system("Applications"), environment.home.appendingPathComponent("Applications")]
        var visited: Set<String> = []
        for root in roots {
            for app in applicationBundles(root) {
                let canonical = app.resolvingSymlinksInPath()
                guard visited.insert(canonical.path).inserted,
                    let info = environment.plist(app.appendingPathComponent("Contents/Info.plist")),
                    let identifier = info["CFBundleIdentifier"] as? String
                else { continue }
                let provider = providers.first { $0.bundleID == identifier }
                let item = desktopItem(app, info: info, identifier: identifier, provider: provider)
                details[item.id] = info
                items.append(item)
            }
        }
        return await withTaskGroup(of: (Int, InstalledItem).self) { group in
            var pending = Array(items.enumerated())[...]
            var checked = items
            func pump() {
                guard let (index, item) = pending.popFirst() else { return }
                let info = details[item.id] ?? [:]
                let identifier = info["CFBundleIdentifier"] as? String
                let provider = providers.first { $0.bundleID == identifier }
                group.addTask {
                    let result =
                        item.state == .managed || item.version == "Unknown"
                        ? item
                        : await self.desktopRelease(item, info: info, provider: provider)
                    return (index, result)
                }
            }
            for _ in 0..<min(6, items.count) { pump() }
            for await (index, item) in group {
                checked[index] = item
                pump()
            }
            return checked
        }
    }

    private func applicationBundles(_ root: URL, depth: Int = 0) -> [URL] {
        guard depth < 3 else { return [] }
        var result: [URL] = []
        for child in environment.children(root) where !child.lastPathComponent.hasPrefix(".") {
            if child.pathExtension.lowercased() == "app" {
                result.append(child)
            } else {
                result += applicationBundles(child, depth: depth + 1)
            }
        }
        return result
    }

    private func desktopItem(
        _ app: URL, info: [String: Any], identifier: String, provider: AppProvider?
    ) -> InstalledItem {
        let name = app.deletingPathExtension().lastPathComponent
        let version = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "Unknown"
        let owner = applicationOwner(app, identifier: identifier)
        let action: InstallationAction?
        if let vendor = provider?.vendor {
            action = InstallationAction(kind: .openURL, executable: vendor, title: "Open Vendor")
        } else {
            action = InstallationAction(kind: .openApp, executable: app.path, title: "Open App")
        }
        let reference = packageReference(
            path: app, root: app.deletingLastPathComponent(), owner: owner ?? name,
            name: identifier, action: owner == nil ? action : nil)
        return InstalledItem(
            manager: .apps, name: name, version: version, reference: reference,
            state: owner == nil ? .manual : .managed,
            note: owner.map { "Updated by \($0)" } ?? "Uses the vendor's updater")
    }

    private func applicationOwner(_ app: URL, identifier: String) -> String? {
        if FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/_MASReceipt/receipt").path) {
            return "App Store"
        }
        if identifier == "io.github.patriciobcs.macup" { return "MacUp updater" }
        if ["com.apple.Safari", "com.apple.SafariTechnologyPreview"].contains(identifier) { return "Software Update" }
        if identifier == "dev.kdrag0n.MacVirt" { return "OrbStack" }
        if identifier.hasPrefix("io.tailscale.") { return "Tailscale" }
        return homebrewAppOwner(app)
    }

    func homebrewAppOwner(_ app: URL) -> String? {
        let normalise: (String) -> String = { $0.lowercased().filter(\.isLetter) }
        let name = normalise(app.deletingPathExtension().lastPathComponent)
        var roots = [environment.system("opt/homebrew/Caskroom"), environment.system("usr/local/Caskroom")]
        if let prefix = environment.variables["HOMEBREW_PREFIX"] {
            roots.append(environment.fileURL(prefix).appendingPathComponent("Caskroom"))
        }
        for cask in roots.flatMap({ environment.children($0) }) {
            guard let receipt = environment.object(cask.appendingPathComponent(".metadata/INSTALL_RECEIPT.json")) else {
                continue
            }
            let config = receipt["config"] as? [String: Any]
            let appDirectory = config?["appdir"] as? String ?? environment.system("Applications").path
            guard
                app.deletingLastPathComponent().resolvingSymlinksInPath().path
                    == environment.fileURL(appDirectory).resolvingSymlinksInPath().path
            else { continue }
            if normalise(cask.lastPathComponent) == name { return "Homebrew" }
        }
        return nil
    }

    private func appProviders() -> [AppProvider] {
        let override = environment.variables["MACUP_APP_CATALOG"].map { URL(fileURLWithPath: $0) }
        let bundled = Bundle.main.url(forResource: "app-catalog", withExtension: "json", subdirectory: "Scripts")
        guard let path = override ?? bundled, let data = try? Data(contentsOf: path) else { return [] }
        return (try? JSONDecoder().decode([AppProvider].self, from: data)) ?? []
    }

    private func desktopRelease(
        _ original: InstalledItem, info: [String: Any], provider: AppProvider?
    ) async -> InstalledItem {
        var item = original
        do {
            let architectures = appArchitectures(item.reference.path, info: info)
            let arch = architectures.contains(hostArchitecture) ? hostArchitecture : architectures.min()
            let feed =
                (info["SUFeedURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? arch.flatMap { provider?.architectureFeeds?[$0] } ?? provider?.feed
            if let feed {
                let releases = try AppcastParser.parse(await data(feed))
                let os = ProcessInfo.processInfo.operatingSystemVersion
                let currentOS =
                    environment.variables["MACUP_OS_VERSION"]
                    ?? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
                let channels = Set(info["SUAllowedChannels"] as? [String] ?? [])
                if let release = AppcastParser.latest(
                    releases, os: currentOS, architectures: appArchitectures(item.reference.path, info: info),
                    channels: channels)
                {
                    let build = info["CFBundleVersion"] as? String ?? item.version
                    item.latest = release.version.isEmpty ? release.build : release.version
                    item.updateAvailable = Version.isNewer(
                        release.build.isEmpty ? item.latest! : release.build, than: build)
                    item.reference.release = release.build.isEmpty ? item.latest : release.build
                    if item.updateAvailable == true, item.latest == item.version, let latest = item.latest,
                        !release.build.isEmpty
                    {
                        item.latest = "\(latest) (build \(release.build))"
                    }
                    item.note = "Vendor appcast; installation stays with the app's own updater"
                }
            } else if let repo = provider?.github {
                item.latest = try await githubVersion(repo, prefix: provider?.tagPrefix)
            } else if let release = try await electronVersion(item.reference.path) {
                item.latest = release
            }
        } catch {
            item.note = "Could not check the vendor feed: \(error.localizedDescription)"
            failures.append("\(item.name): \(error.localizedDescription)")
        }
        return item
    }

    private func githubVersion(_ repository: String, prefix: String?) async throws -> String? {
        guard repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else {
            throw DiscoveryError.invalid("Invalid GitHub release repository")
        }
        let releases =
            try await json("https://api.github.com/repos/\(repository)/releases?per_page=30") as? [[String: Any]] ?? []
        return releases.filter { ($0["prerelease"] as? Bool) != true && ($0["draft"] as? Bool) != true }
            .compactMap { release -> String? in
                guard let tag = release["tag_name"] as? String, prefix.map({ tag.hasPrefix($0) }) ?? true else {
                    return nil
                }
                if prefix == nil
                    && tag.range(of: #"^v?\d+(?:\.\d+)+(?:\+[A-Za-z0-9.-]+)?$"#, options: .regularExpression) == nil
                {
                    return nil
                }
                return version(tag)
            }.max { Version.compare($0, $1) == .orderedAscending }
    }

    private func electronVersion(_ path: String) async throws -> String? {
        let file = URL(fileURLWithPath: path).appendingPathComponent("Contents/Resources/app-update.yml")
        guard let yaml = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let fields = yamlFields(yaml)
        if fields["provider"] == "github", let owner = fields["owner"], let repo = fields["repo"] {
            return try await githubVersion("\(owner)/\(repo)", prefix: fields["tagPrefix"])
        }
        if fields["provider"] == "generic", let base = fields["url"], let url = URL(string: base) {
            let channel = fields["channel"] ?? "latest"
            guard channel.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
            let manifest = try await text(url.appendingPathComponent("\(channel)-mac.yml").absoluteString)
            return yamlFields(manifest)["version"]
        }
        return nil
    }

    func yamlFields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix(" ") && !line.hasPrefix("#") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon])] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(
                    in: CharacterSet(charactersIn: "\"'"))
        }
        return fields
    }

    private func appArchitectures(_ path: String, info: [String: Any]) -> Set<String> {
        if let binary = info["CFBundleExecutable"] as? String, !binary.contains("/") {
            let architectures = BinaryArchitecture.read(
                URL(fileURLWithPath: path).appendingPathComponent("Contents/MacOS/\(binary)"))
            if !architectures.isEmpty { return architectures }
        }
        if let configured = info["LSArchitecturePriority"] as? [String], !configured.isEmpty { return Set(configured) }
        // Architecture-specific feeds supplied by the app remain authoritative; universal feeds use
        // the running Mac's architecture unless the bundle explicitly declares another preference.
        return [environment.variables["MACUP_ARCH"] ?? hostArchitecture]
    }

    var hostArchitecture: String {
        #if arch(arm64)
            "arm64"
        #else
            "x86_64"
        #endif
    }
}
