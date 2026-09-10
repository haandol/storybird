import AVFAudio
import StorybirdCore
import SwiftUI

struct NarrationComposerView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProfileID: UUID?
    @State private var narrationText = ""
    @State private var narrationStart = 0.0
    @State private var language: VoiceLanguage = .korean
    @State private var timingMode: LayerTimingMode = .scene
    @State private var isWorking = false
    @State private var player: AVAudioPlayer?

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
                    Picker("Language", selection: $language) {
                        ForEach(VoiceLanguage.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    TextField("Narration text", text: $narrationText, axis: .vertical)
                        .lineLimit(4)
                    Button("Generate Draft") { generateDraft() }
                        .disabled(!canGenerate)
                    Text("Generate first, check the duration, then place the sentence. A timing conflict keeps the draft.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Placement") {
                    TextField("Start time", value: $narrationStart, format: .number)
                    Picker("Timing", selection: $timingMode) {
                        Text("Follow scene").tag(LayerTimingMode.scene)
                        Text("Fixed project time").tag(LayerTimingMode.project)
                    }
                }
                if let project = store.selectedProject {
                    Section("Narration Drafts") {
                        ForEach(project.narrationDrafts.filter { $0.state != .placed && $0.state != .cancelled }) { draft in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(draft.text).lineLimit(3)
                                Text(draft.state.rawValue.capitalized + " · " + draft.language)
                                    .font(.caption).foregroundStyle(.secondary)
                                if let duration = draft.duration {
                                    Text(String(format: "%.2f seconds", duration)).font(.caption)
                                }
                                if let error = draft.error { Text(error).font(.caption).foregroundStyle(.red) }
                                HStack {
                                    if draft.state == .ready {
                                        Button("Listen") { preview(draft, projectID: project.id) }
                                        Button("Place at Start Time") { place(draft, project: project) }
                                            .disabled(isWorking)
                                    }
                                    if draft.state == .ready || draft.state == .generating {
                                        Button(draft.state == .ready ? "Discard" : "Cancel") {
                                            do { try store.cancelNarrationDraft(projectID: project.id, draftID: draft.id) }
                                            catch { store.errorMessage = error.localizedDescription }
                                        }
                                    }
                                }
                            }.padding(.vertical, 5)
                        }
                    }
                }
                Section("Voice Settings") {
                    Text("Create voice profiles and prepare the local model in Settings.")
                        .font(.callout).foregroundStyle(.secondary)
                    SettingsLink { Label("Open Settings", systemImage: "gearshape") }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Narration")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(isWorking)
                }
            }
        }
        .frame(width: 560, height: 560)
        .task {
            await store.refreshVoiceRuntimeState()
            selectedProfileID = selectedProfileID ?? store.voiceProfiles.first?.id
            if let project = store.selectedProject,
               (try? SceneTiming.anchor(at: narrationStart, in: project)) == nil { timingMode = .project }
        }
        .onDisappear { player?.stop() }
    }

    private var canGenerate: Bool {
        !isWorking && store.voiceRuntimeState == .ready && store.selectedProject?.recording != nil
            && selectedProfileID != nil && !narrationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Starts a project-owned job that continues when this sheet closes.
    private func generateDraft() {
        guard let project = store.selectedProject, let selectedProfileID else { return }
        do {
            _ = try store.startNarrationDraft(
                projectID: project.id, voiceProfileID: selectedProfileID,
                text: narrationText, language: language.rawValue
            )
            narrationText = ""
        } catch { store.errorMessage = error.localizedDescription }
    }

    /// Uses the displayed revision and preserves the draft if placement fails.
    private func place(_ draft: NarrationDraft, project: DemoProject) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await store.placeNarrationDraft(
                    projectID: project.id, draftID: draft.id, expectedRevision: project.revision,
                    startTime: narrationStart, timingMode: timingMode
                )
            } catch { store.errorMessage = error.localizedDescription }
        }
    }

    /// Plays only a ready project-owned WAV after the user's explicit request.
    private func preview(_ draft: NarrationDraft, projectID: UUID) {
        do {
            player?.stop()
            player = try AVAudioPlayer(contentsOf: store.repository.assetURL(projectID: projectID, filename: draft.filename))
            player?.play()
        } catch { store.errorMessage = error.localizedDescription }
    }
}
