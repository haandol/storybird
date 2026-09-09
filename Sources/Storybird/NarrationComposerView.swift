import SwiftUI

struct NarrationComposerView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProfileID: UUID?
    @State private var narrationText = ""
    @State private var narrationStart = 0.0
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Project Narration") {
                    Picker("Voice", selection: $selectedProfileID) {
                        Text("Choose a profile").tag(UUID?.none)
                        ForEach(store.voiceProfiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    TextField(
                        "Narration text",
                        text: $narrationText,
                        axis: .vertical
                    )
                    .lineLimit(4)
                    TextField(
                        "Start time",
                        value: $narrationStart,
                        format: .number
                    )
                    Button("Generate at Project Time") {
                        generateNarration()
                    }
                    .disabled(!canGenerate)
                }

                Section("Voice Settings") {
                    Text(
                        "Prepare the model, create or delete profiles, and choose the guided-recording microphone in Storybird Settings."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    SettingsLink {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Narration")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isWorking)
                }
            }
        }
        .frame(width: 520, height: 430)
        .task {
            await store.refreshVoiceRuntimeState()
            if selectedProfileID == nil {
                selectedProfileID = store.voiceProfiles.first?.id
            }
        }
    }

    private var canGenerate: Bool {
        !isWorking
            && store.voiceRuntimeState == .ready
            && store.selectedProject != nil
            && selectedProfileID != nil
            && !narrationText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
    }

    /// Generates only project-owned narration from an existing profile, keeping
    /// model preparation, profile mutation, and microphone access in Settings.
    private func generateNarration() {
        guard let project = store.selectedProject,
              let selectedProfileID
        else {
            return
        }
        isWorking = true
        Task {
            do {
                _ = try await store.generateNarration(
                    projectID: project.id,
                    expectedRevision: project.revision,
                    voiceProfileID: selectedProfileID,
                    text: narrationText,
                    language: "korean",
                    startTime: narrationStart
                )
                narrationText = ""
            } catch {
                store.errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
