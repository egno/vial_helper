import AppKit
import Carbon.HIToolbox

/// Registers one system-wide hotkey through Carbon's RegisterEventHotKey.
/// This works without the Accessibility permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var onPress: (() -> Void)?
    var isRegistered: Bool { hotKeyRef != nil }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var current: KeyCombo?
    private let signature: OSType = 0x56494C48 // "VILH"

    private init() {}

    func register(_ combo: KeyCombo?) {
        unregister()
        current = combo
        guard let combo else { return }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
        } else {
            NSLog("VialHelper: RegisterEventHotKey failed (%d) for %@", status, combo.display)
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    /// Temporarily disables the hotkey (used while recording a new one).
    func suspend() { unregister() }
    func resume() { register(current) }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, _ in
            DispatchQueue.main.async { HotKeyCenter.shared.onPress?() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &handlerRef)
    }
}
