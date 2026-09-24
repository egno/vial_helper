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

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
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
            overlay.simulateKey(code: 53)
            check("esc hides overlay", !overlay.isVisible)
            exit(ok ? 0 : 1)
        }
    }

    /// `--render out.png [--layer N]` renders the keymap view to a PNG and exits.
    private func handleCommandLine() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render"), i + 1 < args.count else { return false }
        let out = args[i + 1]
        if let li = args.firstIndex(of: "--layer"), li + 1 < args.count, let n = Int(args[li + 1]) {
            model.selectedLayer = n
        }
        model.reloadIfNeeded(path: settings.expandedPath, force: true)
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
