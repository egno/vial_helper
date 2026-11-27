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

    private struct Request {
        let bytes: [UInt8]
        let timeout: TimeInterval
        let matchPrefix: Int
        /// Non-nil: no prefix matching, the first report this accepts is the reply.
        var accept: (([UInt8]) -> Bool)? = nil
        let completion: (HIDReply) -> Void
    }

    // Everything below is touched on `queue` only.
    private let queue = DispatchQueue(label: "VialHelper.HIDTransport")
    private var manager: IOHIDManager?
    private var devices: [IOHIDDevice] = []
    private var current: IOHIDDevice?
    private var waiting: [Request] = []
    private var inFlight: (id: Int, request: Request)?
    private var nextID = 0

    /// Starts watching for the keyboard. Safe to call more than once.
    func start() {
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
        return queue.sync {
            guard let device = current else { return false }
            return write(padded, to: device) == kIOReturnSuccess
        }
    }

    // MARK: - Queue side

    private func write(_ bytes: [UInt8], to device: IOHIDDevice) -> IOReturn {
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, bytes, bytes.count)
    }

    private func finish(_ request: Request, _ reply: HIDReply) {
        DispatchQueue.main.async { request.completion(reply) }
    }

    private func pump() {
        while inFlight == nil, !waiting.isEmpty {
            let request = waiting.removeFirst()
            guard let device = current else {
                finish(request, .notConnected)
                continue
            }
            let result = write(request.bytes, to: device)
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
        guard let pending = inFlight, let device = current,
              sender == Unmanaged.passUnretained(device).toOpaque(),
              bytes.count >= Self.reportSize else { return }
        let sent = pending.request.bytes
        let n = pending.request.matchPrefix
        let reply: HIDReply
        if let accept = pending.request.accept {
            let report = Array(bytes[..<Self.reportSize])
            if report[0] == Self.unhandledID, sent[0] != Self.unhandledID, report[1...] == sent[1...] {
                reply = .unhandled(report)
            } else if accept(report) {
                reply = .reply(report)
            } else {
                return
            }
        } else if bytes[0] == Self.unhandledID, sent[0] != Self.unhandledID {
            // An unknown command comes back with byte 0 replaced; the rest of the prefix still echoes.
            guard bytes[1..<n] == sent[1..<n] else { return }
            reply = .unhandled(bytes)
        } else if bytes[..<n] == sent[..<n] {
            reply = .reply(Array(bytes[..<Self.reportSize]))
        } else {
            return // someone else's reply (e.g. the Vial GUI's), or a late one
        }
        inFlight = nil
        finish(pending.request, reply)
        pump()
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
