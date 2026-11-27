import Foundation
import Combine

/// What the firmware reports about itself (command 0xF0).
struct FirmwareInfo: Equatable {
    var version: String
    var buildDate: String
    var gitHash: String

    /// Just the day of the build ("2026-11-26" from "2026-11-26-12:34:56").
    var buildDay: String { String(buildDate.prefix(10)) }
}

/// Typed commands of the vial_full keymap (protocol: host_hid.h in the keymap folder) on top of
/// `HIDTransport`. All published state changes and completions happen on the main thread.
final class KeyboardLink: ObservableObject {
    static let shared = KeyboardLink()

    enum Command {
        static let version: UInt8 = 0xF0
        static let status: UInt8 = 0xF2
    }

    static let statusRows = 3
    static let statusCols = 5

    let transport = HIDTransport()

    @Published private(set) var isConnected = false
    @Published private(set) var productName: String?
    /// Fetched on every connect; nil while disconnected or when the firmware lacks 0xF0.
    @Published private(set) var firmware: FirmwareInfo?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        transport.$productName
            .sink { [weak self] in self?.productName = $0 }
            .store(in: &cancellables)
        transport.$isConnected
            .removeDuplicates()
            .sink { [weak self] connected in
                guard let self else { return }
                self.firmware = nil
                self.isConnected = connected
                if connected {
                    self.fetchFirmware { [weak self] info in self?.firmware = info }
                }
            }
            .store(in: &cancellables)
    }

    /// Starts watching for the keyboard. Safe to call more than once.
    func start() { transport.start() }

    /// One-line connection summary for the menu.
    var statusLine: String {
        guard isConnected else { return "Keyboard not connected" }
        var parts = ["\(productName ?? "Keyboard") connected"]
        if let fw = firmware {
            if !fw.gitHash.isEmpty { parts.append(fw.gitHash) }
            if !fw.buildDay.isEmpty { parts.append(fw.buildDay) }
        }
        return parts.joined(separator: " · ")
    }

    /// Calls `body(true)` once the keyboard is connected, or `body(false)` after `timeout`.
    func whenConnected(timeout: TimeInterval, _ body: @escaping (Bool) -> Void) {
        var done = false
        var subscription: AnyCancellable?
        subscription = $isConnected.filter { $0 }.first()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                guard !done else { return }
                done = true
                body(true)
            }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            subscription?.cancel()
            guard !done else { return }
            done = true
            body(false)
        }
    }

    // MARK: - 0xF0 firmware version

    /// One version string; field 0 = version, 1 = build date, 2 = git hash.
    func versionField(_ field: UInt8, completion: @escaping (HIDReply, String?) -> Void) {
        transport.request([Command.version, field], matchPrefix: 2) { reply in
            guard let bytes = reply.bytes else { return completion(reply, nil) }
            let text = bytes[2...].prefix { $0 != 0 }
            completion(reply, String(decoding: text, as: UTF8.self))
        }
    }

    /// All three version strings, or nil if any of them could not be read.
    func fetchFirmware(completion: @escaping (FirmwareInfo?) -> Void) {
        versionField(0) { [self] _, version in
            guard let version else { return completion(nil) }
            versionField(1) { [self] _, date in
                guard let date else { return completion(nil) }
                versionField(2) { _, hash in
                    guard let hash else { return completion(nil) }
                    completion(FirmwareInfo(version: version, buildDate: date, gitHash: hash))
                }
            }
        }
    }

    // MARK: - 0xF2 host status text (right OLED)

    /// The 0xF2 report: up to 3 rows of 5 ASCII characters; `invert` bit n inverts row n.
    /// The keyboard drops the text `ttl` seconds after the last report; ttl 0 clears it at once.
    static func statusReport(rows: [String], invert: UInt8 = 0, ttl: UInt8) -> [UInt8] {
        var report: [UInt8] = [Command.status, ttl, invert]
        for i in 0..<statusRows {
            let row = i < rows.count ? rows[i] : ""
            var cells = row.unicodeScalars.prefix(statusCols).map { s -> UInt8 in
                s.isASCII && s.value >= 0x20 && s.value < 0x7F ? UInt8(s.value) : UInt8(ascii: "?")
            }
            cells += [UInt8](repeating: UInt8(ascii: " "), count: statusCols - cells.count)
            report += cells
        }
        return report
    }

    func sendStatus(rows: [String], invert: UInt8 = 0, ttl: UInt8 = 90, completion: ((HIDReply) -> Void)? = nil) {
        transport.request(Self.statusReport(rows: rows, invert: invert, ttl: ttl), matchPrefix: 2) { completion?($0) }
    }

    func clearStatus(completion: ((HIDReply) -> Void)? = nil) {
        sendStatus(rows: [], ttl: 0, completion: completion)
    }

    /// Clears the status text without waiting for the reply (for app shutdown).
    func clearStatusNow() {
        transport.sendWithoutReply(Self.statusReport(rows: [], ttl: 0))
    }
}
