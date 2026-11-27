import Foundation
import Combine

/// One finished trainer session, as stored in the history file.
///
/// The session figures (wpm ... activeMs) are the keyboard's "last finished session" summary
/// (0xF5 sub 0) verbatim. `chars` is a *difference*: the keyboard only keeps per-character
/// counters cumulative since power-up, so each record stores what was added since the previous
/// record of the same power cycle (`bootID`), or the whole table for the first record of a power
/// cycle. `charSessions` says how many sessions that difference spans: 1 when the app saw every
/// session, more when sessions were finished while the app was not connected (their keystrokes
/// land in the next record). Keystrokes of aborted sessions are included as well. Only
/// characters with a non-zero difference are stored.
struct TrainerSessionRecord: Codable, Equatable {
    /// When the app noticed the session: right after it ended, or, with `foundOnConnect`, at the
    /// next connect (the session itself may be older).
    var timestamp: Date
    var foundOnConnect: Bool
    var firmware: String?

    var wpm: Int
    /// Percent, 100 * correct / (correct + misses), rounded down by the firmware.
    var accuracy: Int
    var items: Int
    var correct: Int
    var misses: Int
    var missWrongKey: Int
    var missHeld: Int
    var missTapped: Int
    var missWrongLayer: Int
    var activeMs: Int

    var bestWpm: Int
    var bestAccuracy: Int
    /// Sessions finished ever (EEPROM, saturates at 8191) and since power-up, at this session.
    var sessionsEver: Int
    var sessionsSincePowerUp: Int

    var charSessions: Int
    /// Keyed by the character itself (" " ... "~").
    var chars: [String: TrainerCharStat]

    /// Constant while the keyboard stays powered: both counters advance together.
    var bootID: Int { sessionsEver - sessionsSincePowerUp }

    func sameSession(as o: TrainerSessionRecord) -> Bool {
        bootID == o.bootID && sessionsSincePowerUp == o.sessionsSincePowerUp && wpm == o.wpm
            && correct == o.correct && misses == o.misses && activeMs == o.activeMs
    }
}

/// The JSON history in ~/Library/Application Support/VialHelper/trainer-history.json:
/// `{ "version": 1, "sessions": [TrainerSessionRecord, ...] }`, oldest first, ISO 8601 dates.
final class TrainerHistory: ObservableObject {
    static let shared = TrainerHistory(url: TrainerHistory.defaultURL)

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VialHelper/trainer-history.json")
    }

    private struct FileFormat: Codable {
        var version: Int
        var sessions: [TrainerSessionRecord]
    }

    /// nil = memory only (tests, fake data).
    let url: URL?
    @Published private(set) var records: [TrainerSessionRecord] = []
    @Published private(set) var lastError: String?

    init(url: URL?, records: [TrainerSessionRecord] = []) {
        self.url = url
        self.records = records
        if url != nil { load() }
    }

    func load() {
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            records = try decoder.decode(FileFormat.self, from: data).sessions
            lastError = nil
        } catch {
            // Leave the unreadable file alone: `save` refuses to overwrite it.
            lastError = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Builds the record for a freshly fetched summary + cumulative character table and appends
    /// it. Returns nil when there is nothing new (no session, or the same session is already the
    /// newest record of its power cycle, e.g. after an app restart or a reconnect).
    @discardableResult
    func add(summary s: TrainerSummary, cumulativeChars: [TrainerCharStat], foundOnConnect: Bool,
             firmware: String?, now: Date = Date()) -> TrainerSessionRecord? {
        guard s.hasSession else { return nil }
        var record = TrainerSessionRecord(
            timestamp: now, foundOnConnect: foundOnConnect, firmware: firmware,
            wpm: s.wpm, accuracy: s.accuracy, items: s.items, correct: s.correct, misses: s.misses,
            missWrongKey: s.missWrongKey, missHeld: s.missHeld, missTapped: s.missTapped,
            missWrongLayer: s.missWrongLayer, activeMs: s.activeMs,
            bestWpm: s.bestWpm, bestAccuracy: s.bestAccuracy,
            sessionsEver: s.sessionsEver, sessionsSincePowerUp: s.sessionsFinished,
            charSessions: s.sessionsFinished, chars: [:])
        let sameBoot = records.filter { $0.bootID == record.bootID }
        if let last = sameBoot.last, last.sameSession(as: record) { return nil }

        // What earlier records of this power cycle already account for.
        var seen: [String: TrainerCharStat] = [:]
        for r in sameBoot {
            for (ch, st) in r.chars {
                let p = seen[ch] ?? TrainerCharStat(correct: 0, misses: 0, latencyMs: 0)
                seen[ch] = TrainerCharStat(correct: p.correct + st.correct, misses: p.misses + st.misses,
                                           latencyMs: p.latencyMs + st.latencyMs)
            }
        }
        var cumulative: [String: TrainerCharStat] = [:]
        for (i, st) in cumulativeChars.enumerated() where !st.isZero {
            guard let scalar = UnicodeScalar(0x20 + i) else { continue }
            cumulative[String(Character(scalar))] = st
        }
        // The counters only grow within a power cycle; if they are behind what was recorded, the
        // boot id collided with an older power cycle and the table is taken whole.
        let consistent = seen.allSatisfy { ch, p in
            let c = cumulative[ch] ?? TrainerCharStat(correct: 0, misses: 0, latencyMs: 0)
            return c.correct >= p.correct && c.misses >= p.misses && c.latencyMs >= p.latencyMs
        }
        if consistent, let last = sameBoot.last, s.sessionsFinished > last.sessionsSincePowerUp {
            record.charSessions = s.sessionsFinished - last.sessionsSincePowerUp
            for (ch, c) in cumulative {
                let p = seen[ch] ?? TrainerCharStat(correct: 0, misses: 0, latencyMs: 0)
                let d = TrainerCharStat(correct: c.correct - p.correct, misses: c.misses - p.misses,
                                        latencyMs: c.latencyMs - p.latencyMs)
                if !d.isZero { record.chars[ch] = d }
            }
        } else {
            record.chars = cumulative
        }
        records.append(record)
        save()
        return record
    }

    private func save() {
        guard let url, lastError == nil else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(FileFormat(version: 1, sessions: records)).write(to: url, options: .atomic)
        } catch {
            lastError = "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Aggregates for the history window

    /// Per-character totals over all records.
    var charTotals: [(char: String, stat: TrainerCharStat)] {
        var sum: [String: TrainerCharStat] = [:]
        for r in records {
            for (ch, st) in r.chars {
                let p = sum[ch] ?? TrainerCharStat(correct: 0, misses: 0, latencyMs: 0)
                sum[ch] = TrainerCharStat(correct: p.correct + st.correct, misses: p.misses + st.misses,
                                          latencyMs: p.latencyMs + st.latencyMs)
            }
        }
        return sum.map { ($0.key, $0.value) }.sorted { $0.char < $1.char }
    }

    /// Deterministic sample data for `--render-trainer --fake-trainer`.
    static func fake(sessions n: Int = 24) -> TrainerHistory {
        var seed: UInt64 = 42
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        var records: [TrainerSessionRecord] = []
        let start = Date(timeIntervalSince1970: 1_795_000_000)
        let letters = Array("etaoinshrdlucmfwypvbgkqjxz ;,.-_(){}[]=/0123456789")
        for i in 0..<n {
            let t = Double(i) / Double(max(n - 1, 1))
            let wpm = Int(22 + 21 * t + (rnd() - 0.5) * 7)
            let accuracy = min(99, Int(84 + 11 * t + (rnd() - 0.5) * 6))
            let correct = 260 + Int(rnd() * 60)
            let misses = correct * (100 - accuracy) / max(accuracy, 1)
            let held = Int(Double(misses) * (0.30 - 0.15 * t))
            let tapped = Int(Double(misses) * 0.12)
            let layer = Int(Double(misses) * 0.10)
            var chars: [String: TrainerCharStat] = [:]
            for (k, ch) in letters.enumerated() {
                let count = max(1, Int(Double(correct) / Double(letters.count) * (0.5 + rnd())))
                let hard = ch.isLetter ? 0.03 : (ch.isNumber ? 0.10 : 0.16)
                let miss = Int(Double(count) * hard * (0.5 + rnd()) * (1.4 - 0.6 * t) + rnd() * 0.6)
                let latency = (ch.isLetter ? 190 : ch.isNumber ? 330 : 420) + (k % 7) * 18
                chars[String(ch)] = TrainerCharStat(correct: count, misses: miss,
                                                    latencyMs: Int(Double(count * latency) * (1.25 - 0.4 * t)))
            }
            records.append(TrainerSessionRecord(
                timestamp: start.addingTimeInterval(Double(i) * 86_400 * 0.7), foundOnConnect: false, firmware: "fake",
                wpm: wpm, accuracy: accuracy, items: 20, correct: correct, misses: misses,
                missWrongKey: misses - held - tapped - layer, missHeld: held, missTapped: tapped, missWrongLayer: layer,
                activeMs: correct * 12_000 / max(wpm, 1),
                bestWpm: max(wpm, records.map(\.bestWpm).max() ?? 0), bestAccuracy: max(accuracy, records.map(\.bestAccuracy).max() ?? 0),
                sessionsEver: 100 + i, sessionsSincePowerUp: i + 1, charSessions: 1, chars: chars))
        }
        return TrainerHistory(url: nil, records: records)
    }
}
