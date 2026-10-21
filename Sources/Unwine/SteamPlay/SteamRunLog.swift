import Foundation

/// What NotProton's run script says about a Steam game's starts, from the game's own run log
/// (compatdata/<appid>/notproton-run.log). Read only. One Play can run the script twice: first for
/// Steam's install scripts (a helper), then for the game. The bottle closes for a moment between
/// the two, so only the script's own lines tell when the game's run really ended.
enum SteamRunLog {
    enum Event: Equatable, Sendable {
        case runStarted     // the script started: for the helper or for the game itself
        case helperEnded    // Steam's install-script helper finished; the game's own run comes next
        case gameEnded      // the game ended, and NotProton closed its bottle
        case stopped        // a run stopped before it launched anything
    }

    /// The size of the log now. A run after this writes its lines after it.
    static func end(of log: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: log.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// The script's events after `offset`, in order, and how far this read got. Only whole lines
    /// count: a line still being written waits for the next read. The script empties a log over
    /// 256 KB when a run starts, so a log shorter than `offset` is read from its start.
    static func events(in log: URL, since offset: UInt64) -> (events: [Event], end: UInt64) {
        guard let file = try? FileHandle(forReadingFrom: log) else { return ([], offset) }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()) ?? 0
        let from = size < offset ? 0 : offset
        guard size > from else { return ([], from) }
        try? file.seek(toOffset: from)
        let limit = 1 << 20     // at most 1 MB a look; the rest comes with the next one
        let data = (try? file.read(upToCount: min(Int(size - from), limit))) ?? Data()
        guard let last = data.lastIndex(of: 0x0A) else {
            return ([], data.count >= limit ? from + UInt64(data.count) : from)     // no line ends in a full read: skip it
        }
        var events: [Event] = []
        for line in String(decoding: data[..<last], as: UTF8.self).split(whereSeparator: \.isNewline) where line.hasPrefix("=== ") {
            if line.hasPrefix("=== notproton run ") { events.append(.runStarted) }
            else if line.hasPrefix("=== helper exited") { events.append(.helperEnded) }
            else if line.hasPrefix("=== game exited") { events.append(.gameEnded) }
            else if line.hasPrefix("=== aborted during") { events.append(.stopped) }
        }
        return (events, from + UInt64(last - data.startIndex) + 1)
    }
}

/// One Steam game's start as Unwine watches it, look by look: NotProton's run log and the lock of the
/// game's bottle. It ends early when the game's run ended before a window showed, when a run stopped
/// before its launch, or when the script was killed and wrote no end. The bottle closes for a moment
/// between Steam's install scripts and the game, so a closed bottle alone is never an end. The wait
/// takes two minutes, up to five while the script works with the bottle closed (it makes the bottle,
/// say), and each time the bottle opens, the game gets a minute more.
struct SteamStartWatch {
    enum Verdict: Equatable {
        case waiting
        case closedEarly
        case timedOut(started: Bool)    // false: only Steam's install scripts ran, or nothing at all
    }

    let start: Date
    private var seenOpen = false, ran = false, working = false, helperOnly = false
    private var openedAt: Date?, closedAt: Date?, stoppedAt: Date?
    private var grewAt: Date

    init(start: Date) {
        self.start = start
        grewAt = start
    }

    mutating func look(open: Bool, events: [SteamRunLog.Event], logGrew: Bool, now: Date) -> Verdict {
        if logGrew { grewAt = now }
        // An end counts only after a run of this start: the last lines of an earlier one do not.
        var ended = false
        for event in events {
            switch event {
            case .runStarted: ran = true; working = true; helperOnly = false; stoppedAt = nil
            case .helperEnded: working = false; helperOnly = true
            case .gameEnded: if ran { ended = true }; working = false
            case .stopped: if ran { stoppedAt = now }; working = false
            }
        }
        if open {
            if !seenOpen || closedAt != nil { openedAt = now }   // the latest time it opened
            seenOpen = true
            closedAt = nil
        } else if seenOpen, closedAt == nil {
            closedAt = now
        }
        let since = { (date: Date?) in date.map { now.timeIntervalSince($0) } ?? 0 }
        // A killed script: the bottle closed, and the log stayed quiet, for 45 seconds. After the install
        // scripts only, the game's own run is still to come, so that is no end.
        let silent = (working || !ran) && !open && since(closedAt) >= 45 && now.timeIntervalSince(grewAt) >= 45
        if ended || (!open && since(stoppedAt) >= 10) || silent { return .closedEarly }
        let limit = working && !open ? 300 : max(120, openedAt.map { $0.timeIntervalSince(start) + 60 } ?? 0)
        guard now.timeIntervalSince(start) >= limit else { return .waiting }
        return .timedOut(started: (seenOpen || ran) && !helperOnly)
    }
}
