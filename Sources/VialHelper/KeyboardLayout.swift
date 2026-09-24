import AppKit
import Carbon

/// Tracks the active keyboard input source and, for each QMK keycode in `Keycode.basic`, the
/// character its physical key position produces under that layout — letters, digits and
/// punctuation alike (e.g. KC_Q -> "A" on AZERTY, KC_A -> "Ф" on a Russian layout, KC_GRV -> "Щ"
/// since several Cyrillic letters land on what are punctuation keys in the US layout, and
/// KC_1 -> "&" on AZERTY where the digit row types symbols unshifted).
///
/// The QMK keycode names assume a US ANSI board, so instead of hardcoding which macOS virtual
/// keycode each one sits at, we read that from the real "US" layout at runtime: translate every
/// virtual keycode under it and match the result against `Keycode.basic`'s characters. That same
/// virtual keycode, translated under whatever layout is currently active, gives the live label.
final class KeyboardLayoutObserver: ObservableObject {
    static let shared = KeyboardLayoutObserver()

    /// QMK keycode -> the character its physical position types under the active layout.
    @Published private(set) var overrides: [String: String] = [:]

    /// QMK keycode -> physical key position, discovered from the US layout (see type doc).
    private lazy var referencePositions: [String: CGKeyCode] = Self.discoverReferencePositions()

    private init() {
        refresh()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(refresh),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// Reads the real "US" ANSI layout to find which virtual keycode types each single-character
    /// label in `Keycode.basic` (letters, digits, punctuation) — no hardcoded position table.
    private static func discoverReferencePositions() -> [String: CGKeyCode] {
        guard let layoutData = keyLayoutData(forSourceID: "com.apple.keylayout.US") else { return [:] }

        var charToVK: [Character: CGKeyCode] = [:]
        withUCKeyboardLayout(layoutData) { layoutPtr in
            for vk: CGKeyCode in 0..<128 {
                guard let s = translate(layoutPtr, vk), s.count == 1 else { continue }
                // Prefer the first (lowest-vk) match: the numeric keypad's "-"/"="/"." etc. sit
                // at higher virtual keycodes than the main row and would otherwise clobber it —
                // and keypad keys stay numeric under other layouts, silently losing the override.
                if charToVK[s.first!] == nil { charToVK[s.first!] = vk }
            }
        }

        var result: [String: CGKeyCode] = [:]
        for (code, label) in Keycode.basic {
            guard label.count == 1, let ch = label.lowercased().first, let vk = charToVK[ch] else { continue }
            result[code] = vk
        }
        return result
    }

    @objc private func refresh() {
        guard !referencePositions.isEmpty,
              let layoutData = Self.currentKeyLayoutData() else {
            overrides = [:]
            return
        }

        var result: [String: String] = [:]
        Self.withUCKeyboardLayout(layoutData) { layoutPtr in
            for (code, vk) in referencePositions {
                // Show whatever the position types now — letter, digit or symbol — as long as
                // it's a single printable character (dead keys are disabled in `translate`, so
                // this is always a base character, never an empty placeholder).
                guard let s = Self.translate(layoutPtr, vk), s.count == 1,
                      let scalar = s.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar) else { continue }
                result[code] = s.uppercased()
            }
        }
        overrides = result
    }

    // MARK: - Carbon helpers

    private static func keyLayoutData(forSourceID id: String) -> Data? {
        guard let list = TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, true)?
            .takeRetainedValue() as? [TISInputSource], let source = list.first else { return nil }
        return keyLayoutData(of: source)
    }

    private static func currentKeyLayoutData() -> Data? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return keyLayoutData(of: source)
    }

    private static func keyLayoutData(of source: TISInputSource) -> Data? {
        guard let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return unsafeBitCast(dataPtr, to: CFData.self) as Data
    }

    private static func withUCKeyboardLayout(_ data: Data, _ body: (UnsafePointer<UCKeyboardLayout>) -> Void) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            body(ptr)
        }
    }

    private static func translate(_ layoutPtr: UnsafePointer<UCKeyboardLayout>, _ vk: CGKeyCode) -> String? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            layoutPtr, vk, UInt16(kUCKeyActionDown), 0,
            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState, chars.count, &length, &chars
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
