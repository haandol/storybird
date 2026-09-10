import AppKit
import SwiftUI

struct StorybirdSettingsView: View {
    enum Pane: Hashable {
        case general
        case voice
        case shortcuts
    }

    @ObservedObject var store: AppStore
    @ObservedObject var shortcutSettings: StorybirdShortcutSettings
    @State private var pane: Pane
    @State private var folderOpenError: String?

    init(
        store: AppStore,
        shortcutSettings: StorybirdShortcutSettings,
        initialPane: Pane = .general
    ) {
        self.store = store
        self.shortcutSettings = shortcutSettings
        _pane = State(initialValue: initialPane)
    }

    var body: some View {
        TabView(selection: $pane) {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(Pane.general)

            VoiceStudioView(store: store)
                .tabItem {
                    Label("Voice", systemImage: "waveform.and.mic")
                }
                .tag(Pane.voice)

            shortcutsTab
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
                .tag(Pane.shortcuts)
        }
        .frame(width: 680, height: 720)
    }

    var generalTab: some View {
        Form {
            Section("Storybird") {
                HStack(spacing: 12) {
                    StorybirdMark(size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Storybird")
                            .font(.title2.weight(.semibold))
                        Text("Local-first screen videos")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Storage") {
                LabeledContent("Project library") {
                    HStack {
                        Text(store.repository.rootURL.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(store.repository.rootURL.path)
                        Button("Open in Finder") {
                            folderOpenError = NSWorkspace.shared.open(store.repository.rootURL)
                                ? nil
                                : "The folder could not be opened. Check that it is connected and accessible."
                        }
                        .buttonStyle(.link)
                    }
                }
                HStack {
                    Button("Choose Folder…") { chooseProjectFolder() }
                    Button("Use Default") {
                        folderOpenError = nil
                        store.chooseStorageFolder(nil)
                    }
                    .disabled(store.selectedStorageRootURL == nil)
                }
                .disabled(store.storageChangeDisabledReason != nil)

                if let reason = store.storageChangeDisabledReason {
                    Label(reason, systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = folderOpenError ?? store.storageErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(
                    "This folder holds its own project library, original videos, and narration. Existing files are not moved. Choose a previous folder again to see its projects."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Text(
                    "Shared voice profiles and the voice model stay in Application Support/Storybird. If a sync service manages your project folder, that service controls synchronization."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text(
                    "Screen recording never captures microphone or keyboard input. The microphone is used only while you explicitly record a guided voice-profile sample."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Uses the native folder picker as the only custom-location entry point.
    /// The store rechecks activity and validates the library after the panel closes.
    private func chooseProjectFolder() {
        guard store.storageChangeDisabledReason == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Project Folder"
        panel.message = "Open the project library in this folder. Existing projects will stay in their previous folder."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.repository.rootURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderOpenError = nil
        store.chooseStorageFolder(url)
    }

    private var shortcutsTab: some View {
        Form {
            Section("Project Actions") {
                ForEach(StorybirdCommandAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(action.title) {
                            StorybirdShortcutField(
                                settings: shortcutSettings,
                                action: action
                            )
                        }
                        if let error = shortcutSettings.validationError(
                            for: action
                        ) {
                            Label(
                                error,
                                systemImage: "keyboard.badge.exclamationmark"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        } else {
                            Text(action.helpText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Scope") {
                Text(
                    "These shortcuts work only while Storybird is active. They use the same availability, permission, and confirmation rules as the corresponding controls."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                LabeledContent("Open Settings") {
                    Text("⌘,")
                        .monospaced()
                }
                Text(
                    "The standard macOS Settings shortcut remains fixed."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
