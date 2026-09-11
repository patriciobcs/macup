import Foundation

/// Resolves latest versions, publish dates and security advisories from public registries.
/// Everything is cached on disk keyed by package@version, so each fact is fetched once.
actor Registry {
    struct Entry: Codable {
        var latest: String?
        var date: Date?
        var source: DateSource?
        var advisories: [String]?
        var expires: Date?
    }

    private var cache: [String: Entry] = [:]
    private let cacheURL: URL
    private let session: URLSession
    private var loaded = false
    /// Set by `get` when the most recent request did not complete or hit a rate limit.
    private var requestFailed = false

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Macup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("registry-cache.json")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.httpAdditionalHeaders = [
            "User-Agent": "MacUp/1.0 (+https://github.com/patriciobcs/macup)", "Accept": "application/json",
        ]
        session = URLSession(configuration: cfg)
    }

    // MARK: Public

    /// Fills in `latest` (when "?"), `releaseDate`/`dateSource`, and `advisories`.
    /// Packages that turn out to be up to date are dropped.
    func enrich(_ packages: [OutdatedPackage]) async -> [OutdatedPackage] {
        loadIfNeeded()
        var result: [OutdatedPackage] = []
        await withTaskGroup(of: OutdatedPackage?.self) { group in
            var pending = packages[...]
            var running = 0
            func pump(_ group: inout TaskGroup<OutdatedPackage?>) {
                while running < 6, let next = pending.popFirst() {
                    running += 1
                    group.addTask { await self.resolve(next) }
                }
            }
            pump(&group)
            for await item in group {
                running -= 1
                if let item { result.append(item) }
                pump(&group)
            }
        }
        await attachAdvisories(&result)
        save()
        return result
    }

    // MARK: Per-package resolution

    private func resolve(_ input: OutdatedPackage) async -> OutdatedPackage? {
        var pkg = input
        if pkg.needsLatest {
            guard let latest = await latestVersion(for: pkg) else { return nil }
            pkg.latest = latest
        }
        // Whatever the source, only a strictly newer version is an update.
        if pkg.installed != "?", !Version.isNewer(pkg.latest, than: pkg.installed) { return nil }
        requestFailed = false
        if pkg.releaseDate == nil {
            if let cached = cache["date:\(pkg.versionKey)"], let src = cached.source,
                (cached.expires ?? .distantFuture) > Date()
            {
                pkg.releaseDate = cached.date
                pkg.dateSource = src
            } else if let (date, source) = await releaseDate(for: pkg) {
                pkg.releaseDate = date
                pkg.dateSource = source
                cache["date:\(pkg.versionKey)"] = Entry(date: date, source: source)
            } else if !requestFailed {
                // Remember the miss for a day so we do not hammer APIs for packages without dates.
                // A failed or rate-limited request is not a miss: try again next scan.
                cache["date:\(pkg.versionKey)"] = Entry(
                    date: nil, source: .firstSeen, expires: Date().addingTimeInterval(86_400))
            }
        }
        return pkg
    }

    private func latestVersion(for pkg: OutdatedPackage) async -> String? {
        let key = "latest:\(pkg.id)"
        if let e = cache[key], let latest = e.latest, (e.expires ?? .distantPast) > Date() { return latest }
        requestFailed = false
        var latest: String?
        switch pkg.manager {
        case .cargo:
            if let json = await getJSON("https://crates.io/api/v1/crates/\(Self.seg(pkg.name))") {
                latest = (json["crate"] as? [String: Any])?["max_stable_version"] as? String
            }
        case .uv, .pip, .pipx:
            if let json = await getJSON("https://pypi.org/pypi/\(Self.seg(pkg.name))/json") {
                latest = (json["info"] as? [String: Any])?["version"] as? String
            }
        case .go:
            if let module = pkg.goModule,
                let json = await getJSON("https://proxy.golang.org/\(Self.goEscape(module))/@latest")
            {
                latest = json["Version"] as? String
            }
        case .npm, .bun, .pnpm:
            if let json = await npmDocument(pkg.name) {
                latest = (json["dist-tags"] as? [String: Any])?["latest"] as? String
            }
        default: break
        }
        if let latest {
            cache[key] = Entry(latest: latest, expires: Date().addingTimeInterval(3600))
            return latest
        }
        // Offline or the registry is down: an expired answer beats making the package disappear.
        return requestFailed ? cache[key]?.latest : nil
    }

    private func releaseDate(for pkg: OutdatedPackage) async -> (Date, DateSource)? {
        switch pkg.manager {
        case .npm, .bun, .pnpm:
            guard let json = await npmDocument(pkg.name),
                let time = json["time"] as? [String: Any],
                let s = time[pkg.latest] as? String, let d = Self.parseISO(s)
            else { return nil }
            return (d, .registry)
        case .pip, .uv, .pipx:
            guard let json = await getJSON("https://pypi.org/pypi/\(Self.seg(pkg.name))/\(Self.seg(pkg.latest))/json"),
                let urls = json["urls"] as? [[String: Any]],
                let s = urls.compactMap({ $0["upload_time_iso_8601"] as? String }).min(),
                let d = Self.parseISO(s)
            else { return nil }
            return (d, .registry)
        case .cargo:
            guard
                let json = await getJSON(
                    "https://crates.io/api/v1/crates/\(Self.seg(pkg.name))/\(Self.seg(pkg.latest))"),
                let v = json["version"] as? [String: Any],
                let s = v["created_at"] as? String, let d = Self.parseISO(s)
            else { return nil }
            return (d, .registry)
        case .gem:
            guard let arr = await getJSONArray("https://rubygems.org/api/v1/versions/\(Self.seg(pkg.name)).json"),
                let v = arr.first(where: { ($0["number"] as? String) == pkg.latest }),
                let s = v["created_at"] as? String, let d = Self.parseISO(s)
            else { return nil }
            return (d, .registry)
        case .brew:
            return await homebrewBumpDate(pkg)
        case .go:
            guard let module = pkg.goModule,
                let json = await getJSON(
                    "https://proxy.golang.org/\(Self.goEscape(module))/@v/\(Self.seg(pkg.latest)).info"),
                let s = json["Time"] as? String, let d = Self.parseISO(s)
            else { return nil }
            return (d, .registry)
        case .composer:
            guard let json = await getJSON("https://repo.packagist.org/p2/\(Self.segPath(pkg.name)).json"),
                let versions = (json["packages"] as? [String: Any])?[pkg.name] as? [[String: Any]],
                let v = versions.first(where: {
                    ($0["version"] as? String) == pkg.latest || ($0["version"] as? String) == "v\(pkg.latest)"
                }),
                let s = v["time"] as? String, let d = Self.parseISO(s)
            else { return nil }
            return (d, .registry)
        case .tools:
            // extra is "owner/repo:tag"; the release's publish date is the release date.
            let parts = pkg.extra.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty,
                let json = await getJSON(
                    "https://api.github.com/repos/\(Self.segPath(parts[0]))/releases/tags/\(Self.seg(parts[1]))"),
                let s = json["published_at"] as? String, let d = Self.parseISO(s)
            else { return nil }
            return (d, .registry)
        case .rustup, .mas, .macos, .port, .conda, .nix, .mise:
            return nil
        }
    }

    /// Date of the last commit touching the formula/cask file in Homebrew's GitHub repos.
    private func homebrewBumpDate(_ pkg: OutdatedPackage) async -> (Date, DateSource)? {
        let token = pkg.name.split(separator: "/").last.map(String.init) ?? pkg.name
        guard pkg.name == token || pkg.name.hasPrefix("homebrew/") else { return nil }  // third-party tap
        guard let first = token.first else { return nil }
        let repo: String, path: String
        if pkg.baseKind == "cask" {
            repo = "homebrew-cask"
            path = "Casks/\(first)/\(token).rb"
        } else {
            repo = "homebrew-core"
            let shard = token.hasPrefix("lib") ? "lib" : String(first)
            path = "Formula/\(shard)/\(token).rb"
        }
        var comps = URLComponents(string: "https://api.github.com/repos/Homebrew/\(repo)/commits")!
        comps.queryItems = [.init(name: "path", value: path), .init(name: "per_page", value: "1")]
        guard let url = comps.url, let arr = await getJSONArray(url.absoluteString),
            let commit = arr.first?["commit"] as? [String: Any],
            let committer = commit["committer"] as? [String: Any],
            let s = committer["date"] as? String, let d = Self.parseISO(s)
        else { return nil }
        return (d, .homebrew)
    }

    // MARK: Advisories (OSV.dev)

    private func attachAdvisories(_ packages: inout [OutdatedPackage]) async {
        var toQuery: [(index: Int, ecosystem: String)] = []
        for (i, p) in packages.enumerated() {
            guard let eco = p.manager.osvEcosystem else { continue }
            let key = "osv:\(p.id)@\(p.installed)"
            if let e = cache[key], let adv = e.advisories, (e.expires ?? .distantPast) > Date() {
                packages[i].advisories = adv
            } else {
                toQuery.append((i, eco))
            }
        }
        guard !toQuery.isEmpty else { return }
        let queries: [[String: Any]] = toQuery.map { q in
            [
                "package": ["name": packages[q.index].name, "ecosystem": q.ecosystem],
                "version": packages[q.index].installed,
            ]
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["queries": queries]),
            let json = await postJSON("https://api.osv.dev/v1/querybatch", body: body),
            let results = json["results"] as? [[String: Any]], results.count == toQuery.count
        else { return }
        for (q, r) in zip(toQuery, results) {
            let ids = ((r["vulns"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            packages[q.index].advisories = ids
            cache["osv:\(packages[q.index].id)@\(packages[q.index].installed)"] =
                Entry(advisories: ids, expires: Date().addingTimeInterval(6 * 3600))
        }
    }

    // MARK: HTTP + cache plumbing

    private func npmDocument(_ name: String) async -> [String: Any]? {
        // Scoped packages keep their slash encoded, as the registry expects.
        return await getJSON("https://registry.npmjs.org/\(Self.seg(name))")
    }

    private func getJSON(_ url: String) async -> [String: Any]? {
        guard let data = await get(url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func getJSONArray(_ url: String) async -> [[String: Any]]? {
        guard let data = await get(url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    }

    private func get(_ url: String) async -> Data? {
        guard let u = URL(string: url) else { return nil }
        guard let (data, resp) = try? await session.data(from: u), let http = resp as? HTTPURLResponse else {
            requestFailed = true
            return nil
        }
        if http.statusCode == 403 || http.statusCode == 429 { requestFailed = true }
        guard (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    private func postJSON(_ url: String, body: Data) async -> [String: Any]? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, resp) = try? await session.data(for: req),
            let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: cacheURL),
            let decoded = try? JSONDecoder.iso.decode([String: Entry].self, from: data)
        {
            let now = Date()
            cache = decoded.filter { ($0.value.expires ?? .distantFuture) > now }
        }
    }

    private func save() {
        if let data = try? JSONEncoder.iso.encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
    }

    /// One URL path segment, percent-encoded (a "/" inside a name becomes %2F).
    nonisolated static func seg(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// A path made of several segments separated by "/", each encoded on its own.
    nonisolated static func segPath(_ s: String) -> String {
        s.split(separator: "/", omittingEmptySubsequences: false).map { seg(String($0)) }.joined(separator: "/")
    }

    /// Go module proxy escaping: uppercase letters become "!" + lowercase.
    nonisolated static func goEscape(_ module: String) -> String {
        module.map { $0.isUppercase ? "!\($0.lowercased())" : String($0) }.joined()
    }

    nonisolated static func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
