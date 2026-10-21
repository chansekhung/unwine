import Foundation

/// The banner at the top of the library, a game's page and Settings: what happened, how it went,
/// and a button for the next step when there is one.
struct Banner: Identifiable {
    enum Kind {
        case info       // good to know; hides by itself once people had time to read it
        case success    // something the user asked for is done
        case problem    // something failed or could not start; stays until the user closes it
    }

    /// The banner's button: the next step its text names.
    struct Action {
        let title: String
        let run: @MainActor () -> Void

        init(_ title: String, run: @escaping @MainActor () -> Void) {
            self.title = title
            self.run = run
        }
    }

    let id = UUID()
    var text: String
    var kind: Kind = .info
    var action: Action?

    /// How long an info banner stays: about 8 seconds, longer when there is more to read.
    var readingTime: Double { max(8, Double(text.split(separator: " ").count) / 3) }

    /// The kind of a plain sentence from code that does not name one. A failure or a refused
    /// click is a problem, so it never hides by itself before the user saw it.
    static func kind(of text: String) -> Kind {
        let lower = text.lowercased()
        if ["did not", "could not", "cannot", "failed", "not set up", "no .exe", "is gone"].contains(where: lower.contains) {
            return .problem
        }
        // "Quit it first", "Close your game first": the click waits until something closes.
        if lower.range(of: #"\b(quit|close)\b[^.]*\bfirst\b"#, options: .regularExpression) != nil { return .problem }
        return .info
    }
}

extension AppModel {
    /// The banner's text. Code that sets a plain sentence gets the kind its words say (`Banner.kind(of:)`).
    var banner: String? {
        get { notice?.text }
        set { notice = newValue.map { Banner(text: $0, kind: Banner.kind(of: $0)) } }
    }

    /// Shows a banner. It takes the place of the one before.
    func show(_ text: String, _ kind: Banner.Kind = .info, action: Banner.Action? = nil) {
        notice = Banner(text: text, kind: kind, action: action)
    }

    /// Hides this banner, unless a newer one has taken its place.
    func hideBanner(_ id: UUID) {
        if notice?.id == id { notice = nil }
    }
}
