import Foundation

/// Appcast selection is discovery only. Installation stays with the app's own signature-verifying
/// updater; a feed never supplies an executable command to MacUp.
struct AppcastRelease {
    var build = ""
    var version = ""
    var minimumOS = ""
    var maximumOS = ""
    var channel = ""
    var architectures: Set<String> = []
    var published: Date?
}

final class AppcastParser: NSObject, XMLParserDelegate {
    private var current: AppcastRelease?
    private var element = ""
    private var text = ""
    private(set) var releases: [AppcastRelease] = []

    static func parse(_ data: Data) throws -> [AppcastRelease] {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw DiscoveryError.invalid("The app's update feed is not valid XML") }
        return delegate.releases
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        element = elementName
        text = ""
        if elementName == "item" { current = AppcastRelease() }
        if elementName == "enclosure" {
            if let build = attributeDict["sparkle:version"] { current?.build = build }
            if let version = attributeDict["sparkle:shortVersionString"] { current?.version = version }
            if let arch = attributeDict["sparkle:arch"] { current?.architectures.insert(arch) }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "sparkle:version": current?.build = value
        case "sparkle:shortVersionString": current?.version = value
        case "sparkle:minimumSystemVersion": current?.minimumOS = value
        case "sparkle:maximumSystemVersion": current?.maximumOS = value
        case "sparkle:channel": current?.channel = value
        case "pubDate":
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            current?.published = formatter.date(from: value)
        case "item":
            if let current, !current.build.isEmpty || !current.version.isEmpty { releases.append(current) }
            current = nil
        default: break
        }
        text = ""
    }

    static func latest(
        _ releases: [AppcastRelease], os: String, architectures: Set<String>, channels: Set<String>
    ) -> AppcastRelease? {
        releases.filter { item in
            (item.minimumOS.isEmpty || Version.compare(os, item.minimumOS) != .orderedAscending)
                && (item.maximumOS.isEmpty || Version.compare(os, item.maximumOS) != .orderedDescending)
                && (item.channel.isEmpty || channels.contains(item.channel))
                && (item.architectures.isEmpty || !item.architectures.isDisjoint(with: architectures))
        }.max {
            Version.compare($0.build.isEmpty ? $0.version : $0.build, $1.build.isEmpty ? $1.version : $1.build)
                == .orderedAscending
        }
    }
}
