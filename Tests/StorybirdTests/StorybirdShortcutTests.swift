import AppKit
import Carbon.HIToolbox
@testable import Storybird
import XCTest

@MainActor
final class StorybirdShortcutTests: XCTestCase {
    private let domain = "storybird.shortcuts.tests"

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: domain)
        super.tearDown()
    }

    func test_defaults_matchApprovedProjectActions() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let settings = StorybirdShortcutSettings(defaults: defaults)

        for action in StorybirdCommandAction.allCases {
            XCTAssertEqual(
                settings.shortcut(for: action),
                action.defaultShortcut
            )
        }
        XCTAssertEqual(
            settings.shortcut(for: .newProject).displayName,
            "⌘N"
        )
        XCTAssertEqual(
            settings.shortcut(for: .toggleRecording).displayName,
            "⇧⌘R"
        )
        XCTAssertEqual(
            settings.shortcut(for: .importVideo).displayName,
            "⇧⌘I"
        )
        XCTAssertEqual(
            settings.shortcut(for: .exportVideo).displayName,
            "⇧⌘E"
        )
    }

    func test_editorDefaults_matchPhysicalKeys() throws {
        let settings = StorybirdShortcutSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: domain)))
        for (action, code, flags): (StorybirdCommandAction, Int, NSEvent.ModifierFlags) in [
            (.splitSelection, kVK_ANSI_B, .command), (.duplicateSelection, kVK_ANSI_D, .command),
            (.undoEdit, kVK_ANSI_Z, .command), (.redoEdit, kVK_ANSI_Z, [.command, .shift]),
        ] {
            XCTAssertTrue(settings.isEnabled(action))
            XCTAssertEqual(settings.shortcut(for: action), StorybirdShortcut(keyCode: UInt16(code), modifiers: flags))
        }
    }

    func test_legacyUserCommandB_preservedWhileNewSplitDefaultStaysDisabledUntilReassigned() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(kVK_ANSI_B, forKey: "newProject.shortcut.keyCode")
        defaults.set(Int(NSEvent.ModifierFlags.command.rawValue), forKey: "newProject.shortcut.modifiers")
        let settings = StorybirdShortcutSettings(defaults: defaults)
        XCTAssertEqual(settings.shortcut(for: .newProject), StorybirdCommandAction.splitSelection.defaultShortcut)
        XCTAssertFalse(settings.isEnabled(.splitSelection))
        XCTAssertNotNil(settings.validationError(for: .splitSelection))
        XCTAssertTrue(settings.displayName(for: .splitSelection).contains("Disabled"))
        settings.update(.newProject, to: StorybirdCommandAction.newProject.defaultShortcut)
        let restored = StorybirdShortcutSettings(defaults: defaults)
        XCTAssertFalse(restored.isEnabled(.splitSelection), "Reopening must not silently activate a disabled new key")
        restored.update(.splitSelection, to: StorybirdCommandAction.splitSelection.defaultShortcut)
        XCTAssertNil(restored.validationError(for: .splitSelection))
        XCTAssertTrue(StorybirdShortcutSettings(defaults: defaults).isEnabled(.splitSelection))
    }

    func test_existingEditorCustomization_loadedBeforeNewEditorDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(kVK_ANSI_B, forKey: "duplicateSelection.shortcut.keyCode")
        defaults.set(Int(NSEvent.ModifierFlags.command.rawValue), forKey: "duplicateSelection.shortcut.modifiers")
        let settings = StorybirdShortcutSettings(defaults: defaults)
        XCTAssertEqual(settings.shortcut(for: .duplicateSelection), StorybirdCommandAction.splitSelection.defaultShortcut)
        XCTAssertFalse(settings.isEnabled(.splitSelection))
        let replacement = StorybirdShortcut(keyCode: UInt16(kVK_ANSI_B), modifiers: [.command, .option])
        settings.update(.splitSelection, to: replacement)
        XCTAssertTrue(settings.isEnabled(.splitSelection))
        let reloaded = StorybirdShortcutSettings(defaults: defaults)
        XCTAssertEqual(reloaded.shortcut(for: .splitSelection), replacement)
        XCTAssertEqual(Set(reloaded.shortcuts.values).count, reloaded.shortcuts.count)
        reloaded.update(.undoEdit, to: replacement)
        XCTAssertEqual(reloaded.shortcut(for: .undoEdit), StorybirdCommandAction.undoEdit.defaultShortcut)
        XCTAssertNotNil(reloaded.validationError(for: .undoEdit))
    }

    func test_corruptedEditorKeys_recoverUniqueDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        for action in StorybirdCommandAction.editorActions {
            defaults.set(-1, forKey: "\(action.rawValue).shortcut.keyCode")
        }
        let settings = StorybirdShortcutSettings(defaults: defaults)
        XCTAssertEqual(Set(settings.shortcuts.values).count, StorybirdCommandAction.allCases.count)
        for action in StorybirdCommandAction.editorActions {
            XCTAssertTrue(settings.isEnabled(action))
            XCTAssertEqual(settings.shortcut(for: action), action.defaultShortcut)
        }
    }

    func test_update_persistsAcrossSettingsInstances() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let first = StorybirdShortcutSettings(defaults: defaults)
        let replacement = StorybirdShortcut(
            keyCode: UInt16(kVK_ANSI_P),
            modifiers: [.command, .option]
        )

        first.update(.newProject, to: replacement)
        let reloaded = StorybirdShortcutSettings(defaults: defaults)

        XCTAssertEqual(
            reloaded.shortcut(for: .newProject),
            replacement
        )
    }

    func test_update_withoutRequiredModifier_preservesPrevious() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let settings = StorybirdShortcutSettings(defaults: defaults)
        let previous = settings.shortcut(for: .importVideo)

        settings.update(
            .importVideo,
            to: StorybirdShortcut(
                keyCode: UInt16(kVK_ANSI_I),
                modifiers: [.shift]
            )
        )

        XCTAssertEqual(settings.shortcut(for: .importVideo), previous)
        XCTAssertNotNil(settings.validationError(for: .importVideo))
    }

    func test_update_duplicateShortcut_preservesPrevious() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let settings = StorybirdShortcutSettings(defaults: defaults)
        let previous = settings.shortcut(for: .exportVideo)

        settings.update(
            .exportVideo,
            to: settings.shortcut(for: .importVideo)
        )

        XCTAssertEqual(settings.shortcut(for: .exportVideo), previous)
        XCTAssertNotNil(settings.validationError(for: .exportVideo))
    }

    func test_update_settingsShortcut_preservesStandardSettingsCommand()
        throws
    {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let settings = StorybirdShortcutSettings(defaults: defaults)
        let previous = settings.shortcut(for: .newProject)

        settings.update(.newProject, to: .settings)

        XCTAssertEqual(settings.shortcut(for: .newProject), previous)
        XCTAssertNotNil(settings.validationError(for: .newProject))
    }

    func test_corruptStoredShortcut_recoversDefault() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(
            Int(kVK_ANSI_N),
            forKey: "newProject.shortcut.keyCode"
        )
        defaults.set(
            Int(NSEvent.ModifierFlags.shift.rawValue),
            forKey: "newProject.shortcut.modifiers"
        )

        let settings = StorybirdShortcutSettings(defaults: defaults)

        XCTAssertEqual(
            settings.shortcut(for: .newProject),
            StorybirdCommandAction.newProject.defaultShortcut
        )
    }

    func test_outOfRangeStoredShortcut_recoversDefaultsWithoutTrap()
        throws
    {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(
            -1,
            forKey: "newProject.shortcut.keyCode"
        )
        defaults.set(
            70_000,
            forKey: "toggleRecording.shortcut.keyCode"
        )
        defaults.set(
            -1,
            forKey: "importVideo.shortcut.modifiers"
        )
        defaults.set(
            Int(1) << 55,
            forKey: "exportVideo.shortcut.modifiers"
        )

        let settings = StorybirdShortcutSettings(defaults: defaults)

        for action in StorybirdCommandAction.allCases {
            XCTAssertEqual(
                settings.shortcut(for: action),
                action.defaultShortcut
            )
        }
    }

    func test_commandCenter_disabledActionDoesNotPerform() {
        let center = StorybirdCommandCenter()
        let ownerID = UUID()
        var performed = false
        center.install(
            ownerID: ownerID,
            handlers: [
                .exportVideo: .init(
                    isEnabled: { false },
                    perform: { performed = true }
                ),
            ]
        )

        XCTAssertFalse(center.perform(.exportVideo))
        XCTAssertFalse(performed)
    }

    func test_actionMatching_usesPhysicalKeyAndStopsDuringCapture()
        throws
    {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let settings = StorybirdShortcutSettings(defaults: defaults)
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "r",
                charactersIgnoringModifiers: "r",
                isARepeat: false,
                keyCode: UInt16(kVK_ANSI_R)
            )
        )

        XCTAssertEqual(
            settings.action(matching: event),
            .toggleRecording
        )

        settings.recordingAction = .newProject
        XCTAssertNil(settings.action(matching: event))
    }

    func test_commandCenter_enabledActionPerformsOnce() {
        let center = StorybirdCommandCenter()
        var count = 0
        center.install(
            ownerID: UUID(),
            handlers: [
                .newProject: .init(
                    isEnabled: { true },
                    perform: { count += 1 }
                ),
            ]
        )

        XCTAssertTrue(center.perform(.newProject))
        XCTAssertEqual(count, 1)
    }
}
