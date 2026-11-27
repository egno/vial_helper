import Foundation

/// Outcome of a typed live command.
enum LiveResult<T> {
    case ok(T)
    /// The firmware does not know the command (older build): stop asking until the next connect.
    case unsupported
    /// Timeout, disconnect, or a reply that does not parse: worth another try later.
    case failed

    var value: T? {
        if case .ok(let v) = self { return v }
        return nil
    }
}

/// Typed read-only commands 0xF3-0xF7 (parsers: LiveProtocol.swift). Replies echo bytes 0 and 1,
/// so every request matches on a 2-byte prefix; the index, where there is one, is checked here.
extension KeyboardLink {
    enum LiveCommand {
        static let misfire: UInt8 = 0xF3
        static let state: UInt8 = 0xF4
        static let trainer: UInt8 = 0xF5
        static let tapHold: UInt8 = 0xF6
        static let events: UInt8 = 0xF7
    }

    private func live<T>(_ bytes: [UInt8], timeout: TimeInterval = 0.5, parse: @escaping ([UInt8]) -> T?,
                         completion: @escaping (LiveResult<T>) -> Void) {
        transport.request(bytes, timeout: timeout, matchPrefix: 2) { reply in
            switch reply {
            case .reply(let b):
                if let v = parse(b) { completion(.ok(v)) } else { completion(.failed) }
            case .unhandled:
                completion(.unsupported)
            default:
                completion(.failed)
            }
        }
    }

    // MARK: 0xF3 misfire log

    func misfireEntry(_ index: Int, completion: @escaping (LiveResult<(count: Int, entry: MisfireEntry?)>) -> Void) {
        live([LiveCommand.misfire, 0, UInt8(index)], parse: { b in
            guard let r = MisfireEntry.parse(b), r.entry == nil || r.entry?.index == index else { return nil }
            return r
        }, completion: completion)
    }

    /// The whole table; `.ok([])` when the keyboard tracks no key.
    func fetchMisfires(completion: @escaping (LiveResult<[MisfireEntry]>) -> Void) {
        var entries: [MisfireEntry] = []
        func step(_ index: Int) {
            misfireEntry(index) { result in
                switch result {
                case .ok(let r):
                    if let e = r.entry { entries.append(e) }
                    if r.entry != nil, index + 1 < r.count { step(index + 1) } else { completion(.ok(entries)) }
                case .unsupported: completion(.unsupported)
                case .failed: completion(.failed)
                }
            }
        }
        step(0)
    }

    /// Zeroes all counters on the keyboard.
    func resetMisfires(completion: @escaping (Bool) -> Void) {
        transport.request([LiveCommand.misfire, 1], matchPrefix: 2) { reply in
            completion(reply.bytes.map { $0[2] == 0 } ?? false)
        }
    }

    // MARK: 0xF4 live state

    func fetchState(timeout: TimeInterval = 0.3, completion: @escaping (LiveResult<LiveState>) -> Void) {
        live([LiveCommand.state, 0], timeout: timeout, parse: LiveState.parse, completion: completion)
    }

    // MARK: 0xF5 trainer

    func fetchTrainerSummary(completion: @escaping (LiveResult<TrainerSummary>) -> Void) {
        live([LiveCommand.trainer, 0], parse: TrainerSummary.parse, completion: completion)
    }

    /// The per-character table, indexed by ASCII code - 0x20 (95 entries).
    func fetchTrainerChars(completion: @escaping (LiveResult<[TrainerCharStat]>) -> Void) {
        var stats: [TrainerCharStat] = []
        func step(_ index: Int) {
            live([LiveCommand.trainer, 1, UInt8(index)], parse: { b -> TrainerCharsPage? in
                guard let p = TrainerCharsPage.parse(b), p.index == index else { return nil }
                return p
            }, completion: { (result: LiveResult<TrainerCharsPage>) in
                switch result {
                case .ok(let page):
                    stats += page.stats
                    let next = index + page.stats.count
                    if page.stats.isEmpty || next >= min(page.total, 224) { completion(.ok(stats)) } else { step(next) }
                case .unsupported: completion(.unsupported)
                case .failed: completion(.failed)
                }
            })
        }
        step(0)
    }

    // MARK: 0xF6 tap-hold

    /// `layer` 0xFF = the keycodes as resolved with the layers active right now.
    func fetchTapHold(layer: UInt8 = 0, completion: @escaping (LiveResult<TapHoldInfo>) -> Void) {
        live([LiveCommand.tapHold, layer], parse: TapHoldInfo.parse, completion: completion)
    }

    // MARK: 0xF7 events

    /// Subscribes to state and matrix events for `ttl` seconds (0 ends the subscription). The
    /// events themselves arrive through `transport.onEvent`. `.ok` carries the ttl as applied.
    func subscribeEvents(ttl: UInt8, completion: @escaping (LiveResult<Int>) -> Void) {
        live([LiveCommand.events, 0, ttl], parse: { b in
            LiveEvent.parseSubscribed(b).flatMap { $0 == Int(ttl) ? $0 : nil }
        }, completion: completion)
    }

    /// Ends the subscription without waiting for the reply (for app shutdown).
    func unsubscribeEventsNow() {
        transport.sendWithoutReply([LiveCommand.events, 0, 0])
    }

    /// The current state / matrix event as a reply; works without a subscription (debug).
    func fetchEvent(kind: UInt8, completion: @escaping (LiveResult<LiveEvent>) -> Void) {
        live([LiveCommand.events, kind], parse: LiveEvent.parse, completion: completion)
    }
}
