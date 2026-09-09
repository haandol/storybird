import AppKit
import Carbon.HIToolbox
import Foundation

enum StorybirdCommandAction: String, CaseIterable, Identifiable, Sendable {
    case newProject
    case toggleRecording
    case importVideo
    case exportVideo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newProject: "New recording project"
        case .toggleRecording: "Start or stop recording"
        case .importVideo: "Import video"
        case .exportVideo: "Export video"
        }
    }

    var helpText: String {
        switch self {
        case .newProject:
            "Creates an empty project when recording and file operations are idle."
        case .toggleRecording:
            "Uses the same source selection, permission, and stop flow as the toolbar."
        case .importVideo:
            "Works only when the Import toolbar action is available."
        case .exportVideo:
            "Works only when the selected project can be exported."
        }
    }

    var defaultShortcut: StorybirdShortcut {
        switch self {
        case .newProject:
            StorybirdShortcut(
                keyCode: UInt16(kVK_ANSI_N),
                modifiers: [.command]
            )
        case .toggleRecording:
            StorybirdShortcut(
                keyCode: UInt16(kVK_ANSI_R),
                modifiers: [.command, .shift]
            )
        case .importVideo:
            StorybirdShortcut(
                keyCode: UInt16(kVK_ANSI_I),
                modifiers: [.command, .shift]
            )
        case .exportVideo:
            StorybirdShortcut(
                keyCode: UInt16(kVK_ANSI_E),
                modifiers: [.command, .shift]
            )
        }
    }
}

struct StorybirdShortcut: Hashable, Sendable {
    static let settings = StorybirdShortcut(
        keyCode: UInt16(kVK_ANSI_Comma),
        modifiers: [.command]
    )

    let keyCode: UInt16
    let modifierRawValue: UInt

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        modifierRawValue = modifiers
            .intersection([.command, .option, .shift, .control])
            .rawValue
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierRawValue)
    }

    var isValid: Bool {
        !modifiers.intersection([.command, .option, .control]).isEmpty
    }

    var displayName: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + Self.keyName(for: keyCode)
    }

    /// Compares physical key codes and normalized modifiers so shortcuts keep
    /// working across keyboard layouts and active input methods.
    func matches(_ event: NSEvent) -> Bool {
        keyCode == event.keyCode
            && modifiers == event.modifierFlags.intersection(
                [.command, .option, .shift, .control]
            )
    }

    /// Produces a readable key label without using that label for event
    /// matching, which remains physical-key based.
    private static func keyName(for keyCode: UInt16) -> String {
        if let special = specialKeyNames[UInt32(keyCode)] {
            return special
        }
        if let character = layoutCharacter(for: UInt32(keyCode)) {
            return character.uppercased()
        }
        return "Key \(keyCode)"
    }

    private static let specialKeyNames: [UInt32: String] = [
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "↩",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Escape): "⎋",
        UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞",
        UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12",
    ]

    /// Uses an ASCII-capable layout only for display while matching remains
    /// based on the physical key code delivered by AppKit.
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source =
                TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
                .takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(
                source,
                kTISPropertyUnicodeKeyLayoutData
              )
        else {
            return nil
        }
        let data = Unmanaged<CFData>
            .fromOpaque(pointer)
            .takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?
                    .assumingMemoryBound(to: UCKeyboardLayout.self)
            else {
                return -1
            }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
