import AppKit
import Combine

/// Live data from the keyboard for the overlay: misfire table (0xF3), layer / lock / trainer
/// state (0xF4), trainer results (0xF5, into `TrainerHistory`) and Chordal Hold exemptions (0xF6).
///
/// The 0xF4 state is needed fast while the overlay or the ghost is on. Firmware with 0xF7 pushes
/// it: the app subscribes (ttl `pushTTL`, renewed every third of it), takes the state events as
/// it takes poll replies and polls only every 5 s, as a safety net. Otherwise, and whenever a
/// subscription cannot be held (0xF7 unknown, renewals failing, the Vial GUI running: see
/// `VialGUIWatcher`), 0xF4 is polled at ~12 Hz. With nothing on screen it is polled every 5 s
/// (the trainer is used with the overlay closed; this is how a finished session is noticed).
/// A poll is skipped while the previous one is unanswered, so the serialized transport never
/// queues up polls.
///
/// Older firmware answers 0xF4-0xF7 with "unhandled". Each command is then dropped silently
/// until the next connect; nothing is shown and nothing is retried.
final class LiveKeyboard: ObservableObject {
    static let shared = LiveKeyboard()

    static let fastInterval: TimeInterval = 1.0 / 12
    static let slowInterval: TimeInterval = 5
    /// Lifetime of the 0xF7 subscription in seconds: short, so the reports stop soon after the
    /// app dies without unsubscribing.
    static let pushTTL: UInt8 = 5

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

    /// The keys physically down (0xF7 matrix events), for the ghost's highlight and for its
    /// "While typing" visibility. An object of its own: a key press must not redraw everything
    /// that observes the rest of the live data. Stays empty unless `tracksMatrix`; `lit` only
    /// with `usesMatrix`.
    let pressed = PressedKeys()

    /// Requests sent per command id since launch (debug: `--live-probe`).
    private(set) var requestCounts: [UInt8: Int] = [:]
    /// 0xF7 events received since launch, by kind (1 state, 2 matrix).
    private(set) var eventCounts: [Int: Int] = [:]
    /// The keyboard is pushing its state: the last subscribe request was acknowledged less than
    /// its ttl ago.
    private(set) var pushActive = false
    /// Debug / self-tests: stands in for the "Highlight pressed keys" setting.
    var matrixOverride: Bool? {
        didSet { syncPressed() }
    }
    /// Self-tests shorten the subscription.
    var pushTTL = LiveKeyboard.pushTTL

    private let link: KeyboardLink
    private let vialGUI: VialGUIWatcher
    private weak var model: KeymapModel?
    private weak var settings: AppSettings?
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var connected = false
    private(set) var overlayVisible = false
    private(set) var ghostVisible = false

    @Published private(set) var stateSupported = true
    @Published private(set) var tapHoldSupported = true
    @Published private(set) var trainerSupported = true
    @Published private(set) var misfireSupported = true
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

    @Published private(set) var pushSupported = true
    private var pushUnhandledStreak = 0
    private var subscribeInFlight = false
    /// A subscribe request went out on this connection and no unsubscribe after it.
    private var mayBeSubscribed = false
    private var lastSubscribed = Date.distantPast
    /// Bumped whenever the subscription is given up, so a late subscribe reply is ignored.
    private var pushGeneration = 0
    private var renewTimer: Timer?
    private var vialGUIRunning = false
    private var highlightPressed = false
    /// The ghost hides when idle in "While typing" and wants the key presses of this keyboard.
    private var ghostWantsPresses = false

    var history = TrainerHistory.shared

    /// `.shared` follows the keyboard; other instances are for self-tests (loopback link).
    init(link: KeyboardLink = .shared, vialGUI: VialGUIWatcher = .shared) {
        self.link = link
        self.vialGUI = vialGUI
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
        vialGUIRunning = vialGUI.isRunning
        link.transport.onEvent = { [weak self] in self?.received(event: $0) }
        link.transport.onForeignReport = { [weak self] in self?.foreignReportSeen() }
        link.$isConnected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.connectionChanged($0) }
            .store(in: &cancellables)
        vialGUI.$isRunning
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                guard let self, running != self.vialGUIRunning else { return }
                self.vialGUIRunning = running
                self.updatePush()
            }
            .store(in: &cancellables)
        settings.$ghostHighlightPressed
            .removeDuplicates()
            .sink { [weak self] on in
                guard let self else { return }
                self.highlightPressed = on
                self.syncPressed()
            }
            .store(in: &cancellables)
    }

    /// Ends the subscription right away; call when the app quits (it would lapse anyway).
    func shutdown() {
        renewTimer?.invalidate()
        renewTimer = nil
        if connected, mayBeSubscribed { link.unsubscribeEventsNow() }
        endPush(unsubscribe: false)
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
        updatePush()
        scheduleTimer()
    }

    /// Called by the ghost when it appears / disappears; it needs the layer state as fast as the overlay does.
    func setGhostVisible(_ visible: Bool) {
        guard visible != ghostVisible else { return }
        ghostVisible = visible
        if visible, connected { pollState() }
        syncPressed()
        updatePush()
        scheduleTimer()
    }

    /// Called by the ghost: whether its visibility goes by the key presses (`pressed.presses`).
    func setGhostWantsPresses(_ wanted: Bool) {
        guard wanted != ghostWantsPresses else { return }
        ghostWantsPresses = wanted
        syncPressed()
    }

    /// The keyboard is telling which keys go down right now, so `pressed.presses` fires for
    /// every key of this keyboard (and for no other keyboard's).
    var reportsPresses: Bool { connected && pushActive && tracksMatrix }

    /// After anything `tracksMatrix` / `usesMatrix` depend on changed.
    private func syncPressed() {
        if !tracksMatrix { pressed.clear() } else if !usesMatrix { pressed.unlight() }
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
        otherClientTimer?.invalidate()
        otherClientTimer = nil
        if otherClientTalking { otherClientTalking = false }
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
        // A keyboard that has just appeared holds no subscription; one that left needs no goodbye.
        pushSupported = true
        pushUnhandledStreak = 0
        renewTimer?.invalidate()
        renewTimer = nil
        endPush(unsubscribe: false)
        if state != nil { state = nil }
        if tapHold != nil { tapHold = nil }
        if !misfires.isEmpty { misfires = [] }
        if let model, !model.chordalExempt.isEmpty { model.chordalExempt = [] }
        if isConnected {
            refreshTapHold()
            refreshMisfires()
            pollState()
        }
        updatePush()
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
        // While the keyboard pushes its state the poll is only a safety net (and still how a
        // keyboard that silently dropped the subscription is caught up with).
        let interval: TimeInterval = !connected || !stateSupported || otherClientTalking ? 0 : (wantsFastState && !pushActive ? Self.fastInterval : Self.slowInterval)
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

    // MARK: - 0xF7 push

    private var wantsFastState: Bool { overlayVisible || ghostVisible }

    /// Unsolicited reports can be taken for a reply by the Vial GUI, which pairs replies with
    /// requests by order only: no subscription while it runs.
    private var wantsPush: Bool { connected && pushSupported && wantsFastState && !vialGUIRunning && !otherClientTalking }

    /// How long after the last report of another program's conversation this app stays silent.
    static var otherClientQuiet: TimeInterval = 120
    /// Another program is talking to the keyboard over the shared interface (seen by the replies
    /// to requests that are not ours). vial.rocks takes whatever report comes next for the reply
    /// to its request, so neither events nor the replies to this app's polls may reach it: no
    /// subscription and no polling until it has been quiet for `otherClientQuiet`. The state
    /// shown meanwhile is the last one known.
    @Published private(set) var otherClientTalking = false
    private var otherClientTimer: Timer?

    private func foreignReportSeen() {
        guard connected else { return }
        otherClientTimer?.invalidate()
        let t = Timer(timeInterval: Self.otherClientQuiet, repeats: false) { [weak self] _ in self?.setOtherClientTalking(false) }
        RunLoop.main.add(t, forMode: .common)
        otherClientTimer = t
        setOtherClientTalking(true)
    }

    private func setOtherClientTalking(_ talking: Bool) {
        if !talking { otherClientTimer?.invalidate(); otherClientTimer = nil }
        guard talking != otherClientTalking else { return }
        otherClientTalking = talking
        updatePush()
        scheduleTimer()
    }

    /// Matrix events say which keys are down. They are looked at only for the ghost: for its
    /// highlight while that setting is on (`usesMatrix`) and, in "While typing", to notice that a
    /// key of this keyboard went down. The keyboard sends them to every subscriber regardless.
    var usesMatrix: Bool { matrixOverride ?? (highlightPressed && ghostVisible) }
    var tracksMatrix: Bool { matrixOverride ?? (ghostVisible && (highlightPressed || ghostWantsPresses)) }

    /// One line for `--live-probe`.
    var pushStatus: String {
        if !connected { return "not connected" }
        if !pushSupported { return "not supported by this firmware (0xF7 unhandled), polling" }
        if otherClientTalking { return "paused, with the polling: another program is talking to the keyboard" }
        if vialGUIRunning { return "off while the Vial GUI is running, polling" }
        if !wantsFastState { return "not needed (nothing on screen)" }
        return pushActive ? "in use (ttl \(pushTTL) s, renewed every \(String(format: "%.1f", TimeInterval(pushTTL) / 3)) s)" : "not established, polling"
    }

    /// Starts, keeps or ends the subscription after anything `wantsPush` depends on changed.
    private func updatePush() {
        if wantsPush {
            guard renewTimer == nil else { return }
            let interval = TimeInterval(pushTTL) / 3
            let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.subscribe() }
            t.tolerance = interval * 0.1
            RunLoop.main.add(t, forMode: .common)
            renewTimer = t
            subscribe()
        } else {
            renewTimer?.invalidate()
            renewTimer = nil
            endPush(unsubscribe: connected)
        }
    }

    /// The first request and every renewal. The keyboard follows each with one state and one
    /// matrix event, so whatever was missed is caught up with here.
    private func subscribe() {
        checkLapse()
        guard wantsPush, !subscribeInFlight else { return }
        subscribeInFlight = true
        mayBeSubscribed = true
        count(KeyboardLink.LiveCommand.events)
        let generation = pushGeneration
        link.subscribeEvents(ttl: pushTTL) { [weak self] result in
            guard let self, generation == self.pushGeneration else { return }
            self.subscribeInFlight = false
            switch result {
            case .ok:
                self.pushUnhandledStreak = 0
                self.lastSubscribed = Date()
                if !self.pushActive {
                    self.pushActive = true
                    self.scheduleTimer()
                }
            case .unsupported:
                // As with 0xF4: believed the second time in a row (the timer asks again).
                self.pushUnhandledStreak += 1
                if self.pushUnhandledStreak >= 2 {
                    self.pushSupported = false
                    self.mayBeSubscribed = false
                    self.updatePush()
                }
            case .failed:
                self.checkLapse()
            }
        }
    }

    /// No renewal got through for a whole ttl: the keyboard has stopped sending, back to polling
    /// (the renew timer keeps trying).
    private func checkLapse() {
        guard pushActive, Date().timeIntervalSince(lastSubscribed) > TimeInterval(pushTTL) else { return }
        pushActive = false
        pressed.clear()
        scheduleTimer()
        pollState()
    }

    private func endPush(unsubscribe: Bool) {
        pushGeneration += 1
        subscribeInFlight = false
        if unsubscribe, mayBeSubscribed {
            count(KeyboardLink.LiveCommand.events)
            link.subscribeEvents(ttl: 0) { _ in }
        }
        mayBeSubscribed = false
        pressed.clear()
        if pushActive {
            pushActive = false
            scheduleTimer()
            pollState()
        }
    }

    /// An unsolicited 0xF7 report (see `HIDTransport.onEvent`).
    private func received(event report: [UInt8]) {
        guard connected else { return }
        eventCounts[Int(report[1]), default: 0] += 1
        if report[1] == 2 {
            // Not even parsed unless the ghost wants it.
            guard pushActive, tracksMatrix, case .matrix(let m)? = LiveEvent.parse(report) else { return }
            pressed.set(m.pressed, light: usesMatrix)
        } else if case .state(let s)? = LiveEvent.parse(report) {
            apply(state: s)
        }
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
    func inject(matrix: MatrixEvent) {
        matrixOverride = true
        pressed.set(matrix.pressed)
    }
}

/// The keys shown as pressed. `lit` is what is drawn: the keys that are down, each for at
/// least `minLit` so that the shortest tap still gets a frame (the view fades it out after).
/// With `light: false` only `down` and `presses` are kept up (nothing is drawn).
final class PressedKeys: ObservableObject {
    static let minLit: TimeInterval = 0.08

    @Published private(set) var lit: Set<Int> = []
    /// `KeyPlacement.id`s of the keys physically down.
    private(set) var down: Set<Int> = []
    /// Fires when a key goes down (activity, for the ghost's visibility).
    let presses = PassthroughSubject<Void, Never>()
    private var pressedAt: [Int: Date] = [:]

    func set(_ keys: Set<Int>, light: Bool = true) {
        guard keys != down else { return }
        let now = Date()
        let pressed = keys.subtracting(down), released = down.subtracting(keys)
        down = keys
        guard light else {
            unlight()
            if !pressed.isEmpty { presses.send() }
            return
        }
        var next = lit
        for k in pressed {
            pressedAt[k] = now
            next.insert(k)
        }
        for k in released {
            guard let since = pressedAt[k] else { next.remove(k); continue }
            let wait = Self.minLit - now.timeIntervalSince(since)
            if wait <= 0 {
                next.remove(k)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.expire(k, pressedAt: since) }
            }
        }
        if next != lit { lit = next }
        if !pressed.isEmpty { presses.send() }
    }

    func clear() {
        down = []
        unlight()
    }

    /// Nothing drawn any more; what is down stays known.
    func unlight() {
        pressedAt = [:]
        if !lit.isEmpty { lit = [] }
    }

    private func expire(_ key: Int, pressedAt since: Date) {
        // Pressed again in the meantime: that press has its own timing.
        guard !down.contains(key), pressedAt[key] == since, lit.contains(key) else { return }
        lit.remove(key)
    }
}

/// Whether the Vial desktop app is running. It shares the raw HID interface and pairs replies
/// with its requests by order only, so the keyboard must not send anything unasked while it may
/// be talking: `LiveKeyboard` holds no 0xF7 subscription meanwhile.
///
/// Not seen: Vial run from source (the process is "python") and the web version in a browser.
final class VialGUIWatcher: ObservableObject {
    static let shared = VialGUIWatcher()

    @Published private(set) var isRunning = false

    private var observers: [NSObjectProtocol] = []

    /// `observing: false` gives a watcher that only changes through `set` (self-tests).
    init(observing: Bool = true) {
        guard observing else { return }
        let ws = NSWorkspace.shared
        // "Will launch" too: Vial talks to the keyboard as soon as it is up.
        for name in [NSWorkspace.willLaunchApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.changed(note, terminated: name == NSWorkspace.didTerminateApplicationNotification)
            })
        }
        refresh()
    }

    deinit { observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }

    func set(_ running: Bool) {
        if running != isRunning { isRunning = running }
    }

    /// The bundle identifier of the official build (vial-gui, `mac_bundle_identifier`) and of
    /// anything else that calls itself Vial: a word starting with "vial" in the bundle id or
    /// the name, this app excepted. A false match only costs the push (the app polls instead).
    static func isVialGUI(bundleID: String?, name: String?) -> Bool {
        let texts = [bundleID, name].compactMap { $0?.lowercased() }
        if texts.contains(where: { $0.filter { $0.isLetter || $0.isNumber }.contains("vialhelper") }) { return false }
        if bundleID?.lowercased() == "today.vial" { return true }
        return texts.contains { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix("vial") } }
    }

    private static func isVialGUI(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && isVialGUI(bundleID: app.bundleIdentifier, name: app.localizedName ?? app.executableURL?.lastPathComponent)
    }

    private func changed(_ note: Notification, terminated: Bool) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if terminated {
            refresh(without: app)
        } else if let app, Self.isVialGUI(app) {
            set(true)
            // It may not be in the list of running applications yet, or never get there.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.refresh() }
        }
    }

    private func refresh(without gone: NSRunningApplication? = nil) {
        set(NSWorkspace.shared.runningApplications.contains { $0 != gone && !$0.isTerminated && Self.isVialGUI($0) })
    }
}
