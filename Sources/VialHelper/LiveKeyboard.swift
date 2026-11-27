import Foundation
import Combine

/// Live data from the keyboard for the overlay: misfire table (0xF3), layer / lock / trainer
/// state (0xF4), trainer results (0xF5, into `TrainerHistory`) and Chordal Hold exemptions (0xF6).
///
/// Polling of 0xF4: ~12 Hz while the overlay is visible, every 5 s otherwise (the trainer is
/// used with the overlay closed; this is how a finished session is noticed). A poll is skipped
/// while the previous one is unanswered, so the serialized transport never queues up polls.
///
/// Older firmware answers 0xF4-0xF6 with "unhandled". Each command is then dropped silently
/// until the next connect; nothing is shown and nothing is retried.
final class LiveKeyboard: ObservableObject {
    static let shared = LiveKeyboard()

    static let fastInterval: TimeInterval = 1.0 / 12
    static let slowInterval: TimeInterval = 5

    /// Tracked mod-taps of the base layer; empty when unknown.
    @Published private(set) var misfires: [MisfireEntry] = []
    /// The `m` toggle of the overlay.
    @Published var showMisfires: Bool {
        didSet { UserDefaults.standard.set(showMisfires, forKey: "showMisfires") }
    }
    /// nil while disconnected or when the firmware has no 0xF4.
    @Published private(set) var state: LiveState?
    /// nil while disconnected or when the firmware has no 0xF6.
    @Published private(set) var tapHold: TapHoldInfo?

    /// Requests sent per command id since launch (debug: `--live-probe`).
    private(set) var requestCounts: [UInt8: Int] = [:]

    private let link = KeyboardLink.shared
    private weak var model: KeymapModel?
    private weak var settings: AppSettings?
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var connected = false
    private(set) var overlayVisible = false

    private var stateSupported = true
    private var tapHoldSupported = true
    private var trainerSupported = true
    private var misfireSupported = true
    private var stateUnhandledStreak = 0
    private var statePollInFlight = false
    private var misfireFetchInFlight = false
    private var tapHoldFetchInFlight = false
    private var trainerFetchInFlight = false
    private var trainerFetchPending = false
    /// Sessions counter of the last 0xF4 reply of this connection.
    private var lastSessions: Int?
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0

    var history = TrainerHistory.shared

    private init() {
        let d = UserDefaults.standard
        showMisfires = d.object(forKey: "showMisfires") == nil ? true : d.bool(forKey: "showMisfires")
    }

    var misfireBadges: [Int: MisfireBadge] { MisfireBadge.badges(for: misfires) }

    /// Begins following the keyboard link. `model.chordalExempt` is filled from 0xF6.
    func start(model: KeymapModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        guard !started else { return }
        started = true
        link.$isConnected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.connectionChanged($0) }
            .store(in: &cancellables)
    }

    /// Called by the overlay when it appears / disappears.
    func setOverlayVisible(_ visible: Bool) {
        guard visible != overlayVisible else { return }
        overlayVisible = visible
        if visible, connected {
            refreshMisfires()
            refreshTapHold()
            pollState()
        }
        scheduleTimer()
    }

    func toggleMisfires() { showMisfires.toggle() }

    func resetMisfires(completion: ((Bool) -> Void)? = nil) {
        count(KeyboardLink.LiveCommand.misfire)
        link.resetMisfires { [weak self] ok in
            if ok { self?.refreshMisfires() }
            completion?(ok)
        }
    }

    // MARK: - Connection

    private func connectionChanged(_ isConnected: Bool) {
        connected = isConnected
        stateSupported = true
        tapHoldSupported = true
        trainerSupported = true
        misfireSupported = true
        stateUnhandledStreak = 0
        statePollInFlight = false
        misfireFetchInFlight = false
        tapHoldFetchInFlight = false
        trainerFetchInFlight = false
        trainerFetchPending = false
        lastSessions = nil
        if state != nil { state = nil }
        if tapHold != nil { tapHold = nil }
        if !misfires.isEmpty { misfires = [] }
        if let model, !model.chordalExempt.isEmpty { model.chordalExempt = [] }
        if isConnected {
            refreshTapHold()
            refreshMisfires()
            pollState()
        }
        scheduleTimer()
    }

    private func count(_ command: UInt8, _ n: Int = 1) { requestCounts[command, default: 0] += n }

    // MARK: - 0xF3

    func refreshMisfires() {
        guard connected, misfireSupported, !misfireFetchInFlight else { return }
        misfireFetchInFlight = true
        link.fetchMisfires { [weak self] result in
            guard let self else { return }
            self.misfireFetchInFlight = false
            switch result {
            case .ok(let entries):
                self.count(KeyboardLink.LiveCommand.misfire, max(entries.count, 1))
                if entries != self.misfires { self.misfires = entries }
            case .unsupported:
                self.count(KeyboardLink.LiveCommand.misfire)
                self.misfireSupported = false
            case .failed:
                self.count(KeyboardLink.LiveCommand.misfire)
            }
        }
    }

    // MARK: - 0xF6

    func refreshTapHold() {
        guard connected, tapHoldSupported, !tapHoldFetchInFlight else { return }
        tapHoldFetchInFlight = true
        count(KeyboardLink.LiveCommand.tapHold)
        // Layer 0: the exemption and hand masks do not depend on the layer anyway.
        link.fetchTapHold(layer: 0) { [weak self] result in
            guard let self else { return }
            self.tapHoldFetchInFlight = false
            switch result {
            case .ok(let info): self.apply(tapHold: info)
            case .unsupported: self.tapHoldSupported = false
            case .failed: break
            }
        }
    }

    func apply(tapHold info: TapHoldInfo) {
        if info != tapHold { tapHold = info }
        if let model, model.chordalExempt != info.chordalExempt { model.chordalExempt = info.chordalExempt }
    }

    // MARK: - 0xF4

    private func scheduleTimer() {
        let interval: TimeInterval = !connected || !stateSupported ? 0 : (overlayVisible ? Self.fastInterval : Self.slowInterval)
        guard interval != timerInterval else { return }
        timerInterval = interval
        timer?.invalidate()
        timer = nil
        guard interval > 0 else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.pollState() }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func pollState() {
        guard connected, stateSupported, !statePollInFlight else { return }
        statePollInFlight = true
        count(KeyboardLink.LiveCommand.state)
        link.fetchState { [weak self] result in
            guard let self else { return }
            self.statePollInFlight = false
            switch result {
            case .ok(let s):
                self.stateUnhandledStreak = 0
                self.apply(state: s)
            case .unsupported:
                // The interface is shared with the Vial GUI, whose own "unhandled" replies look
                // the same; believe it the second time in a row.
                self.stateUnhandledStreak += 1
                if self.stateUnhandledStreak >= 2 {
                    self.stateSupported = false
                    if self.state != nil { self.state = nil }
                    self.scheduleTimer()
                }
            case .failed:
                break
            }
        }
    }

    func apply(state s: LiveState) {
        let previous = state
        if s != previous { state = s }
        if s.highestLayer != previous?.highestLayer { follow(s) }
        if connected, lastSessions != s.sessionsFinished {
            let first = lastSessions == nil
            lastSessions = s.sessionsFinished
            // On connect only when a session exists; a wrapped counter still differs from nil.
            if !first || s.sessionsFinished > 0 { fetchTrainer(foundOnConnect: first) }
        }
    }

    /// "Follow the active layer": with a single layer zoomed, switch to the highest active one.
    private func follow(_ s: LiveState) {
        guard overlayVisible, let model, let settings, settings.followActiveLayer,
              let selected = model.selectedLayer, selected != s.highestLayer,
              model.visibleLayers.contains(s.highestLayer) else { return }
        model.select(s.highestLayer)
    }

    // MARK: - 0xF5

    private func fetchTrainer(foundOnConnect: Bool) {
        guard connected, trainerSupported else { return }
        if trainerFetchInFlight { trainerFetchPending = true; return }
        trainerFetchInFlight = true
        func done() {
            trainerFetchInFlight = false
            if trainerFetchPending {
                trainerFetchPending = false
                fetchTrainer(foundOnConnect: false)
            }
        }
        count(KeyboardLink.LiveCommand.trainer)
        link.fetchTrainerSummary { [weak self] result in
            guard let self else { return }
            switch result {
            case .ok(let summary):
                guard summary.hasSession else { return done() }
                self.link.fetchTrainerChars { [weak self] chars in
                    guard let self else { return }
                    self.count(KeyboardLink.LiveCommand.trainer, 32)
                    if case .unsupported = chars { self.trainerSupported = false }
                    // Without the character table the session itself is still worth keeping.
                    self.history.add(summary: summary, cumulativeChars: chars.value ?? [],
                                     foundOnConnect: foundOnConnect, firmware: self.link.firmware?.gitHash)
                    done()
                }
            case .unsupported:
                self.trainerSupported = false
                done()
            case .failed:
                done()
            }
        }
    }

    // MARK: - Debug injection (rendering without a keyboard)

    func inject(misfires: [MisfireEntry]) { self.misfires = misfires }
    func inject(state: LiveState?) { self.state = state }
}
