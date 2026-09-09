import AppKit
import Combine
import Foundation

@MainActor
final class StorybirdShortcutSettings: ObservableObject {
    @Published private(set) var shortcuts: [
        StorybirdCommandAction: StorybirdShortcut
    ]
    @Published private(set) var validationErrors: [
        StorybirdCommandAction: String
    ] = [:]
    @Published var recordingAction: StorybirdCommandAction?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcuts = Self.loadShortcuts(from: defaults)
    }

    var isRecordingShortcut: Bool {
        recordingAction != nil
    }

    func shortcut(
        for action: StorybirdCommandAction
    ) -> StorybirdShortcut {
        shortcuts[action] ?? action.defaultShortcut
    }

    /// Exposes a rejected-edit explanation next to the affected field while
    /// unrelated working shortcuts remain unchanged.
    func validationError(
        for action: StorybirdCommandAction
    ) -> String? {
        validationErrors[action]
    }

    /// Saves one valid, unique local shortcut while preserving the previous
    /// working value and explaining any rejected change.
    func update(
        _ action: StorybirdCommandAction,
        to shortcut: StorybirdShortcut
    ) {
        guard shortcut.isValid else {
            validationErrors[action] =
                "Include Command, Option, or Control."
            return
        }
        guard shortcut != .settings else {
            validationErrors[action] =
                "⌘, is reserved for the standard Open Settings command."
            return
        }
        guard !shortcuts.contains(where: {
            $0.key != action && $0.value == shortcut
        }) else {
            validationErrors[action] =
                "Another Storybird action already uses this shortcut."
            return
        }
        shortcuts[action] = shortcut
        validationErrors[action] = nil
        Self.save(shortcut, for: action, to: defaults)
    }

    /// Finds a local action only when no settings field is capturing a new
    /// combination, preventing shortcut editing from triggering app work.
    func action(matching event: NSEvent) -> StorybirdCommandAction? {
        guard !isRecordingShortcut, !event.isARepeat else { return nil }
        return StorybirdCommandAction.allCases.first {
            shortcut(for: $0).matches(event)
        }
    }

    /// Loads all actions as one set and repairs invalid or duplicate persisted
    /// values until every action has one unique working shortcut.
    private static func loadShortcuts(
        from defaults: UserDefaults
    ) -> [StorybirdCommandAction: StorybirdShortcut] {
        var loaded = Dictionary(
            uniqueKeysWithValues: StorybirdCommandAction.allCases.map {
                ($0, load($0, from: defaults) ?? $0.defaultShortcut)
            }
        )
        while true {
            let duplicateGroups = Dictionary(grouping: loaded.keys) {
                loaded[$0] ?? $0.defaultShortcut
            }
            let duplicates = duplicateGroups.values.filter {
                $0.count > 1
            }
            guard !duplicates.isEmpty else { break }
            var changed = false
            for group in duplicates {
                for action in group
                    where loaded[action] != action.defaultShortcut {
                    loaded[action] = action.defaultShortcut
                    changed = true
                }
            }
            guard changed else {
                return Dictionary(
                    uniqueKeysWithValues:
                        StorybirdCommandAction.allCases.map {
                            ($0, $0.defaultShortcut)
                        }
                )
            }
        }
        return loaded
    }

    /// Reads one stored scalar pair and rejects corruption before it can become
    /// an active application shortcut.
    private static func load(
        _ action: StorybirdCommandAction,
        from defaults: UserDefaults
    ) -> StorybirdShortcut? {
        let keyCodeKey = "\(action.rawValue).shortcut.keyCode"
        let modifiersKey = "\(action.rawValue).shortcut.modifiers"
        guard defaults.object(forKey: keyCodeKey) != nil else {
            return nil
        }
        let rawKeyCode = defaults.integer(forKey: keyCodeKey)
        let rawModifiers = defaults.integer(forKey: modifiersKey)
        guard let keyCode = UInt16(exactly: rawKeyCode),
              let modifierRawValue = UInt(exactly: rawModifiers)
        else {
            return nil
        }
        let allowedModifiers: NSEvent.ModifierFlags = [
            .command, .option, .shift, .control,
        ]
        guard modifierRawValue & ~allowedModifiers.rawValue == 0 else {
            return nil
        }
        let shortcut = StorybirdShortcut(
            keyCode: keyCode,
            modifiers: NSEvent.ModifierFlags(
                rawValue: modifierRawValue
            )
        )
        return shortcut.isValid && shortcut != .settings ? shortcut : nil
    }

    /// Persists only a validated shortcut after uniqueness and reserved-key
    /// checks have succeeded.
    private static func save(
        _ shortcut: StorybirdShortcut,
        for action: StorybirdCommandAction,
        to defaults: UserDefaults
    ) {
        defaults.set(
            Int(shortcut.keyCode),
            forKey: "\(action.rawValue).shortcut.keyCode"
        )
        defaults.set(
            Int(shortcut.modifierRawValue),
            forKey: "\(action.rawValue).shortcut.modifiers"
        )
    }
}
