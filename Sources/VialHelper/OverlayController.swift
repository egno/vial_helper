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

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.hide()
        }
    }

    private var lastHiddenAt = Date.distantPast

    var isVisible: Bool { panel.isVisible }

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
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        lastHiddenAt = Date()
        panel.orderOut(nil)
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
        return false
    }

    private func fitToContent() {
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        let screen = screenForPlacement()
        let visible = screen.visibleFrame
        // Keep the panel on screen.
        size.width = min(size.width, visible.width - 40)
        size.height = min(size.height, visible.height - 40)
        panel.setContentSize(size)
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private func screenForPlacement() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
