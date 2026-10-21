import Foundation

/// One Unwine version in the change list, in plain words for players.
struct ChangelogEntry: Identifiable, Equatable {
    struct Item: Equatable {
        var text: String
        var sub: [String] = []
    }

    let version: String
    let date: Date?             // nil while the version is not released yet
    var note: [String] = []     // text under the heading, before the bullets
    var items: [Item] = []

    var id: String { version }
}

/// The change list the build copies into the app from CHANGELOG.md, newest version first.
/// scripts/build.sh takes the app's version from the same file, so the running version always has
/// an entry here.
enum Changelog {
    static let entries: [ChangelogEntry] = {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }()

    /// Reads "## 1.0.2 · 2026-10-21" headings, "- " bullets, "  - " sub-bullets and plain lines (a
    /// note for the version). The title above the first heading and HTML comments, which are notes
    /// for whoever writes the list, are left out.
    static func parse(_ text: String) -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        var inComment = false
        var lastWasBlank = true
        for raw in text.components(separatedBy: .newlines) {
            var line = raw
            if inComment {
                guard let end = line.range(of: "-->") else { continue }
                line = String(line[end.upperBound...])
                inComment = false
            }
            while let start = line.range(of: "<!--") {
                if let end = line.range(of: "-->", range: start.upperBound..<line.endIndex) {
                    line.removeSubrange(start.lowerBound..<end.upperBound)
                } else {
                    line = String(line[..<start.lowerBound])
                    inComment = true
                }
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { lastWasBlank = trimmed.isEmpty }

            if line.hasPrefix("## ") {
                let parts = line.dropFirst(3).split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let version = parts.first, !version.isEmpty else { continue }
                entries.append(ChangelogEntry(version: version, date: parts.dropFirst().first.flatMap(day)))
                continue
            }
            guard !entries.isEmpty, !trimmed.isEmpty else { continue }
            let i = entries.count - 1
            if line.hasPrefix("- ") {
                entries[i].items.append(.init(text: String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("- "), !entries[i].items.isEmpty {
                entries[i].items[entries[i].items.count - 1].sub.append(String(trimmed.dropFirst(2)))
            } else if line.first == " ", let j = entries[i].items.indices.last {
                // An indented line goes on with the bullet above it.
                if entries[i].items[j].sub.isEmpty {
                    entries[i].items[j].text += " " + trimmed
                } else {
                    entries[i].items[j].sub[entries[i].items[j].sub.count - 1] += " " + trimmed
                }
            } else if entries[i].items.isEmpty {
                if lastWasBlank || entries[i].note.isEmpty { entries[i].note.append(trimmed) } else { entries[i].note[entries[i].note.count - 1] += " " + trimmed }
            }
        }
        return entries
    }

    private static func day(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: text)
    }
}
