import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let settings = AppSettings.shared
    private let model = KeymapModel()
    private lazy var overlay = OverlayController(model: model, settings: settings)
    private lazy var ghost = GhostController(model: model, settings: settings)
    private var settingsWindow: NSWindow?
    private var settingsHosting: NSHostingController<SettingsView>?
    /// The pane height the settings window was last sized for.
    private var settingsFitHeight: CGFloat = 0
    private let settingsUI = SettingsUIState()
    private var cancellables = Set<AnyCancellable>()
    private let link = KeyboardLink.shared
    private lazy var statusFeeder = StatusFeeder(link: link)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handleHIDCommandLine() { return }
        if LiveDebug.handleCommandLine() { return }

        settings.$holdAloneLayer
            .sink { [weak self] in self?.model.holdAloneSetting = $0 }
            .store(in: &cancellables)

        if VialDebug.handleCommandLine(model: model, settings: settings, link: link, render: { [self] in _ = handleCommandLine() }) { return }
        if handleCommandLine() { return }

        model.reloadIfNeeded(path: settings.expandedPath)
        setupStatusItem()

        HotKeyCenter.shared.onPress = { [weak self] in self?.overlay.toggle() }
        HotKeyCenter.shared.register(settings.hotKey)

        settings.$hotKey
            .dropFirst()
            .removeDuplicates()
            .sink { HotKeyCenter.shared.register($0) }
            .store(in: &cancellables)

        HotKeyCenter.shared.setHandler(.ghost) { [weak self] in self?.toggleGhost() }
        HotKeyCenter.shared.register(settings.ghostHotKey, slot: .ghost)
        settings.$ghostHotKey
            .dropFirst()
            .removeDuplicates()
            .sink { HotKeyCenter.shared.register($0, slot: .ghost) }
            .store(in: &cancellables)
        // The ghost exists only while the keyboard is connected: it goes away with the keyboard
        // and, if it was left on, comes back with it (also at launch).
        settings.$ghostMode
            .combineLatest(link.$isConnected)
            .map { $0 && $1 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                guard let self else { return }
                if on { self.ghost.show() } else { self.ghost.hide() }
            }
            .store(in: &cancellables)
        // The overlay shows the same keymap, so the ghost fades away while it is open.
        overlay.onVisibilityChange = { [weak self] in self?.ghost.setOverlayOpen($0) }
        NotificationCenter.default.publisher(for: GhostController.moveRequested)
            .sink { [weak self] _ in self?.moveGhost() }
            .store(in: &cancellables)

        settings.$vilPath
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.model.reloadIfNeeded(path: self.settings.expandedPath, force: true)
            }
            .store(in: &cancellables)

        link.start()
        statusFeeder.start(settings: settings, layout: .shared)
        model.live.start(link: link, settings: settings)
        LiveKeyboard.shared.start(model: model, settings: settings)

        if CommandLine.arguments.contains("--show") {
            overlay.show()
        }
        if CommandLine.arguments.contains("--settings") {
            openSettings()
        }
        if CommandLine.arguments.contains("--selftest") {
            runSelfTest()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusFeeder.shutdown()
        LiveKeyboard.shared.shutdown()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Vial Helper")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Vial Helper — click to show keymap, right-click for menu"
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            showMenu()
        } else {
            overlay.toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let about = NSMenuItem(title: appVersionLine(), action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let keyboard = NSMenuItem(title: link.statusLine, action: nil, keyEquivalent: "")
        keyboard.isEnabled = false
        menu.addItem(keyboard)
        menu.addItem(.separator())

        let show = NSMenuItem(title: overlay.isVisible ? "Hide Keymap" : "Show Keymap", action: #selector(toggleOverlay), keyEquivalent: "")
        show.target = self
        if let hk = settings.hotKey {
            show.keyEquivalent = hk.keyName.count == 1 ? hk.keyName.lowercased() : ""
            show.keyEquivalentModifierMask = hk.flags
        }
        menu.addItem(show)

        let ghostItem = NSMenuItem(title: "Ghost Mode", action: link.isConnected ? #selector(toggleGhost) : nil, keyEquivalent: "")
        ghostItem.target = self
        ghostItem.isEnabled = link.isConnected
        ghostItem.state = settings.ghostMode && link.isConnected ? .on : .off
        if let hk = settings.ghostHotKey {
            ghostItem.keyEquivalent = hk.keyName.count == 1 ? hk.keyName.lowercased() : ""
            ghostItem.keyEquivalentModifierMask = hk.flags
        }
        menu.addItem(ghostItem)

        let moveItem = NSMenuItem(title: ghost.isMoving ? "Finish Moving Ghost" : "Move Ghost…", action: ghost.isActive ? #selector(moveGhost) : nil, keyEquivalent: "")
        moveItem.target = self
        moveItem.isEnabled = ghost.isActive
        menu.addItem(moveItem)

        let reload = NSMenuItem(title: "Reload Keymap", action: #selector(reloadKeymap), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        let openFile = NSMenuItem(title: "Open .vil File…", action: #selector(chooseFile), keyEquivalent: "o")
        openFile.target = self
        menu.addItem(openFile)

        let reveal = NSMenuItem(title: "Reveal .vil in Finder", action: #selector(revealFile), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())
        LiveMenu.shared.addItems(to: menu)

        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Vial Helper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// "Vial Helper 1.0.0"; when run unbundled (`swift run`) there is no Info.plist version.
    private func appVersionLine() -> String {
        guard let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "Vial Helper (dev build)"
        }
        return "Vial Helper \(v)"
    }

    private func statusLine() -> String {
        if let f = model.file { return "\(f.fileName) · \(f.layers.count) layers" }
        return "Keymap not loaded"
    }

    // MARK: - Actions

    @objc private func toggleOverlay() { overlay.toggle() }

    /// Menu item and hotkey; does nothing while the keyboard is away.
    @objc private func toggleGhost() {
        guard link.isConnected else { return }
        settings.ghostMode.toggle()
    }

    /// Menu item and the Settings button: lets the ghost be dragged to a place of its own (or
    /// ends that). Only while the ghost is on.
    @objc private func moveGhost() {
        if ghost.isMoving { ghost.endMove(keep: true); return }
        overlay.hide()
        ghost.beginMove()
    }

    @objc private func reloadKeymap() {
        model.reloadIfNeeded(path: settings.expandedPath, force: true)
    }

    @objc private func chooseFile() {
        overlay.hide()
        let panel = NSOpenPanel()
        panel.title = "Choose a Vial keymap"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (settings.expandedPath as NSString).deletingLastPathComponent)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            settings.vilPath = url.path
            model.reloadIfNeeded(path: url.path, force: true)
            overlay.show()
        }
    }

    @objc private func revealFile() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: settings.expandedPath)])
    }

    @objc private func openSettings() {
        overlay.hide()
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, model: model, ui: settingsUI)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Vial Helper Settings"
            // Each pane has its own height: the window takes it (see `fitSettingsWindow`), up to
            // what the screen allows, and the form scrolls inside when that is not enough. With its
            // sizing options the hosting controller would force the full height on the window.
            let hosting = NSHostingController(rootView: view)
            hosting.sizingOptions = []
            window.contentViewController = hosting
            settingsHosting = hosting
            // The pane's height changes with the tab, and with rows that come and go (keyboard
            // connected, a mode with a delay, what the firmware supports).
            let changes: [AnyPublisher<Void, Never>] = [
                settingsUI.objectWillChange.eraseToAnyPublisher(),
                settings.objectWillChange.eraseToAnyPublisher(),
                link.objectWillChange.eraseToAnyPublisher(),
                LiveKeyboard.shared.objectWillChange.eraseToAnyPublisher(),
                model.objectWillChange.eraseToAnyPublisher(),
            ]
            Publishers.MergeMany(changes)
                .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
                .sink { [weak self] in self?.fitSettingsWindow(animated: true) }
                .store(in: &cancellables)
            window.isReleasedWhenClosed = false
            settingsWindow = window
            fitSettingsWindow(animated: false)
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Sizes the settings window to the pane shown, keeping its top edge where it is.
    private func fitSettingsWindow(animated: Bool) {
        guard let window = settingsWindow, let hosting = settingsHosting, !animated || window.isVisible else { return }
        let width = SettingsView.width
        // The form takes any height it is offered, so its own height is asked of a fresh hosting
        // view (the window's one has no sizing options, see `openSettings`).
        let ideal = NSHostingView(rootView: hosting.rootView).fittingSize.height
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let room = screen.map { $0.visibleFrame.height - 60 } ?? 600
        let content = NSSize(width: width, height: min(max(ideal, 200), max(room, 300)))
        window.contentMinSize = NSSize(width: width, height: 200)
        window.contentMaxSize = NSSize(width: width, height: 10_000)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let visible = screen?.visibleFrame, frame.minY < visible.minY { frame.origin.y = visible.minY }
        // Not after a hand resize either way: only when the pane's own height asks for another one.
        guard !animated || abs(ideal - settingsFitHeight) > 0.5 else { return }
        settingsFitHeight = ideal
        window.setFrame(frame, display: true, animate: animated)
    }

    // MARK: - Command line (debug helpers)

    /// `--selftest`: opens the overlay, exercises the key handling, prints results and exits.
    private func runSelfTest() {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print("\(cond ? "PASS" : "FAIL") \(name)"); ok = ok && cond }
        overlay.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            check("overlay visible after show", overlay.isVisible)
            check("hotkey registered", HotKeyCenter.shared.isRegistered)
            overlay.simulateKey(code: 18, characters: "1")
            check("digit selects layer 1", model.selectedLayer == 1)
            overlay.simulateKey(code: 124)
            check("right arrow cycles to layer 2", model.selectedLayer == 2)
            overlay.simulateKey(code: 0, characters: "a")
            check("'a' shows all layers", model.selectedLayer == nil)
            let misfiresShown = LiveKeyboard.shared.showMisfires
            overlay.simulateKey(code: 46, characters: "m")
            check("'m' toggles the misfire heatmap", LiveKeyboard.shared.showMisfires != misfiresShown)
            overlay.simulateKey(code: 46, characters: "m")
            check("live overlay polling follows visibility", LiveKeyboard.shared.overlayVisible)
            // Ghost mode, driven through the controller so the stored setting is left alone.
            let wasGhost = ghost.isVisible
            ghost.show()
            check("ghost on after show", ghost.isActive)
            check("ghost never takes focus", !ghost.canTakeFocus)
            check("ghost is click-through", ghost.ignoresMouse)
            check("overlay keeps the keyboard with the ghost on", overlay.isKey)
            check("ghost stays on the screen", ghost.isOnScreen)
            check("ghost steps aside while the overlay is open", ghost.presence.overlayOpen && ghost.targetAlpha == 0 && !ghost.isVisible)
            check("live polling stays fast for the faded-out ghost", LiveKeyboard.shared.ghostVisible)
            check("ghost sharing type follows the setting", ghost.sharingType == (settings.ghostHideFromSharing ? .none : .readOnly))
            overlay.simulateKey(code: 53)
            check("esc hides overlay", !overlay.isVisible)
            // What the ghost comes back to depends on the stored visibility mode, the keyboard's
            // layer and the pointer; the overlay must no longer be one of the reasons.
            var expected = ghost.presence
            expected.overlayOpen = false
            check("ghost outlives the overlay", ghost.isActive && ghost.presence == expected && ghost.targetAlpha == expected.alpha)
            check("live polling stays fast for the ghost", LiveKeyboard.shared.ghostVisible)
            // Placing by hand: the stored places are put back afterwards.
            let places = settings.ghostCustomPlaces
            ghost.beginMove()
            check("ghost takes the mouse while being moved", ghost.isMoving && !ghost.ignoresMouse && ghost.targetAlpha == 1)
            ghost.simulateDrag(to: NSPoint(x: -20000, y: 30000))
            ghost.endMove(keep: false)
            check("cancelled move puts the ghost back", !ghost.isMoving && ghost.isOnScreen && settings.ghostCustomPlaces == places)
            ghost.beginMove()
            ghost.simulateDrag(to: NSPoint(x: -20000, y: 30000))
            ghost.endMove(keep: true)
            check("moved ghost is remembered", settings.ghostCustomPlaces != places)
            check("moved ghost is clamped to the screen", ghost.isOnScreen)
            check("ghost is click-through again after the move", !ghost.isMoving && ghost.ignoresMouse && !ghost.canTakeFocus)
            settings.ghostCustomPlaces = places
            GhostWindowSelfTest.run(check)
            for (name, passed) in VialDebug.selfChecks() { check(name, passed) }
            check("live polling stops with the overlay", !LiveKeyboard.shared.overlayVisible)
            LiveSelfTest.run(check)
            PushSelfTest.run({ name, passed in check(name, passed) }, done: { [self] in
                // The fades are animations: the panel's real alpha is looked at once it has
                // arrived (or a deadline has passed), not after a fixed delay.
                Poll.until({ [self] in abs(ghost.panelAlpha - ghost.targetAlpha) < 0.01 }) { [self] _ in
                    check("ghost alpha settles on its target", abs(ghost.panelAlpha - ghost.targetAlpha) < 0.01)
                    overlay.show()
                    let opened = overlay.isVisible && ghost.presence.overlayOpen && ghost.targetAlpha == 0
                    Poll.until({ [self] in ghost.panelAlpha < 0.01 }) { [self] _ in
                        check("ghost faded out under the overlay", opened && overlay.isVisible && ghost.panelAlpha < 0.01)
                        overlay.hide()
                        if !wasGhost { ghost.hide() }
                        check("ghost hides", wasGhost || !ghost.isActive)
                        check("live polling slows down without the ghost", wasGhost || !LiveKeyboard.shared.ghostVisible)
                        exit(ok ? 0 : 1)
                    }
                }
            })
        }
    }

    /// `--hid-version` prints the firmware version, build date and git hash and exits.
    /// `--hid-status "12:34|EN" [--ttl N]` sends one host status text (rows separated by "|",
    /// empty text or ttl 0 clears it), prints the reply and exits.
    /// `--hid-raw "f0 02"` sends the given hex bytes as one report and prints the reply.
    private func handleHIDCommandLine() -> Bool {
        let args = CommandLine.arguments
        let wantsVersion = args.contains("--hid-version")
        let statusIndex = args.firstIndex(of: "--hid-status")
        let rawIndex = args.firstIndex(of: "--hid-raw")
        guard wantsVersion || statusIndex != nil || rawIndex != nil else { return false }
        func finish(_ line: String, ok: Bool) -> Never {
            print(line)
            exit(ok ? 0 : 1)
        }
        link.start()
        link.whenConnected(timeout: 2) { [self] connected in
            guard connected else {
                if let code = link.transport.openError {
                    finish(String(format: "not connected (could not open the HID interface: 0x%08x)", UInt32(bitPattern: code)), ok: false)
                }
                finish("not connected", ok: false)
            }
            print("connected: \(link.productName ?? "?")")
            if let ri = rawIndex {
                let text = ri + 1 < args.count ? args[ri + 1] : ""
                let bytes = text.split(whereSeparator: { " ,".contains($0) }).compactMap { UInt8($0, radix: 16) }
                link.transport.request(bytes) { finish($0.summary, ok: $0.bytes != nil) }
                return
            }
            if let si = statusIndex {
                let text = si + 1 < args.count ? args[si + 1] : ""
                var ttl = UInt8(StatusFeeder.ttl)
                if let ti = args.firstIndex(of: "--ttl"), ti + 1 < args.count, let n = UInt8(args[ti + 1]) { ttl = n }
                let rows = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                link.sendStatus(rows: rows, ttl: text.isEmpty ? 0 : ttl) { reply in
                    if let b = reply.bytes {
                        print("ttl \(b[1]) s, status \(b[2]), display \(b[3]) rows x \(b[4]) cols")
                    }
                    finish(reply.summary, ok: reply.bytes != nil)
                }
                return
            }
            let names = ["version", "built", "commit"]
            func field(_ i: Int) {
                guard i < names.count else { exit(0) }
                link.versionField(UInt8(i)) { reply, text in
                    guard let text else { finish("\(names[i]): \(reply.summary)", ok: false) }
                    print("\(names[i].padding(toLength: 8, withPad: " ", startingAt: 0))\(text)")
                    field(i + 1)
                }
            }
            field(0)
        }
        return true
    }

    /// `--render out.png [--layer N]` renders the keymap view to a PNG and exits.
    private func handleCommandLine() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render"), i + 1 < args.count else { return false }
        let out = args[i + 1]
        if let li = args.firstIndex(of: "--layer"), li + 1 < args.count, let n = Int(args[li + 1]) {
            model.selectedLayer = n
        }
        // Debug: `--chordal-exempt 303,304,100` pre-fills the Chordal Hold exemption set (row*100+col).
        if let ci = args.firstIndex(of: "--chordal-exempt"), ci + 1 < args.count {
            model.chordalExempt = Set(args[ci + 1].split(separator: ",").compactMap { Int($0) })
        }
        model.reloadIfNeeded(path: settings.expandedPath, force: true)
        LiveDebug.applyRenderInjection(model: model)
        // `--ghost` renders the ghost-mode view instead (the layer comes from `--inject-state`).
        let ghostView = args.contains("--ghost")
        let rendered: NSImage? = MainActor.assumeIsolated {
            if ghostView {
                let renderer = ImageRenderer(content: GhostView(model: model, settings: settings, plainBackground: true))
                renderer.scale = 2
                return renderer.nsImage
            }
            let renderer = ImageRenderer(content: KeymapRootView(model: model, settings: settings, plainBackground: true))
            renderer.scale = 2
            return renderer.nsImage
        }
        guard let image = rendered,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            fputs("render failed\n", stderr)
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: out))
            print("wrote \(out) (\(Int(image.size.width))x\(Int(image.size.height)))")
            exit(0)
        } catch {
            fputs("write failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
