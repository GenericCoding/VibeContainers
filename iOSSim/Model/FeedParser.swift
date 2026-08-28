import Foundation

/// Reads RSS 2.0 and Atom with one pass of `XMLParser`.
///
/// Both formats are handled together because a URL someone pastes in is as
/// likely to be one as the other, and the shapes only really differ in three
/// places: what an entry is called, where the link lives, and how the date is
/// written.
///
/// Text is only ever collected while inside a known element, so stray content
/// between tags — a feed with a literal `undefined` sitting in an `<item>`,
/// which the default source actually contains — cannot be mistaken for a field.
struct ParsedFeed {
    var title: String
    var items: [ParsedItem]
}

struct ParsedItem {
    var title: String
    var link: String
    var summary: String
    var date: Date?
    var identifier: String
}

final class FeedParser: NSObject, XMLParserDelegate {
    static func parse(_ data: Data) -> ParsedFeed? {
        let parser = FeedParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.shouldProcessNamespaces = true
        guard xml.parse() else { return nil }
        guard !parser.items.isEmpty || !parser.feedTitle.isEmpty else { return nil }
        return ParsedFeed(title: parser.feedTitle, items: parser.items)
    }

    private var feedTitle = ""
    private var items: [ParsedItem] = []

    private var element = ""
    private var text = ""
    private var insideItem = false
    private var current = ParsedItem(title: "", link: "", summary: "", date: nil, identifier: "")

    private static let itemElements: Set<String> = ["item", "entry"]
    private static let textElements: Set<String> = [
        "title", "link", "description", "summary", "content", "encoded",
        "pubdate", "published", "updated", "date", "guid", "id"
    ]

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let name = elementName.lowercased()
        element = name
        text = ""

        if Self.itemElements.contains(name) {
            insideItem = true
            current = ParsedItem(title: "", link: "", summary: "", date: nil, identifier: "")
            return
        }

        // Atom puts the link in an attribute, and may offer several: the one
        // worth having is the alternate (or the first unlabelled one).
        if name == "link", let href = attributes["href"] {
            let rel = attributes["rel"] ?? "alternate"
            guard rel == "alternate" else { return }
            if insideItem {
                if current.link.isEmpty { current.link = href }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard Self.textElements.contains(element) else { return }
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard Self.textElements.contains(element),
              let string = String(data: CDATABlock, encoding: .utf8) else { return }
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        element = ""

        if Self.itemElements.contains(name) {
            insideItem = false
            if current.identifier.isEmpty { current.identifier = current.link }
            if current.identifier.isEmpty { current.identifier = current.title }
            if !current.title.isEmpty || !current.link.isEmpty { items.append(current) }
            return
        }

        guard !value.isEmpty else { return }

        if insideItem {
            switch name {
            case "title": if current.title.isEmpty { current.title = value }
            case "link": if current.link.isEmpty { current.link = value }
            case "description", "summary", "content", "encoded":
                if current.summary.isEmpty { current.summary = Self.plainText(value) }
            case "pubdate", "published", "updated", "date":
                if current.date == nil { current.date = Self.date(from: value) }
            case "guid", "id": if current.identifier.isEmpty { current.identifier = value }
            default: break
            }
        } else if name == "title", feedTitle.isEmpty {
            feedTitle = value
        }
    }

    // MARK: - Values

    /// Feeds put anything from a sentence to a full HTML article in the
    /// summary; the list only ever shows a couple of lines of it.
    static func plainText(_ html: String) -> String {
        var output = ""
        var insideTag = false
        for character in html {
            switch character {
            case "<": insideTag = true
            case ">": insideTag = false
            default: if !insideTag { output.append(character) }
            }
        }
        return output
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static let rfc822: [String] = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm zzz",
        "yyyy-MM-dd"
    ]

    static func date(from value: String) -> Date? {
        // Atom is ISO 8601; RSS is RFC 822, in whichever of its shapes the
        // generator felt like.
        if let date = isoParser.date(from: value) { return date }
        if let date = isoParserNoFraction.date(from: value) { return date }

        for format in rfc822 {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let isoParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser
    }()

    private static let isoParserNoFraction = ISO8601DateFormatter()
}
