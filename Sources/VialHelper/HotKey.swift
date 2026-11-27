import AppKit
import Carbon.HIToolbox

/// What a system-wide hotkey does. The raw value is the Carbon hotkey id.
enum HotKeySlot: UInt32, CaseIterable {
    /// Toggles the keymap overlay.
    case overlay = 1
    /// Toggles ghost mode.
    case ghost = 2
}

/// Registers the system-wide hotkeys (one per `HotKeySlot`) through Carbon's RegisterEventHotKey.
/// This works without the Accessibility permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// Handler of the overlay hotkey.
    var onPress: (() -> Void)? {
        get { handlers[.overlay] }
        set { handlers[.overlay] = newValue }
    }
    var isRegistered: Bool { isRegistered(.overlay) }

    private var handlers: [HotKeySlot: () -> Void] = [:]
    private var refs: [HotKeySlot: EventHotKeyRef] = [:]
    private var combos: [HotKeySlot: KeyCombo] = [:]
    private var handlerRef: EventHandlerRef?
    private var suspended = false
    private let signature: OSType = 0x56494C48 // "VILH"

    private init() {}

    func isRegistered(_ slot: HotKeySlot) -> Bool { refs[slot] != nil }

    func setHandler(_ slot: HotKeySlot, _ handler: @escaping () -> Void) { handlers[slot] = handler }

    func register(_ combo: KeyCombo?, slot: HotKeySlot = .overlay) {
        unregister(slot)
        combos[slot] = combo
        guard let combo, !suspended else { return }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: slot.rawValue)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[slot] = ref
        } else {
            NSLog("VialHelper: RegisterEventHotKey failed (%d) for %@", status, combo.display)
        }
    }

    private func unregister(_ slot: HotKeySlot) {
        if let ref = refs.removeValue(forKey: slot) { UnregisterEventHotKey(ref) }
    }

    /// Temporarily disables every hotkey (used while recording a new one).
    func suspend() {
        suspended = true
        HotKeySlot.allCases.forEach(unregister)
    }

    func resume() {
        suspended = false
        for slot in HotKeySlot.allCases { register(combos[slot], slot: slot) }
    }

    fileprivate func pressed(id: UInt32) {
        guard let slot = HotKeySlot(rawValue: id) else { return }
        handlers[slot]?()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let pressed = id.id
            DispatchQueue.main.async { HotKeyCenter.shared.pressed(id: pressed) }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &handlerRef)
    }
}
