import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let settings = AppSettings.shared
    private let model = KeymapModel()
    private lazy var overlay = OverlayController(model: model, settings: settings)
    private var settingsWindow: NSWindow?
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
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Vial Helper Settings"
            let hosting = NSHostingView(rootView: view)
            window.contentView = hosting
            window.setContentSize(hosting.fittingSize)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
            overlay.simulateKey(code: 53)
            check("esc hides overlay", !overlay.isVisible)
            for (name, passed) in VialDebug.selfChecks() { check(name, passed) }
            check("live polling stops with the overlay", !LiveKeyboard.shared.overlayVisible)
            LiveSelfTest.run(check)
            exit(ok ? 0 : 1)
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
        let view = KeymapRootView(model: model, settings: settings, plainBackground: true)
        let rendered: NSImage? = MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: view)
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
