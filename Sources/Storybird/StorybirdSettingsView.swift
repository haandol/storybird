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

    private var generalTab: some View {
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
                    Text(store.repository.rootURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Text(
                    "Original recordings, voice references, and timeline layers remain on this Mac until you explicitly export a video."
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
