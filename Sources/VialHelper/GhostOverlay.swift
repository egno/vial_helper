import AppKit
import SwiftUI
import Combine

// Ghost mode: the see-through keys of the layer that is active on the keyboard right now, kept on
// the screen being worked on while a new layout is learned. It is a window that cannot become
// key and ignores the mouse, so typing and clicking go to whatever is underneath.

/// What the ghost draws: one layer, and the active layers its transparent keys fall through to.
struct GhostLayer: Equatable {
    var layer: Int
    /// Active layers below `layer`, highest first.
    var below: [Int]

    /// The highest active layer when the keyboard reports its state (0xF4), else the base layer.
    static func current(layerCount: Int, state: LiveState?) -> GhostLayer {
        guard let state, state.highestLayer > 0, state.highestLayer < layerCount else {
            return GhostLayer(layer: 0, below: [])
        }
        let lower = (0..<state.highestLayer).reversed().filter { state.isActive($0) }
        return GhostLayer(layer: state.highestLayer, below: lower)
    }
}

struct GhostView: View {
    @ObservedObject var model: KeymapModel
    @ObservedObject var settings: AppSettings
    @ObservedObject private var layoutObserver = KeyboardLayoutObserver.shared
    @ObservedObject var live = LiveKeyboard.shared
    /// Opaque background for off-screen rendering (materials do not render there).
    var plainBackground = false

    /// Debug (`--ghost-opacity`): plate opacity for a render, leaving the stored setting alone.
    static var plateOpacityOverride: Double?

    /// Labels as the keyboard would type them now: shifted while Shift, a one-shot Shift or
    /// Caps Word is on.
    private var context: LabelContext {
        var c = LabelContext.current(model: model, settings: settings, keyOverrides: layoutObserver.overrides)
        c.shiftedKeyOverrides = layoutObserver.shiftedOverrides
        c.shift = ShiftLegends.current(live.state)
        return c
    }

    /// `ghostOpacity` is the opacity of the plates only; the window's own alpha is left to the
    /// controller for fading the whole ghost in and out.
    private var style: CanvasStyle {
        CanvasStyle(plateOpacity: Self.plateOpacityOverride ?? settings.ghostOpacity,
                    simplified: settings.ghostSimplifiedLabels, hideInherited: settings.ghostHideInherited)
    }

    var body: some View {
        let unit = CGFloat(settings.ghostSize)
        return Group {
            if let file = model.file, let geometry = model.geometry {
                let shown = GhostLayer.current(layerCount: file.layers.count, state: live.state)
                VStack(alignment: .leading, spacing: unit * 0.12) {
                    badge(layer: shown.layer, unit: unit)
                    KeyboardCanvas(file: file, geometry: geometry, layer: shown.layer, unit: unit,
                                   encoderMode: settings.encoderMode, context: context, below: shown.below, style: style,
                                   pressed: live.matrixOverride ?? settings.ghostHighlightPressed ? live.pressed : nil)
                }
            } else {
                Label(model.error ?? "Keymap not loaded", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(6)
                    .background(Capsule().fill(Color.black.opacity(style.plateOpacity ?? 0)))
            }
        }
        .padding(plainBackground ? 12 : 3)
        .background(backdrop)
        .fixedSize()
        // The plates are dark whatever the system appearance is, so the legends are always light.
        .environment(\.colorScheme, .dark)
    }

    /// The shown layer's name and, beside it, what else the keyboard reports: held and one-shot
    /// modifiers, Caps Word / Caps Lock, locked layers. Always there, so the ghost keeps its height.
    private func badge(layer: Int, unit: CGFloat) -> some View {
        let size = max(10, unit * 0.3)
        return HStack(spacing: 4) {
            LayerTitle(layer: layer, name: settings.layerName(layer), unit: unit * 0.9)
                .legendHalo(true, unit: unit)
                .padding(.horizontal, size * 0.67)
                .padding(.vertical, size * 0.19)
                .background(Capsule().fill(Color.black.opacity(style.plateOpacity ?? 0)))
            if let s = live.state {
                LiveIndicators(state: s, context: context, detailed: true, fontSize: size, plateOpacity: style.plateOpacity)
            }
        }
        .fixedSize()
    }

    /// Off-screen renders get a backdrop running from light to dark, to judge the legends over both.
    @ViewBuilder
    private var backdrop: some View {
        if plainBackground {
            LinearGradient(colors: [Color(white: 0.95), Color(white: 0.12)], startPoint: .leading, endPoint: .trailing)
        } else {
            Color.clear
        }
    }
}

/// Never key, never main: showing it leaves the keyboard focus where it was. The one exception
/// is while it is being placed by hand (`GhostController.beginMove`), when it takes the keys so
/// that Return and Esc end the move and a click elsewhere (resign key) does too.
final class GhostPanel: NSPanel {
    var acceptsKeys = false
    var onKeyDown: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { acceptsKeys }
    override var canBecomeMain: Bool { false }

    /// Before normal dispatch, as in KeymapPanel: the hosting view would consume some keys.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, acceptsKeys, let onKeyDown { onKeyDown(event); return }
        super.sendEvent(event)
    }
}

/// Everything that decides how visible the ghost is while ghost mode is on. The panel's alpha is
/// `alpha` and nothing else: 1 when fully shown (how see-through the keys are is the view's business).
struct GhostPresence: Equatable {
    /// Alpha left while the pointer is over the ghost.
    static let pointerAlpha: CGFloat = 0.1

    var mode: GhostVisibility = .always
    /// The highest active layer is the base layer; nil without the 0xF4 live state.
    var onBase: Bool?
    /// Nothing has happened for `AppSettings.ghostHideDelay`: no layer change and, as far as key
    /// presses are known (always in `whileTyping`, else with "Highlight pressed keys"), no key
    /// pressed or held.
    var baseIdle = false
    /// The pointer is inside the ghost's frame (false when that setting is off).
    var pointerInside = false
    /// The full overlay, which shows the same keymap, is open.
    var overlayOpen = false
    /// The ghost is being placed by hand.
    var moving = false

    var alpha: CGFloat {
        if moving { return 1 }
        if overlayOpen { return 0 }
        // Without the live state the layer is unknown, so the layer modes behave as `always`.
        if onBase == true, mode == .nonBase { return 0 }
        if canIdle, baseIdle { return 0 }
        return pointerInside ? Self.pointerAlpha : 1
    }

    /// Whether the ghost may fade out for lack of activity right now. A held layer keeps it:
    /// that is when it is being read. `whileTyping` works on key presses, so also without the state.
    var canIdle: Bool {
        switch mode {
        case .always, .nonBase: return false
        case .fadeOnBase: return onBase == true
        case .whileTyping: return onBase != false
        }
    }

    /// Whether nothing above the default layer is active; nil when the keyboard does not say.
    static func onBase(_ state: LiveState?) -> Bool? {
        guard let state else { return nil }
        let base = state.defaultLayerState == 0 ? 0 : 31 - state.defaultLayerState.leadingZeroBitCount
        return state.highestLayer <= base
    }
}

/// A hand-picked place of the ghost, kept as the fraction of the free room in a screen's visible
/// frame ([x, y], 0 = left / bottom, 1 = right / top): independent of the resolution and of the
/// ghost's size, and always on the screen.
enum GhostPlacement {
    static func origin(fraction: [Double], size: CGSize, in visible: NSRect) -> NSPoint {
        func unit(_ i: Int) -> CGFloat { i < fraction.count && fraction[i].isFinite ? CGFloat(min(max(fraction[i], 0), 1)) : 0.5 }
        return NSPoint(x: visible.minX + max(visible.width - size.width, 0) * unit(0),
                       y: visible.minY + max(visible.height - size.height, 0) * unit(1))
    }

    /// The fraction for a frame, clamped: a frame dragged off the screen lands on its edge.
    static func fraction(of frame: NSRect, in visible: NSRect) -> [Double] {
        func unit(_ offset: CGFloat, _ room: CGFloat) -> Double { room > 0 ? Double(min(max(offset / room, 0), 1)) : 0.5 }
        return [unit(frame.minX - visible.minX, visible.width - frame.width),
                unit(frame.minY - visible.minY, visible.height - frame.height)]
    }

    /// Stable name of a display (its UUID), so a place is remembered per screen across restarts.
    static func screenKey(_ screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return screen.localizedName
    }
}

/// Drawn over the ghost while it is being placed by hand: says what to do and takes the drag.
private final class GhostMoveHintView: NSView {
    var onDone: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let button = NSButton(title: "Done", target: self, action: #selector(done))
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func done() { onDone?() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override func draw(_ dirtyRect: NSRect) {
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.6).setFill()
        frame.fill()
        NSColor.controlAccentColor.setStroke()
        frame.lineWidth = 2
        frame.setLineDash([6, 4], count: 2, phase: 0)
        frame.stroke()
        draw("Drag to place the ghost", size: 14, weight: .semibold, centreY: bounds.midY + 22)
        draw("Return or a click elsewhere keeps the place, Esc cancels", size: 11, weight: .regular, centreY: bounds.midY - 30)
    }

    private func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, centreY: CGFloat) {
        let line = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.white,
        ])
        let s = line.size()
        line.draw(at: NSPoint(x: bounds.midX - s.width / 2, y: centreY - s.height / 2))
    }
}

/// Owns the ghost window. Shown and hidden by `AppSettings.ghostMode` (see AppDelegate); while it
/// is shown, how visible it is comes from `GhostPresence`.
final class GhostController {
    /// Posted by the Settings window's "Move Ghost…" button (see AppDelegate).
    static let moveRequested = Notification.Name("VialHelperGhostMoveRequested")

    private static let margin: CGFloat = 24
    private static let fadeDuration: TimeInterval = 0.15
    /// The fade after `AppSettings.ghostHideDelay`: slow, it is not a reaction to anything.
    private static let idleFadeDuration: TimeInterval = 0.6

    private let model: KeymapModel
    private let settings: AppSettings
    private var panel: GhostPanel!
    private var hosting: NSHostingView<GhostView>!
    private var moveHint: GhostMoveHintView!
    private var cancellables = Set<AnyCancellable>()
    private var screenTimer: Timer?
    private var refitPending = false

    /// The conditions the panel's alpha was last computed from; changed only through `update`.
    private(set) var presence = GhostPresence()
    /// The alpha the panel is at or animating to.
    private(set) var targetAlpha: CGFloat = 1
    private var baseIdleTimer: Timer?
    private var pointerTimer: Timer?
    private var lastHideDelay: Double
    /// Highest layer and active mask of the last live state, to tell a layer change from other news.
    private var lastLayers: [UInt32]?
    private var lastPosition: GhostPosition
    private var moveStartFrame: NSRect?
    private var moveResignObserver: NSObjectProtocol?

    init(model: KeymapModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        lastPosition = settings.ghostPosition
        lastHideDelay = settings.ghostHideDelay
        buildPanel()
        settingsChanged()

        // Anything that can change the size or the place of the ghost. The publishers fire
        // before the change, so the refit runs on the next turn of the run loop.
        let triggers: [AnyPublisher<Void, Never>] = [
            model.objectWillChange.eraseToAnyPublisher(),
            LiveKeyboard.shared.objectWillChange.eraseToAnyPublisher(),
            settings.objectWillChange.eraseToAnyPublisher(),
            KeyboardLayoutObserver.shared.objectWillChange.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).map { _ in }.eraseToAnyPublisher(),
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification).map { _ in }.eraseToAnyPublisher(),
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification).map { _ in }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.scheduleRefit() }
            .store(in: &cancellables)

        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.settingsChanged() }
            .store(in: &cancellables)

        // The keyboard's layers, for the layer-dependent visibility modes (see "Keyboard state").
        LiveKeyboard.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.liveStateChanged($0) }
            .store(in: &cancellables)
        // Fires in `whileTyping` and with "Highlight pressed keys" on (the app does not look at
        // the keys otherwise).
        LiveKeyboard.shared.pressed.presses
            .sink { [weak self] in self?.keyPressed() }
            .store(in: &cancellables)
    }

    /// Ghost mode is on: the panel is in the window list, though it may be faded out (`targetAlpha`).
    var isActive: Bool { panel.isVisible }
    /// On and not faded out completely.
    var isVisible: Bool { panel.isVisible && targetAlpha > 0 }
    var isMoving: Bool { presence.moving }
    var panelAlpha: CGFloat { panel.alphaValue }
    var sharingType: NSWindow.SharingType { panel.sharingType }
    var canTakeFocus: Bool { panel.canBecomeKey || panel.canBecomeMain }
    var ignoresMouse: Bool { panel.ignoresMouseEvents }
    var isOnScreen: Bool { NSScreen.screens.contains { $0.frame.contains(panel.frame) } }

    func show() {
        guard !panel.isVisible else { return }
        // Also has the keyboard's keymap re-read, like opening the overlay does.
        model.reloadIfNeeded(path: settings.expandedPath)
        fit()
        // Appears as it should be right now, without a fade from whatever it was when hidden.
        presence.mode = settings.ghostVisibility
        presence.onBase = GhostPresence.onBase(LiveKeyboard.shared.state)
        presence.baseIdle = false
        presence.pointerInside = settings.ghostAvoidPointer && panel.frame.contains(NSEvent.mouseLocation)
        targetAlpha = presence.alpha
        panel.alphaValue = targetAlpha
        panel.orderFrontRegardless()
        // Fast state (pushed or polled) for as long as ghost mode is on, also while the panel is
        // faded out: a layer change is what brings it back.
        LiveKeyboard.shared.setGhostVisible(true)
        armBaseIdle()
        syncPointerTimer()
        syncWantsPresses()
        // A window of the same app getting the focus on another display posts nothing to observe.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.followScreen() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        screenTimer = t
    }

    func hide() {
        guard panel.isVisible else { return }
        endMove(keep: false)
        screenTimer?.invalidate()
        screenTimer = nil
        panel.orderOut(nil)
        LiveKeyboard.shared.setGhostVisible(false)
        armBaseIdle()
        syncPointerTimer()
        syncWantsPresses()
    }

    /// The full overlay shows the same keymap: the ghost steps aside while it is open.
    func setOverlayOpen(_ open: Bool) {
        update { $0.overlayOpen = open }
    }

    // MARK: - Placing by hand

    /// Lets the ghost be dragged: for the time being it takes the mouse and the keys. Ends with
    /// `endMove` (the Done button, Return, Esc, or the panel losing the keys to a click elsewhere).
    func beginMove() {
        guard panel.isVisible, !presence.moving else { return }
        moveStartFrame = panel.frame
        update { $0.moving = true }
        moveHint.isHidden = false
        panel.ignoresMouseEvents = false
        panel.acceptsKeys = true
        panel.makeKey()
        moveResignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.endMove(keep: true)
        }
    }

    /// Back to click-through and never key. `keep` stores where the panel is as the place for the
    /// screen it is on; otherwise it returns to where it was.
    func endMove(keep: Bool) {
        guard presence.moving else { return }
        if let o = moveResignObserver { NotificationCenter.default.removeObserver(o) }
        moveResignObserver = nil
        if keep, let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first {
            settings.ghostCustomPlaces[GhostPlacement.screenKey(screen)] = GhostPlacement.fraction(of: panel.frame, in: screen.visibleFrame)
        } else if let frame = moveStartFrame {
            panel.setFrame(frame, display: true)
        }
        moveStartFrame = nil
        moveHint.isHidden = true
        panel.ignoresMouseEvents = true
        let wasKey = panel.isKeyWindow
        panel.acceptsKeys = false
        // A key window that can no longer be key still holds the keys; taking it out of the
        // window list and back hands them to the window that had them.
        if wasKey {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        update { $0.moving = false }
        fit()
    }

    /// Debug helper (`--selftest`): what a drag does to the panel while it is being moved.
    func simulateDrag(to origin: NSPoint) {
        if presence.moving { panel.setFrameOrigin(origin) }
    }

    // MARK: - Visibility

    /// The one place the panel's alpha is set: changes the conditions and animates to their alpha.
    private func update(duration: TimeInterval = GhostController.fadeDuration, _ change: (inout GhostPresence) -> Void) {
        change(&presence)
        let alpha = presence.alpha
        guard alpha != targetAlpha else { return }
        targetAlpha = alpha
        guard panel.isVisible else { panel.alphaValue = alpha; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            panel.animator().alphaValue = alpha
        }
    }

    /// (Re)starts the wait after which the ghost fades out for lack of activity (`canIdle`).
    private func armBaseIdle() {
        baseIdleTimer?.invalidate()
        baseIdleTimer = nil
        guard panel.isVisible, presence.canIdle, !presence.baseIdle else { return }
        let t = Timer(timeInterval: settings.ghostHideDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            // A key of the keyboard is still held (a Shift, a key that repeats): not idle yet.
            if LiveKeyboard.shared.reportsPresses, !LiveKeyboard.shared.pressed.down.isEmpty { return self.armBaseIdle() }
            self.update(duration: GhostController.idleFadeDuration) { $0.baseIdle = true }
        }
        RunLoop.main.add(t, forMode: .common)
        baseIdleTimer = t
    }

    /// The panel ignores the mouse, so it gets no mouse events of its own; the pointer is looked
    /// up instead (needs no permission), and only while the ghost is on and the setting asks for it.
    private func syncPointerTimer() {
        let wanted = panel.isVisible && settings.ghostAvoidPointer
        if wanted, pointerTimer == nil {
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.update { $0.pointerInside = self.panel.frame.contains(NSEvent.mouseLocation) }
            }
            t.tolerance = 0.03
            RunLoop.main.add(t, forMode: .common)
            pointerTimer = t
        } else if !wanted {
            pointerTimer?.invalidate()
            pointerTimer = nil
            update { $0.pointerInside = false }
        }
    }

    /// `GhostVisibility.whileTyping` needs every key press, also of keys the keyboard's state says
    /// nothing about. The keyboard reports them itself (0xF7 matrix events, `pressed.presses`),
    /// so only its keys count: typing on another keyboard does not bring the ghost up. While it
    /// does not report them (firmware without 0xF7, no subscription because Vial is talking to
    /// the keyboard) only a layer change does.
    private func syncWantsPresses() {
        LiveKeyboard.shared.setGhostWantsPresses(panel.isVisible && settings.ghostVisibility == .whileTyping)
    }

    /// Runs after any setting changed (and once at start).
    private func settingsChanged() {
        let sharing: NSWindow.SharingType = settings.ghostHideFromSharing ? .none : .readOnly
        if panel.sharingType != sharing { panel.sharingType = sharing }
        if settings.ghostVisibility != presence.mode {
            update { $0.mode = self.settings.ghostVisibility; $0.baseIdle = false }
            armBaseIdle()
        }
        if settings.ghostHideDelay != lastHideDelay {
            lastHideDelay = settings.ghostHideDelay
            armBaseIdle()
        }
        syncPointerTimer()
        syncWantsPresses()
        // Picking a corner is asking for the corner: the hand-picked place of this screen goes.
        if settings.ghostPosition != lastPosition {
            lastPosition = settings.ghostPosition
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let key = GhostPlacement.screenKey(screen)
                if settings.ghostCustomPlaces[key] != nil { settings.ghostCustomPlaces[key] = nil }
            }
        }
    }

    // MARK: - Keyboard state
    // All the ghost's window logic wants from LiveKeyboard: the 0xF4 state as it changes (the
    // `$state` subscription in init), fast state while ghost mode is on (`setGhostVisible` in
    // show / hide) and, where the pressed keys are known, every key press (`keyPressed`).

    private func liveStateChanged(_ state: LiveState?) {
        let layers = state.map { [UInt32($0.highestLayer), $0.activeMask] }
        guard layers != lastLayers else { return }
        lastLayers = layers
        // Any layer change shows the ghost again at once, also one that ends on the base layer.
        update { $0.onBase = GhostPresence.onBase(state); $0.baseIdle = false }
        armBaseIdle()
    }

    /// Typing is activity: the wait starts over with every key, so the ghost (and the highlight
    /// on it) stays while the keyboard is in use, and in `whileTyping` a key brings it back.
    private func keyPressed() {
        guard presence.canIdle else { return }
        update { $0.baseIdle = false }
        armBaseIdle()
    }

    // MARK: - Private

    private func buildPanel() {
        hosting = NSHostingView(rootView: GhostView(model: model, settings: settings))
        // The view of the keys and, over it while the ghost is being placed, the hint.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        hosting.frame = content.bounds
        hosting.autoresizingMask = [.width, .height]
        content.addSubview(hosting)
        moveHint = GhostMoveHintView(frame: content.bounds)
        moveHint.autoresizingMask = [.width, .height]
        moveHint.isHidden = true
        moveHint.onDone = { [weak self] in self?.endMove(keep: true) }
        content.addSubview(moveHint)

        panel = GhostPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // No backdrop: only the keys are drawn, each on its own dark plate, so the legends are
        // light whatever the system appearance is.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = content
        panel.onKeyDown = { [weak self] event in
            switch event.keyCode {
            case 53: self?.endMove(keep: false)        // esc
            case 36, 76: self?.endMove(keep: true)     // return, enter
            default: break
            }
        }
    }

    private func scheduleRefit() {
        guard panel.isVisible, !refitPending else { return }
        refitPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refitPending = false
            if self.panel.isVisible { self.fit() }
        }
    }

    private func followScreen() {
        if let screen = NSScreen.main, panel.screen != screen { fit() }
    }

    /// Sizes the panel to its content and puts it at the hand-picked place of the active screen,
    /// or at the configured edge when there is none. Not while it is being dragged.
    private func fit() {
        guard !presence.moving else { return }
        hosting.layoutSubtreeIfNeeded()
        // The screen with the keyboard focus, which is where the typing is looked at.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame.insetBy(dx: Self.margin, dy: Self.margin)
        var size = hosting.fittingSize
        size.width = min(size.width, visible.width)
        size.height = min(size.height, visible.height)
        let position = settings.ghostPosition
        var origin = NSPoint(
            x: visible.minX + (visible.width - size.width) * position.horizontal,
            y: position.isTop ? visible.maxY - size.height : visible.minY
        )
        if let place = settings.ghostCustomPlaces[GhostPlacement.screenKey(screen)] {
            origin = GhostPlacement.origin(fraction: place, size: size, in: screen.visibleFrame)
        }
        let frame = NSRect(origin: origin, size: size)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }
}

/// `--selftest`: the decisions of the ghost's window that need no window and no keyboard.
enum GhostWindowSelfTest {
    static func run(_ check: (String, Bool) -> Void) {
        /// A 0xF4 reply with the given highest layer and layer masks.
        func state(highest: UInt8, layers: UInt8, base: UInt8 = 1) -> LiveState? {
            var b = [UInt8](repeating: 0, count: 32)
            b[0] = 0xF4; b[3] = highest; b[4] = layers; b[8] = base; b[22] = 0xFF
            return LiveState.parse(b)
        }
        let base = state(highest: 0, layers: 0), nav = state(highest: 2, layers: 0b100)
        check("ghost base layer: known only with the live state",
              GhostPresence.onBase(nil) == nil && GhostPresence.onBase(base) == true && GhostPresence.onBase(nav) == false)
        check("ghost base layer follows the default layer",
              GhostPresence.onBase(state(highest: 1, layers: 0, base: 0b10)) == true && GhostPresence.onBase(state(highest: 2, layers: 0b100, base: 0b10)) == false)

        func alpha(_ mode: GhostVisibility, _ s: LiveState?, known: Bool = true, idle: Bool = false, pointer: Bool = false,
                   overlay: Bool = false, moving: Bool = false) -> CGFloat {
            GhostPresence(mode: mode, onBase: known ? GhostPresence.onBase(s) : nil, baseIdle: idle, pointerInside: pointer,
                          overlayOpen: overlay, moving: moving).alpha
        }
        check("ghost always: shown on every layer", alpha(.always, base) == 1 && alpha(.always, nav) == 1 && alpha(.always, base, idle: true) == 1)
        check("ghost only on other layers: hidden on base, shown above", alpha(.nonBase, base) == 0 && alpha(.nonBase, nav) == 1)
        check("ghost while typing: hidden when idle, a held layer keeps it, works without the state",
              alpha(.whileTyping, base) == 1 && alpha(.whileTyping, base, idle: true) == 0 && alpha(.whileTyping, nav, idle: true) == 1 &&
              alpha(.whileTyping, nil, known: false, idle: true) == 0)
        // "While typing" without the highlight: presses are noticed, nothing is lit.
        let keys = PressedKeys()
        var presses = 0
        let counting = keys.presses.sink { presses += 1 }
        keys.set([3], light: false)
        keys.set([3], light: false) // a renewal repeats the matrix: not a press
        keys.set([3, 7], light: false)
        keys.set([7], light: false) // a release
        counting.cancel()
        check("ghost while typing: the keyboard's presses count once each, unlit", presses == 2 && keys.down == [7] && keys.lit.isEmpty)
        check("ghost fades on base: only after the wait", alpha(.fadeOnBase, base) == 1 && alpha(.fadeOnBase, base, idle: true) == 0 && alpha(.fadeOnBase, nav, idle: true) == 1)
        check("ghost layer modes without live state: as always",
              alpha(.nonBase, nil, known: false) == 1 && alpha(.fadeOnBase, nil, known: false, idle: true) == 1)
        check("ghost under the pointer: nearly gone", alpha(.always, nav, pointer: true) == GhostPresence.pointerAlpha && alpha(.nonBase, base, pointer: true) == 0)
        check("ghost hidden while the overlay is open", alpha(.always, nav, overlay: true) == 0 && alpha(.always, nav, pointer: true, overlay: true) == 0)
        check("ghost fully shown while being moved", alpha(.nonBase, base, pointer: true, overlay: true, moving: true) == 1)

        let visible = NSRect(x: 100, y: 50, width: 1000, height: 600), size = CGSize(width: 400, height: 100)
        func placed(_ frame: NSRect) -> NSRect {
            NSRect(origin: GhostPlacement.origin(fraction: GhostPlacement.fraction(of: frame, in: visible), size: size, in: visible), size: size)
        }
        let inside = NSRect(x: 250, y: 300, width: 400, height: 100)
        check("ghost place round-trips", placed(inside) == inside && GhostPlacement.fraction(of: inside, in: visible) == [0.25, 0.5])
        check("ghost place is clamped to the screen",
              visible.contains(placed(NSRect(x: -5000, y: 9000, width: 400, height: 100)))
                && visible.contains(NSRect(origin: GhostPlacement.origin(fraction: [7, -.infinity], size: size, in: visible), size: size)))
        // The same fraction on a screen of another size (resolution change) is still on it.
        let other = NSRect(x: 0, y: 0, width: 640, height: 360)
        check("ghost place survives a resolution change",
              other.contains(NSRect(origin: GhostPlacement.origin(fraction: [1, 1], size: size, in: other), size: size))
                && other.contains(NSRect(origin: GhostPlacement.origin(fraction: [0.3, 0.3], size: CGSize(width: 900, height: 100), in: other), size: CGSize(width: 640, height: 100))))
    }
}
