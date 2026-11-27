import AppKit
import SwiftUI
import Combine

/// Borderless floating panel that can take key events without activating the app.
final class KeymapPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Intercept before normal dispatch: the SwiftUI hosting view otherwise consumes arrow keys
    /// (focus navigation) and they never reach the window's keyDown.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// Owns the hover window with the keymap.
final class OverlayController {
    private let model: KeymapModel
    private let settings: AppSettings
    private var panel: KeymapPanel!
    private var hosting: NSHostingView<KeymapRootView>!
    private var cancellables = Set<AnyCancellable>()
    /// The scale the keymap is drawn at: 1, or less when it would not fit the screen.
    private(set) var contentScale: CGFloat = 1
    /// Layers side by side in the view of all layers.
    private(set) var contentColumns = 2
    static let columnChoices = 2...4
    /// Room left around the panel on the screen.
    private static let screenMargin: CGFloat = 24

    init(model: KeymapModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        buildPanel()

        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.fitToContent() }
            }
            .store(in: &cancellables)

        // Live keyboard data can add or remove a line (misfire legend, indicators); resize only
        // when the content size really changed, so a layer switch does not re-centre the panel.
        LiveKeyboard.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.panel.isVisible else { return }
                    self.hosting.layoutSubtreeIfNeeded()
                    let fitting = self.hosting.fittingSize, current = self.panel.frame.size
                    if abs(fitting.width - current.width) > 0.5 || abs(fitting.height - current.height) > 0.5 { self.fitToContent() }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.hide()
        }
    }

    private var lastHiddenAt = Date.distantPast

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }
    /// The whole panel is on its screen and shows all of the keymap (nothing cut off).
    var fitsScreen: Bool {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return false }
        let fitting = hosting.fittingSize
        return visible.contains(panel.frame) && fitting.width <= panel.frame.width + 1 && fitting.height <= panel.frame.height + 1
    }
    /// Called with true when the overlay opens and false when it closes (the ghost steps aside).
    var onVisibilityChange: ((Bool) -> Void)?

    func toggle() {
        if isVisible {
            hide()
        } else if Date().timeIntervalSince(lastHiddenAt) > 0.3 {
            // A click on the status item can first make the panel resign key (hiding it)
            // and then deliver the action; do not re-open it in that case.
            show()
        }
    }

    func show() {
        model.reloadIfNeeded(path: settings.expandedPath)
        fitToContent()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        LiveKeyboard.shared.setOverlayVisible(true)
        onVisibilityChange?(true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        lastHiddenAt = Date()
        panel.orderOut(nil)
        LiveKeyboard.shared.setOverlayVisible(false)
        onVisibilityChange?(false)
    }

    /// Debug helper: feeds a key event straight into the panel.
    func simulateKey(code: UInt16, characters: String = "") {
        guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: panel.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
        panel.sendEvent(ev)
    }

    // MARK: - Private

    private func buildPanel() {
        let root = KeymapRootView(model: model, settings: settings)
        hosting = NSHostingView(rootView: root)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        panel = KeymapPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
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
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = effect
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: hide(); return true          // esc
        case 123: model.cycle(-1); return true // left
        case 124: model.cycle(1); return true  // right
        default: break
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return false }
        if let n = Int(chars), chars.count == 1 {
            model.select(n)
            return true
        }
        if chars == "a" || chars == "`" {
            model.select(nil)
            return true
        }
        if chars == "m" {
            LiveKeyboard.shared.toggleMisfires()
            return true
        }
        return false
    }

    private func fitToContent() {
        let screen = screenForPlacement()
        let visible = screen.visibleFrame
        let room = CGSize(width: visible.width - Self.screenMargin * 2, height: visible.height - Self.screenMargin * 2)
        // All layers at once are larger than a laptop display in one arrangement or another:
        // the one that suits this screen best is taken, and drawn smaller if it still does not fit.
        let all = model.selectedLayer == nil && model.visibleLayers.count > 2
        let choices = all ? Array(Self.columnChoices.prefix { $0 <= model.visibleLayers.count }) : [contentColumns]
        let sizes = choices.map { naturalSize(columns: $0) }
        let best = Self.bestFit(sizes: sizes, room: room)
        let columns = choices[best], natural = sizes[best]
        let scale = Self.scale(natural: natural, room: room)
        if abs(scale - contentScale) > 0.001 || columns != contentColumns {
            contentScale = scale
            contentColumns = columns
            hosting.rootView = KeymapRootView(model: model, settings: settings, scale: scale, columns: columns)
        }
        hosting.layoutSubtreeIfNeeded()
        let size = CGSize(width: (natural.width * scale).rounded(.up), height: (natural.height * scale).rounded(.up))
        panel.setContentSize(size)
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    /// The size of the keymap at full scale with that many layers side by side, measured off screen.
    private func naturalSize(columns: Int) -> CGSize {
        NSHostingView(rootView: KeymapRootView(model: model, settings: settings, columns: columns)).fittingSize
    }

    /// Which of the sizes fills `room` best: the one that can be drawn largest, and among those
    /// that fit as they are the one with the most room to spare on its tighter side.
    static func bestFit(sizes: [CGSize], room: CGSize) -> Int {
        func ratio(_ s: CGSize) -> CGFloat { s.width > 0 && s.height > 0 ? min(room.width / s.width, room.height / s.height) : 0 }
        return sizes.indices.max { ratio(sizes[$0]) < ratio(sizes[$1]) } ?? 0
    }

    /// The scale at which content of the size `natural` fits into `room`; never enlarged.
    static func scale(natural: CGSize, room: CGSize) -> CGFloat {
        guard natural.width > 0, natural.height > 0, room.width > 0, room.height > 0 else { return 1 }
        return min(1, room.width / natural.width, room.height / natural.height)
    }

    private func screenForPlacement() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
