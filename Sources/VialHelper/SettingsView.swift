import SwiftUI
import ServiceManagement

/// Transient UI state of the settings window. Kept in an object (not `@State`) because the
/// Command Line Tools toolchain cannot expand SwiftUI's `@State` macro on recent SDKs.
final class SettingsUIState: ObservableObject {
    @Published var recording = false
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
    var monitor: Any?
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: KeymapModel
    @ObservedObject var ui: SettingsUIState

    var body: some View {
        Form {
            Section("Keymap file") {
                HStack {
                    TextField("~/aurora.vil", text: $settings.vilPath)
                        .textFieldStyle(.roundedBorder)
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
            }

            Section("Global shortcut") {
                HStack {
                    Text(ui.recording ? "Press a shortcut… (esc to cancel)" : (settings.hotKey?.display ?? "None"))
                        .font(.system(.body, design: .rounded).monospacedDigit())
                        .frame(minWidth: 180, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(ui.recording ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)))
                    Spacer()
                    Button(ui.recording ? "Cancel" : "Record") { ui.recording ? stopRecording() : startRecording() }
                    Button("Clear") { settings.hotKey = nil }.disabled(settings.hotKey == nil || ui.recording)
                }
                Text("Needs at least one of ⌘ ⌃ ⌥, or a function key.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Layer names") {
                TextField("Base, Nav, Num, Sym…", text: $settings.layerNames)
                    .textFieldStyle(.roundedBorder)
                Text("Comma-separated, in layer order. Optional.").font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Picker("Encoders", selection: $settings.encoderMode) {
                    ForEach(EncoderMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Slot 0 is the left half, slot 1 the right half. Hide the half you have no encoder on.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Launch at login", isOn: Binding(
                    get: { ui.loginEnabled },
                    set: { setLaunchAtLogin($0) }
                ))
                if let err = ui.loginError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onDisappear { stopRecording() }
    }

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

    private func startRecording() {
        ui.recording = true
        HotKeyCenter.shared.suspend()
        ui.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // esc
                stopRecording()
                return nil
            }
            if let combo = KeyCombo.from(event: event) {
                settings.hotKey = combo
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
            ui.recording = false
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
