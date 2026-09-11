import Foundation

/// Serves canned registry responses so the tests exercise the real parsing and caching without
/// touching the network. Routes are matched by substring, in the order they were registered.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var body: String
        init(_ body: String, status: Int = 200) {
            self.body = body
            self.status = status
        }
    }

    private static let lock = NSLock()
    private static var routes: [(match: String, reply: Reply)] = []
    private static var requested: [String] = []

    /// Installs the routes for one test and forgets everything from the previous one.
    static func serve(_ routes: [(String, Reply)]) {
        lock.lock()
        defer { lock.unlock() }
        Self.routes = routes.map { (match: $0.0, reply: $0.1) }
        requested = []
    }

    /// URLs asked for so far, so a test can prove an answer came from the cache.
    static var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    static func requestCount(matching fragment: String) -> Int {
        requests.filter { $0.contains(fragment) }.count
    }

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private static func reply(for url: String) -> Reply? {
        lock.lock()
        defer { lock.unlock() }
        requested.append(url)
        return routes.first { url.contains($0.match) }?.reply
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        // An unrouted URL stands for being offline, which is a case the registry handles on purpose.
        guard let reply = Self.reply(for: url.absoluteString) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil)
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
