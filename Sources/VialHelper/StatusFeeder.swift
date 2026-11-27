import Foundation
import Combine

/// Keeps the keyboard's right OLED showing the clock (row 0) and the active input source
/// (row 1) through the firmware's host status text (0xF2).
///
/// The text is resent when the input source changes, on connect and every 30 s of wall-clock
/// time (so the clock turns over on the minute). The keyboard drops it 90 s after the last
/// report, so it disappears by itself if the app dies; quitting or turning the setting off
/// clears it at once.
final class StatusFeeder {
    static let ttl: UInt8 = 90
    static let refreshInterval: TimeInterval = 30

    private let link: KeyboardLink
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var enabled = false
    private var connected = false
    private var inputSource = ""
    /// True while the keyboard may still be showing our text.
    private var shown = false

    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    init(link: KeyboardLink) {
        self.link = link
    }

    func start(settings: AppSettings, layout: KeyboardLayoutObserver) {
        Publishers.CombineLatest3(settings.$oledStatus, link.$isConnected, layout.$inputSourceShortName)
            .sink { [weak self] enabled, connected, source in
                self?.update(enabled: enabled, connected: connected, inputSource: source)
            }
            .store(in: &cancellables)
    }

    /// Clears the text right away; call when the app quits.
    func shutdown() {
        cancellables.removeAll()
        timer?.invalidate()
        timer = nil
        if shown, connected { link.clearStatusNow() }
        shown = false
    }

    var rows: [String] { [clock.string(from: Date()), inputSource, ""] }

    private func update(enabled: Bool, connected: Bool, inputSource: String) {
        self.enabled = enabled
        self.connected = connected
        self.inputSource = inputSource
        if !connected { shown = false }
        if enabled && connected {
            send()
            scheduleTimer()
        } else {
            timer?.invalidate()
            timer = nil
            if shown {
                shown = false
                link.clearStatus()
            }
        }
    }

    private func send() {
        shown = true
        link.sendStatus(rows: rows, ttl: Self.ttl)
    }

    /// One-shot timer to the next multiple of the refresh interval on the wall clock, which
    /// includes every minute boundary; rescheduled after each tick so it survives sleep.
    private func scheduleTimer() {
        timer?.invalidate()
        let now = Date().timeIntervalSince1970
        let step = Self.refreshInterval
        let next = (now / step).rounded(.down) * step + step + 0.05
        let t = Timer(fire: Date(timeIntervalSince1970: next), interval: 0, repeats: false) { [weak self] _ in
            guard let self, self.enabled, self.connected else { return }
            self.send()
            self.scheduleTimer()
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
