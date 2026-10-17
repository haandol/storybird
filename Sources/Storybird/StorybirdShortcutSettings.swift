import AppKit
import Combine
import Foundation
import SwiftUI

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
        let loaded = Self.loadShortcuts(from: defaults)
        shortcuts = loaded.shortcuts
        validationErrors = loaded.errors
    }

    var isRecordingShortcut: Bool {
        recordingAction != nil
    }

    func shortcut(
        for action: StorybirdCommandAction
    ) -> StorybirdShortcut {
        shortcuts[action] ?? action.defaultShortcut
    }

    func isEnabled(_ action: StorybirdCommandAction) -> Bool { shortcuts[action] != nil }

    func displayName(for action: StorybirdCommandAction) -> String {
        isEnabled(action) ? shortcut(for: action).displayName : "Disabled · " + action.defaultShortcut.displayName
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
        defaults.removeObject(forKey: "\(action.rawValue).shortcut.disabled")
        Self.save(shortcut, for: action, to: defaults)
    }

    /// Finds a local action only when no settings field is capturing a new
    /// combination, preventing shortcut editing from triggering app work.
    func action(matching event: NSEvent) -> StorybirdCommandAction? {
        guard !isRecordingShortcut, !event.isARepeat else { return nil }
        return StorybirdCommandAction.allCases.first {
            shortcuts[$0]?.matches(event) == true
        }
    }

    /// Keeps the established project-key repair rules, then adds editor keys
    /// without replacing valid existing choices. A conflicting new default stays
    /// disabled until the user assigns that editor action a valid combination.
    private static func loadShortcuts(from defaults: UserDefaults) -> (shortcuts: [StorybirdCommandAction: StorybirdShortcut], errors: [StorybirdCommandAction: String]) {
        var loaded = loadProjectShortcuts(from: defaults)
        var errors: [StorybirdCommandAction: String] = [:]
        let editors = StorybirdCommandAction.editorActions
        let stored = Dictionary(uniqueKeysWithValues: editors.compactMap { action in load(action, from: defaults).map { (action, $0) } })
        let duplicated = Set(Dictionary(grouping: stored.keys) { stored[$0]! }.values.filter { $0.count > 1 }.flatMap { $0 })
        for action in editors where !defaults.bool(forKey: "\(action.rawValue).shortcut.disabled") {
            if let value = stored[action], !duplicated.contains(action), !loaded.values.contains(value) { loaded[action] = value }
        }
        for action in editors where loaded[action] == nil {
            let disabledKey = "\(action.rawValue).shortcut.disabled"
            if !defaults.bool(forKey: disabledKey), !loaded.values.contains(action.defaultShortcut) {
                loaded[action] = action.defaultShortcut
            } else {
                defaults.set(true, forKey: disabledKey)
                errors[action] = "Disabled: choose an unused shortcut for this editor action. Existing shortcuts were preserved."
            }
        }
        return (loaded, errors)
    }

    private static func loadProjectShortcuts(from defaults: UserDefaults) -> [StorybirdCommandAction: StorybirdShortcut] {
        let actions = StorybirdCommandAction.projectActions
        var loaded = Dictionary(
            uniqueKeysWithValues: actions.map {
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
                        actions.map {
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

private struct StorybirdShortcutEnvironmentKey: EnvironmentKey {
    static let defaultValue: StorybirdShortcutSettings? = nil
}

extension EnvironmentValues {
    var storybirdShortcuts: StorybirdShortcutSettings? {
        get { self[StorybirdShortcutEnvironmentKey.self] }
        set { self[StorybirdShortcutEnvironmentKey.self] = newValue }
    }
}
