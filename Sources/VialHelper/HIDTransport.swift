import Foundation
import Combine
import IOKit
import IOKit.hid

// Raw HID transport to a QMK keyboard (IOKit, no dependencies).
//
// Talks to the QMK raw HID interface (usage page 0xFF60, usage 0x61): 32-byte reports without
// a report id, one reply per request. The device is opened shared (not seized), so the Vial GUI
// can use it at the same time. Both programs then see every input report, which is why a reply
// is only delivered when it matches the request in flight; everything else is dropped.
//
//     let hid = HIDTransport()
//     hid.start()                                   // idempotent; begins tracking the device
//     hid.$isConnected / hid.productName            // published on the main thread
//     hid.request([0xF0, 2]) { reply in             // completion runs on the main thread
//         if case .reply(let bytes) = reply { ... } // always 32 bytes
//     }
//
// - `request` never blocks: I/O happens on a private serial queue. Requests are serialized,
//   one in flight; the next is written once the previous got its reply or timed out.
// - A reply matches when its first `matchPrefix` bytes equal the request's (default 1, the
//   command id). Use a longer prefix when the firmware echoes more (sub-command, offset...).
// - `.unhandled`: the firmware answered with byte 0 = 0xFF (how QMK/VIA report an unknown
//   command) and bytes 1..<matchPrefix still echo the request.
// - A reply that arrives after its request timed out is dropped, unless an identical request
//   is in flight by then.
// - `request(_:timeout:accept:completion:)` is for commands whose reply does not echo the request
//   (most Vial 0xFE commands overwrite the buffer from byte 0): the next report `accept` returns
//   true for is the reply. Give `accept` whatever the reply layout allows checking, so a stray
//   report (the Vial GUI's reply, a late one) is not mistaken for it.
// - `sendWithoutReply` writes one report synchronously and waits for nothing (app shutdown).
// - Unsolicited 0xF7 events (see `eventKind`) are taken out of the stream before any reply
//   matching and handed to `onEvent`: they are never the reply to a request and never end one,
//   whatever its prefix or `accept` would have let through (a Vial definition page accepts any
//   report). The one exception is the request for that very report ([0xF7, 1] / [0xF7, 2]).
// - `HIDTransport(loopback:)` talks to a closure instead of a device (self-tests).
// - With several matching keyboards the first one found is used.

enum HIDReply: Equatable {
    /// The 32-byte reply.
    case reply([UInt8])
    /// The firmware does not know the command (byte 0 = 0xFF); the raw report is attached.
    case unhandled([UInt8])
    case timeout
    case notConnected
    /// The report could not be written (IOReturn code), or the request was longer than a report.
    case sendFailed(Int32)

    var bytes: [UInt8]? {
        if case .reply(let b) = self { return b }
        return nil
    }

    var summary: String {
        switch self {
        case .reply(let b): return "reply " + b.map { String(format: "%02x", $0) }.joined()
        case .unhandled: return "unhandled (the firmware does not know this command)"
        case .timeout: return "timeout"
        case .notConnected: return "not connected"
        case .sendFailed(let code): return String(format: "send failed (0x%08x)", UInt32(bitPattern: code))
        }
    }
}

final class HIDTransport: ObservableObject {
    static let reportSize = 32
    static let usagePage = 0xFF60
    static let usage = 0x61
    static let unhandledID: UInt8 = 0xFF

    @Published private(set) var isConnected = false
    /// USB product string of the connected keyboard, e.g. "Aurora Corne rev1".
    @Published private(set) var productName: String?
    /// Non-nil when IOKit refused to open the HID interface (e.g. a privacy denial).
    @Published private(set) var openError: Int32?

    /// Unsolicited 0xF7 reports (state / matrix events), on the main thread, in the order they
    /// arrived and in order with the request completions. Set before `start`.
    var onEvent: (([UInt8]) -> Void)?

    private struct Request {
        let bytes: [UInt8]
        let timeout: TimeInterval
        let matchPrefix: Int
        /// Non-nil: no prefix matching, the first report this accepts is the reply.
        var accept: (([UInt8]) -> Bool)? = nil
        let completion: (HIDReply) -> Void
    }

    /// What an incoming report is to the request in flight (if any).
    enum Disposition: Equatable {
        /// An unsolicited 0xF7 event: goes to `onEvent`, the request in flight keeps waiting.
        case event
        case reply(HIDReply)
        /// Someone else's reply (e.g. the Vial GUI's), or a late one.
        case ignore
    }

    static let eventsID: UInt8 = 0xF7

    /// 1 (state) or 2 (matrix) when `report` has the exact shape of a 0xF7 event, else nil.
    /// Deliberately strict (status 0, the zero tail, a sane layer count / matrix size), so that
    /// a reply without a prefix of its own, such as a page of the compressed Vial definition
    /// or a definition size of 503 bytes (f7 01 00 00), is not mistaken for an event.
    static func eventKind(_ report: [UInt8]) -> Int? {
        guard report.count >= reportSize, report[0] == eventsID, report[2] == 0 else { return nil }
        switch report[1] {
        case 1:
            // Byte 25 is the number of layers; 26-31 are always 0.
            guard (1...32).contains(report[25]), !report[26..<reportSize].contains(where: { $0 != 0 }) else { return nil }
            return 1
        case 2:
            let positions = Int(report[3]) * Int(report[4])
            guard (1...48).contains(positions), !report[11..<reportSize].contains(where: { $0 != 0 }) else { return nil }
            return 2
        default:
            return nil
        }
    }

    /// The whole reply matching, as a pure function (tested in LiveSelfTest). `sent` is the
    /// request in flight, zero-padded.
    static func classify(_ bytes: [UInt8], sent: [UInt8]?, matchPrefix n: Int, accept: (([UInt8]) -> Bool)?) -> Disposition {
        guard bytes.count >= reportSize else { return .ignore }
        let report = Array(bytes[..<reportSize])
        if eventKind(report) != nil {
            // Asked for by [0xF7, 1] / [0xF7, 2], the same bytes are that request's reply.
            let askedFor = sent.map { accept == nil && $0[0] == eventsID && $0[1] == report[1] } ?? false
            if !askedFor { return .event }
        }
        guard let sent else { return .ignore }
        if let accept {
            if report[0] == unhandledID, sent[0] != unhandledID, report[1...] == sent[1...] { return .reply(.unhandled(report)) }
            return accept(report) ? .reply(.reply(report)) : .ignore
        }
        if report[0] == unhandledID, sent[0] != unhandledID {
            // An unknown command comes back with byte 0 replaced; the rest of the prefix still echoes.
            return report[1..<n] == sent[1..<n] ? .reply(.unhandled(report)) : .ignore
        }
        return report[..<n] == sent[..<n] ? .reply(.reply(report)) : .ignore
    }

    // Everything below is touched on `queue` only.
    private let queue = DispatchQueue(label: "VialHelper.HIDTransport")
    private var manager: IOHIDManager?
    private var devices: [IOHIDDevice] = []
    private var current: IOHIDDevice?
    private var waiting: [Request] = []
    private var inFlight: (id: Int, request: Request)?
    private var nextID = 0
    /// Self-tests: stands in for the device. Called on `queue` with every report written;
    /// what it returns comes back as input reports, in order.
    private let loopback: (([UInt8]) -> [[UInt8]])?

    init() { loopback = nil }

    /// A transport without a device: `responder` plays the keyboard (see `loopback`).
    init(loopback responder: @escaping ([UInt8]) -> [[UInt8]]) { loopback = responder }

    /// Loopback only: a report the "keyboard" sends unasked.
    func injectReport(_ bytes: [UInt8]) {
        queue.async { [self] in handle(bytes) }
    }

    /// Starts watching for the keyboard. Safe to call more than once.
    func start() {
        if loopback != nil {
            DispatchQueue.main.async { [self] in
                productName = "Loopback"
                isConnected = true
            }
            return
        }
        queue.async { [self] in
            guard manager == nil else { return }
            let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            manager = m
            IOHIDManagerSetDeviceMatching(m, [
                kIOHIDDeviceUsagePageKey: Self.usagePage,
                kIOHIDDeviceUsageKey: Self.usage,
            ] as CFDictionary)
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
                Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue().deviceAdded(device)
            }, ctx)
            IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
                Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue().deviceRemoved(device)
            }, ctx)
            IOHIDManagerRegisterInputReportCallback(m, { ctx, _, sender, _, _, report, length in
                let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue().reportReceived(bytes, from: sender)
            }, ctx)
            // Open before activating: opening an activated manager trips an IOKit assertion.
            let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) // shared, not seized
            if result != kIOReturnSuccess {
                DispatchQueue.main.async { self.openError = result }
            }
            IOHIDManagerSetDispatchQueue(m, queue)
            IOHIDManagerActivate(m)
        }
    }

    /// Sends `bytes` (zero-padded to 32) and reports the matching reply on the main thread.
    func request(_ bytes: [UInt8], timeout: TimeInterval = 0.5, matchPrefix: Int = 1,
                 completion: @escaping (HIDReply) -> Void) {
        guard !bytes.isEmpty, bytes.count <= Self.reportSize else {
            DispatchQueue.main.async { completion(.sendFailed(kIOReturnBadArgument)) }
            return
        }
        let padded = bytes + [UInt8](repeating: 0, count: Self.reportSize - bytes.count)
        let request = Request(bytes: padded, timeout: timeout,
                              matchPrefix: min(max(matchPrefix, 1), Self.reportSize), completion: completion)
        queue.async { [self] in
            waiting.append(request)
            pump()
        }
    }

    /// Like `request`, for replies that do not echo the request: the first report `accept`
    /// returns true for is the reply. `accept` runs on the transport queue; keep it pure.
    /// A report that is the request with byte 0 replaced by 0xFF is reported as `.unhandled`.
    func request(_ bytes: [UInt8], timeout: TimeInterval = 0.5, accept: @escaping ([UInt8]) -> Bool,
                 completion: @escaping (HIDReply) -> Void) {
        guard !bytes.isEmpty, bytes.count <= Self.reportSize else {
            DispatchQueue.main.async { completion(.sendFailed(kIOReturnBadArgument)) }
            return
        }
        let padded = bytes + [UInt8](repeating: 0, count: Self.reportSize - bytes.count)
        let request = Request(bytes: padded, timeout: timeout, matchPrefix: 0, accept: accept, completion: completion)
        queue.async { [self] in
            waiting.append(request)
            pump()
        }
    }

    /// Writes one report and returns once it is written, without waiting for (or consuming)
    /// the reply. Blocks the caller briefly; meant for the last message before the app exits.
    @discardableResult
    func sendWithoutReply(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty, bytes.count <= Self.reportSize else { return false }
        let padded = bytes + [UInt8](repeating: 0, count: Self.reportSize - bytes.count)
        return queue.sync { write(padded) == kIOReturnSuccess }
    }

    // MARK: - Queue side

    /// nil when there is nothing to write to.
    private func write(_ bytes: [UInt8]) -> IOReturn? {
        if let loopback {
            let reports = loopback(bytes)
            queue.async { [self] in reports.forEach(handle) }
            return kIOReturnSuccess
        }
        guard let device = current else { return nil }
        return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, bytes, bytes.count)
    }

    private func finish(_ request: Request, _ reply: HIDReply) {
        DispatchQueue.main.async { request.completion(reply) }
    }

    private func pump() {
        while inFlight == nil, !waiting.isEmpty {
            let request = waiting.removeFirst()
            guard let result = write(request.bytes) else {
                finish(request, .notConnected)
                continue
            }
            guard result == kIOReturnSuccess else {
                finish(request, .sendFailed(result))
                continue
            }
            nextID += 1
            let id = nextID
            inFlight = (id, request)
            queue.asyncAfter(deadline: .now() + request.timeout) { [self] in
                guard let pending = inFlight, pending.id == id else { return }
                inFlight = nil
                finish(pending.request, .timeout)
                pump()
            }
        }
    }

    private func reportReceived(_ bytes: [UInt8], from sender: UnsafeMutableRawPointer?) {
        guard let device = current, sender == Unmanaged.passUnretained(device).toOpaque() else { return }
        handle(bytes)
    }

    private func handle(_ bytes: [UInt8]) {
        let pending = inFlight
        switch Self.classify(bytes, sent: pending?.request.bytes, matchPrefix: pending?.request.matchPrefix ?? 0,
                             accept: pending?.request.accept) {
        case .event:
            let report = Array(bytes[..<Self.reportSize])
            DispatchQueue.main.async { [self] in onEvent?(report) }
        case .reply(let reply):
            guard let pending else { return }
            inFlight = nil
            finish(pending.request, reply)
            pump()
        case .ignore:
            break
        }
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        guard !devices.contains(where: { $0 === device }) else { return }
        devices.append(device)
        if current == nil { select(device) }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        devices.removeAll { $0 === device }
        guard current === device else { return }
        if let pending = inFlight {
            inFlight = nil
            finish(pending.request, .notConnected)
        }
        select(devices.first)
        pump()
    }

    private func select(_ device: IOHIDDevice?) {
        current = device
        let name = device.flatMap { IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String }
        DispatchQueue.main.async { [self] in
            productName = name
            isConnected = device != nil
        }
    }
}
