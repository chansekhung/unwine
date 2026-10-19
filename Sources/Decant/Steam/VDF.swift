import Foundation

/// A parsed Valve KeyValues ("VDF" / ".acf") node. Keys are matched case-insensitively,
/// because Steam itself writes both "AppState" and "appstate" over the years.
indirect enum VDF {
    case string(String)
    case object([(key: String, value: VDF)])

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var entries: [(key: String, value: VDF)] {
        if case .object(let e) = self { return e }
        return []
    }

    subscript(key: String) -> VDF? {
        entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    /// Follows a path of keys, e.g. `node["AppState", "name"]`.
    subscript(path: String...) -> VDF? {
        var node: VDF? = self
        for key in path { node = node?[key] }
        return node
    }

    // MARK: Parsing

    static func parse(_ text: String) -> VDF? {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        return parser.parseRoot()
    }

    static func parse(contentsOf url: URL) -> VDF? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return parse(text)
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var i = 0

        init(scalars: [Unicode.Scalar]) { self.scalars = scalars }

        enum Token: Equatable { case open, close, text(String) }

        mutating func parseRoot() -> VDF? {
            var items: [(key: String, value: VDF)] = []
            while let token = next() {
                guard case .text(let key) = token else { return items.isEmpty ? nil : .object(items) }
                guard let value = parseValue() else { break }
                items.append((key, value))
            }
            return items.isEmpty ? nil : .object(items)
        }

        mutating func parseValue() -> VDF? {
            guard let token = next() else { return nil }
            switch token {
            case .text(let s): return .string(s)
            case .open: return parseObjectBody()
            case .close: return nil
            }
        }

        mutating func parseObjectBody() -> VDF {
            var items: [(key: String, value: VDF)] = []
            while let token = next() {
                switch token {
                case .close: return .object(items)
                case .open: continue // malformed; skip
                case .text(let key):
                    guard let value = parseValue() else { return .object(items) }
                    items.append((key, value))
                }
            }
            return .object(items)
        }

        mutating func next() -> Token? {
            skipTrivia()
            guard i < scalars.count else { return nil }
            let c = scalars[i]
            switch c {
            case "{": i += 1; return .open
            case "}": i += 1; return .close
            case "\"": return .text(readQuoted())
            default: return .text(readBare())
            }
        }

        mutating func skipTrivia() {
            while i < scalars.count {
                let c = scalars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{FEFF}" {
                    i += 1
                } else if c == "/", i + 1 < scalars.count, scalars[i + 1] == "/" {
                    while i < scalars.count, scalars[i] != "\n" { i += 1 }
                } else if c == "[" {
                    // Conditional like [$WIN32]; ignore.
                    while i < scalars.count, scalars[i] != "]" { i += 1 }
                    i += 1
                } else {
                    break
                }
            }
        }

        mutating func readQuoted() -> String {
            i += 1 // opening quote
            var out = String.UnicodeScalarView()
            while i < scalars.count {
                let c = scalars[i]
                if c == "\\", i + 1 < scalars.count {
                    let n = scalars[i + 1]
                    switch n {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\\": out.append("\\")
                    case "\"": out.append("\"")
                    default: out.append(c); out.append(n)
                    }
                    i += 2
                    continue
                }
                if c == "\"" { i += 1; break }
                out.append(c)
                i += 1
            }
            return String(out)
        }

        mutating func readBare() -> String {
            var out = String.UnicodeScalarView()
            while i < scalars.count {
                let c = scalars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "{" || c == "}" || c == "\"" { break }
                out.append(c)
                i += 1
            }
            return String(out)
        }
    }
}
