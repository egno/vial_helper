import SwiftUI
import ServiceManagement

/// Transient UI state of the settings window. Kept in an object (not `@State`) because the
/// Command Line Tools toolchain cannot expand SwiftUI's `@State` macro on recent SDKs.
final class SettingsUIState: ObservableObject {
    /// The shortcut being recorded, nil when none is.
    @Published var recordingSlot: HotKeySlot?
    var recording: Bool { recordingSlot != nil }
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
    @Published var customKeycodeError: String?
    var monitor: Any?
    /// The pane shown; remembered between openings.
    @Published var tab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settingsTab") ?? "") ?? .general {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab") }
    }
}

/// The panes of the settings window.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, keymap, ghost, keyboard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .keymap: return "Keymap"
        case .ghost: return "Ghost"
        case .keyboard: return "Keyboard"
        }
    }
}

struct SettingsView: View {
    static let width: CGFloat = 520

    @ObservedObject var settings: AppSettings
    @ObservedObject var model: KeymapModel
    @ObservedObject var ui: SettingsUIState
    @ObservedObject private var link = KeyboardLink.shared
    @ObservedObject private var live = LiveKeyboard.shared

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $ui.tab) {
                ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 12)
            Form {
                switch ui.tab {
                case .general: generalPane
                case .keymap: keymapPane
                case .ghost: ghostPane
                case .keyboard: keyboardPane
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: Self.width)
        .onDisappear { stopRecording() }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: - General

    @ViewBuilder private var generalPane: some View {
        Section("Shortcuts") {
            shortcutRow(.overlay, title: "Overlay")
            shortcutRow(.ghost, title: "Ghost mode")
            caption("Needs at least one of ⌘ ⌃ ⌥, or a function key.")
        }
        Section {
            Toggle("Launch at login", isOn: Binding(
                get: { ui.loginEnabled },
                set: { setLaunchAtLogin($0) }
            ))
            if let err = ui.loginError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Keymap

    @ViewBuilder private var keymapPane: some View {
        Section("Keymap file") {
            HStack {
                TextField("", text: $settings.vilPath, prompt: Text("~/aurora.vil"))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                Button("Browse…", action: browse)
            }
            HStack(spacing: 8) {
                if let f = model.file {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(f.fileName): \(f.layers.count) layers, \(f.rows)×\(f.cols) matrix, \(f.combos.count) combos")
                } else {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(model.error ?? "Not loaded")
                }
                Spacer()
                Button("Reload") { model.reloadIfNeeded(path: settings.expandedPath, force: true) }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Picker("Keymap source", selection: $settings.keymapSource) {
                ForEach(KeymapSourceSetting.allCases) { Text($0.title).tag($0) }
            }
            .help("The keyboard's keymap is read over the Vial protocol (read-only) each time the overlay opens; the file is used while the keyboard is away.")
            if let note = model.liveNote { caption(note) }
        }

        Section("Names") {
            LabeledContent("Layers") {
                TextField("", text: $settings.layerNames, prompt: Text("Base, Nav, Num, Sym…"))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.roundedBorder)
            }
            .help("Comma-separated, in layer order. Optional.")
            LabeledContent("Custom keycodes") {
                TextField("", text: $settings.customKeycodeNames, prompt: Text("Jiggle, Trainer…"))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.roundedBorder)
                Button("Load…", action: loadCustomKeycodeNames)
                    .help("Take the names from customKeycodes[].shortName of the keyboard's vial.json.")
            }
            .help("Comma-separated, in USER00, USER01… (QK_KB_n) order. Optional.")
            if let err = ui.customKeycodeError {
                Text(err).font(.caption).foregroundStyle(.red)
            } else {
                caption("Comma-separated, in layer / USER00, USER01… order.")
            }
        }

        Section("Overlay") {
            Picker("Encoders", selection: $settings.encoderMode) {
                ForEach(EncoderMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Slot 0 is the left half, slot 1 the right half. Hide the half you have no encoder on.")
            Toggle("Follow the active layer", isOn: $settings.followActiveLayer)
                .disabled(link.isConnected && !live.stateSupported)
                .help("With one layer zoomed, the overlay switches to the layer that is active on the keyboard. Needs firmware that reports its live state.")
            Picker("Hold-alone config layer", selection: $settings.holdAloneLayer) {
                Text("Off").tag(AppSettings.holdAloneOff)
                Text("Last layer").tag(AppSettings.holdAloneLast)
                ForEach(0..<max(model.layerCount, 1), id: \.self) { Text("L\($0)").tag($0) }
            }
            .help("Firmware with hold_alone.c taps the key at the same position on this layer when a layer-tap or mod-tap is held and released alone. The layer is hidden and its keys appear in teal on the tap-hold keys.")
        }
    }

    // MARK: - Ghost

    @ViewBuilder private var ghostPane: some View {
        let on = settings.ghostMode
        Section {
            Toggle("Show the ghost keymap", isOn: $settings.ghostMode)
                .disabled(!link.isConnected)
                .help("A see-through keymap of the layer that is active right now, on the screen you are working on. It never takes focus and clicks pass through it.")
            if !link.isConnected {
                Text(on ? "Keyboard not connected: the ghost comes back when it is." : "Keyboard not connected: ghost mode needs the keyboard link.")
                    .font(.caption).foregroundStyle(.orange)
            } else if !live.stateSupported {
                Text("This firmware does not report its layers: the ghost shows the base layer only.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }

        Section("Visibility") {
            Picker("Show", selection: $settings.ghostVisibility) {
                ForEach(GhostVisibility.allCases) { Text($0.title).tag($0) }
            }
            if settings.ghostVisibility.hidesWhenIdle {
                Slider(value: $settings.ghostHideDelay, in: AppSettings.ghostHideDelayRange, step: 0.5) {
                    valueLabel("Hide after", String(format: "%.1f s", settings.ghostHideDelay))
                }
            }
            Toggle("Fade while the pointer is over it", isOn: $settings.ghostAvoidPointer)
            Toggle("Hide from screenshots and screen sharing", isOn: $settings.ghostHideFromSharing)
        }
        .disabled(!on)

        Section("Placement") {
            Picker("Position", selection: $settings.ghostPosition) {
                ForEach(GhostPosition.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent(settings.ghostCustomPlaces.isEmpty ? "Custom place"
                           : "Custom place on \(settings.ghostCustomPlaces.count == 1 ? "one screen" : "\(settings.ghostCustomPlaces.count) screens")") {
                if !settings.ghostCustomPlaces.isEmpty {
                    Button("Reset") { settings.ghostCustomPlaces = [:] }
                }
                Button("Move Ghost…") { NotificationCenter.default.post(name: GhostController.moveRequested, object: nil) }
                    .disabled(!link.isConnected)
            }
            .help("Drag the ghost anywhere; the place is remembered per screen. Position applies to the other screens, and picking a position resets the current one.")
            Slider(value: $settings.ghostSize, in: AppSettings.ghostSizeRange, step: 2) {
                valueLabel("Size", "\(Int(settings.ghostSize)) pt")
            }
        }
        .disabled(!on)

        Section("Keys") {
            Slider(value: $settings.ghostOpacity, in: AppSettings.ghostOpacityRange) {
                valueLabel("Background opacity", "\(Int((settings.ghostOpacity * 100).rounded()))%")
            }
            Toggle("Simplified labels", isOn: $settings.ghostSimplifiedLabels)
                .help("Only the tap legend, plus the hold legend of mod-tap and layer-tap keys, in larger type.")
            Toggle("Hide keys inherited from lower layers", isOn: $settings.ghostHideInherited)
                .help("On upper layers, leaves out the transparent keys so only what the layer changes is shown.")
            Toggle("Highlight pressed keys", isOn: $settings.ghostHighlightPressed)
                .disabled(link.isConnected && !live.pushSupported && !settings.ghostHighlightPressed)
                .help(Self.highlightPressedHelp)
            if link.isConnected && !live.pushSupported {
                Text("This firmware has no key events (0xF7): nothing is highlighted.")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                caption("The keyboard then reports pressed key positions over raw HID, readable by any program that opens it.")
            }
        }
        .disabled(!on)
    }

    private func valueLabel(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    // MARK: - Keyboard

    @ViewBuilder private var keyboardPane: some View {
        Section("Link") {
            LabeledContent("Keyboard") {
                HStack(spacing: 6) {
                    Image(systemName: link.isConnected ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(link.isConnected ? Color.green : Color.secondary)
                    Text(link.isConnected ? (link.productName ?? "Connected") : "Not connected")
                }
            }
            if link.isConnected {
                LabeledContent("Firmware") {
                    Text(link.firmware.map { "\($0.version) · \($0.buildDay)" } ?? "Unknown")
                        .textSelection(.enabled)
                        .help(link.firmware.map { "Commit \($0.gitHash), built \($0.buildDate)" } ?? "")
                }
            }
            Toggle("Show clock and input source on the keyboard OLED", isOn: $settings.oledStatus)
        }
        if link.isConnected {
            Section("Supported by this firmware") {
                featureRow("Active layers and indicators", "0xF4", live.stateSupported)
                featureRow("Pushed state and pressed keys", "0xF7", live.pushSupported)
                featureRow("Misfire counters", "0xF3", live.misfireSupported)
                featureRow("Trainer results", "0xF5", live.trainerSupported)
                featureRow("Chordal Hold exemptions", "0xF6", live.tapHoldSupported)
                caption("A command counts as supported until the keyboard refuses it; some are only asked while the overlay or the ghost is on screen.")
            }
        }
    }

    private func featureRow(_ title: String, _ command: String, _ supported: Bool) -> some View {
        LabeledContent {
            Image(systemName: supported ? "checkmark" : "minus")
                .foregroundStyle(supported ? Color.green : Color.secondary)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Text(command).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    static let highlightPressedHelp = "Lights up the keys you are holding down, with a short afterglow. Privacy: for this the keyboard reports the positions of the pressed keys to the Mac over its raw HID interface, where any program that has the interface open can read them (together with the keymap that is what you type). Off by default; while it is off this app ignores those reports. Needs firmware with the 0xF7 events and is paused while the Vial app is running."

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (settings.expandedPath as NSString).deletingLastPathComponent)
        if panel.runModal() == .OK, let url = panel.url {
            settings.vilPath = url.path
        }
    }

    /// Fills the custom keycode names from `customKeycodes[].shortName` of a chosen vial.json.
    private func loadCustomKeycodeNames() {
        let panel = NSOpenPanel()
        panel.title = "Choose the keyboard's vial.json"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let names = Keycode.customKeycodeNames(vialJSON: data) else {
            ui.customKeycodeError = "No \"customKeycodes\" list in \(url.lastPathComponent)."
            return
        }
        ui.customKeycodeError = nil
        settings.customKeycodeNames = names.joined(separator: ", ")
    }

    private func shortcutRow(_ slot: HotKeySlot, title: String) -> some View {
        let recording = ui.recordingSlot == slot
        let combo = settings.hotKey(for: slot)
        return HStack {
            Text(title)
            Spacer()
            Text(recording ? "Press a shortcut… (esc)" : (combo?.display ?? "None"))
                .font(.system(.body, design: .rounded).monospacedDigit())
                .frame(minWidth: 150, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(recording ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)))
            Button(recording ? "Cancel" : "Record") { recording ? stopRecording() : startRecording(slot) }
                .disabled(ui.recording && !recording)
            Button("Clear") { settings.setHotKey(nil, for: slot) }.disabled(combo == nil || ui.recording)
        }
    }

    private func startRecording(_ slot: HotKeySlot) {
        ui.recordingSlot = slot
        HotKeyCenter.shared.suspend()
        ui.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // esc
                stopRecording()
                return nil
            }
            if let combo = KeyCombo.from(event: event) {
                // One combination cannot be registered twice; the other shortcut gives it up.
                for other in HotKeySlot.allCases where other != slot && settings.hotKey(for: other) == combo {
                    settings.setHotKey(nil, for: other)
                }
                settings.setHotKey(combo, for: slot)
                stopRecording()
                return nil
            }
            NSSound.beep()
            return nil
        }
    }

    private func stopRecording() {
        if let m = ui.monitor { NSEvent.removeMonitor(m) }
        ui.monitor = nil
        if ui.recording {
            ui.recordingSlot = nil
            HotKeyCenter.shared.resume()
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            ui.loginError = nil
        } catch {
            ui.loginError = "Could not change login item: \(error.localizedDescription). Move the app to /Applications and try again."
        }
        ui.loginEnabled = SMAppService.mainApp.status == .enabled
    }
}
