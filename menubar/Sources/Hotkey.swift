// Hotkey.swift -- the global summon shortcut: a Carbon-registered hotkey
// that works without Accessibility or Input Monitoring permission, plus the
// small AppKit-backed recorder control Settings uses to change it.
//
// RegisterEventHotKey (not NSEvent.addGlobalMonitorForEvents) is the whole
// reason this file exists: a global monitor needs Input Monitoring, which is
// a permission prompt and a trip to System Settings before the shortcut does
// anything. The Carbon hotkey manager is the same mechanism menu-bar
// utilities have used for years, and needs nothing beyond launching.

import Carbon.HIToolbox
import AppKit
import SwiftUI

/// A key code plus the Carbon modifier mask it is chorded with. Carbon's
/// virtual key codes, not characters: Option+Q types "\u{0153}", but the
/// hotkey manager only ever sees keyCode 12 (kVK_ANSI_Q) with optionKey set.
struct KeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// \u{2325}Q. Not a stock macOS or Spotlight binding, and sits right
    /// under the left hand next to quick-fire's other hotkeys.
    static let defaultCombo = KeyCombo(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(optionKey))

    /// "\u{2303}\u{2325}\u{21E7}\u{2318}Q", built in the same order System
    /// Settings orders its own modifier glyphs.
    var displayString: String {
        var out = ""
        if modifiers & UInt32(controlKey) != 0 { out += "\u{2303}" }
        if modifiers & UInt32(optionKey) != 0 { out += "\u{2325}" }
        if modifiers & UInt32(shiftKey) != 0 { out += "\u{21E7}" }
        if modifiers & UInt32(cmdKey) != 0 { out += "\u{2318}" }
        out += KeyCombo.label(for: keyCode)
        return out
    }

    /// A label for the keys a recorder is realistically going to see: letters,
    /// digits, and the handful of named keys worth chording. Anything else
    /// still prints something rather than nothing.
    static func label(for keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "\u{21A9}",
            UInt32(kVK_Tab): "\u{21E5}", UInt32(kVK_Delete): "\u{232B}",
            UInt32(kVK_Escape): "\u{238B}",
            UInt32(kVK_LeftArrow): "\u{2190}", UInt32(kVK_RightArrow): "\u{2192}",
            UInt32(kVK_UpArrow): "\u{2191}", UInt32(kVK_DownArrow): "\u{2193}",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }
}

/// Wraps RegisterEventHotKey/UnregisterEventHotKey. One instance per summon
/// shortcut; `register` tears down and reinstalls, so changing the combo in
/// Settings is always "unregister the old one, try the new one" rather than
/// two independently tracked handlers drifting apart.
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var isRegistered = false
    private let onPress: () -> Void
    private let hotKeyID: EventHotKeyID

    private static var nextID: UInt32 = 0

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
        Self.nextID += 1
        // "QtHk" as a four-byte signature -- Carbon's convention for telling
        // one app's hotkeys apart from another's. Nothing here reads it back;
        // the id alone is enough, since this process only ever registers one
        // hotkey at a time.
        let signature = FourCharCode(bitPattern: Int32(bitPattern: 0x5174_486B))
        self.hotKeyID = EventHotKeyID(signature: signature, id: Self.nextID)
    }

    /// Installs the event handler once, lazily, on first register: a process
    /// that never registers a hotkey (every --dump-* seam, every test that
    /// never calls --dump-hotkey) never touches the Carbon event target.
    private func ensureHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var pressedID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &pressedID)
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            if status == noErr, pressedID.id == hotkey.hotKeyID.id {
                hotkey.onPress()
            }
            return OSStatus(noErr)
        }, 1, &spec, selfPtr, &handlerRef)
    }

    /// Unregisters whatever is currently active, then tries to register
    /// `combo`. `combo == nil` (Clear) unregisters and stops there. Returns
    /// whether a hotkey ended up registered, which is what `--dump-hotkey`
    /// and the Settings recorder both report back.
    @discardableResult
    func register(_ combo: KeyCombo?) -> Bool {
        unregister()
        guard let combo else { return false }
        ensureHandler()
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        isRegistered = (status == noErr)
        return isRegistered
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        isRegistered = false
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

/// The AppKit view that actually captures a key combo. A real NSView rather
/// than SwiftUI's onKeyPress: onKeyPress reports a KeyPress's `characters`
/// -- Option+Q types "\u{0153}" -- not the Carbon key code
/// RegisterEventHotKey actually wants.
final class HotkeyRecorderNSView: NSView {
    var onChange: ((KeyCombo) -> Void)?
    private(set) var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    func stopRecording() {
        isRecording = false
    }

    /// Requires at least one modifier: a bare letter registered as a *global*
    /// hotkey would fire every time that letter is typed anywhere, which is
    /// not a shortcut, it is a landmine. Pressing Escape while recording
    /// cancels without recording anything.
    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            return
        }
        let mods = Self.carbonModifiers(from: event.modifierFlags)
        guard mods != 0 else { return }
        isRecording = false
        onChange?(KeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods))
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }
}

/// SwiftUI's side of the recorder: an invisible AppKit view that becomes
/// first responder on demand, the same zero-sized-control trick MenuView
/// already uses for its command-key shortcuts.
struct HotkeyField: NSViewRepresentable {
    @Binding var recording: Bool
    var onChange: (KeyCombo) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.onChange = { combo in
            recording = false
            onChange(combo)
        }
        return view
    }

    func updateNSView(_ view: HotkeyRecorderNSView, context: Context) {
        if recording, !view.isRecording {
            view.startRecording()
        } else if !recording, view.isRecording {
            view.stopRecording()
        }
    }
}

/// The recorder Settings shows: a clickable pill with the current combo (or
/// "Click to record"), and a Clear button that disables the hotkey outright
/// -- a real, round-trippable state, not the same thing as "using the
/// default".
struct HotkeyRecorderControl: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { recording = true }) {
                Text(recording ? "Press keys\u{2026} (Esc cancels)"
                                : (combo?.displayString ?? "Click to record"))
                    .font(.system(size: 12, design: recording ? .default : .monospaced))
                    .frame(minWidth: 150, alignment: .leading)
            }
            .buttonStyle(.bordered)
            Button("Clear") { combo = nil }
                .controlSize(.small)
                .disabled(combo == nil)
            HotkeyField(recording: $recording) { combo = $0 }
                .frame(width: 0, height: 0)
        }
    }
}
