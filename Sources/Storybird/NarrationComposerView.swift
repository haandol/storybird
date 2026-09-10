import AppKit
import UniformTypeIdentifiers
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
    @State private var showRecorder = false
    @State private var audioError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Generate Speech with TTS") {
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
                    Section("Original Movie Audio") {
                        TextField("Volume", value: Binding(
                            get: { store.selectedProject?.sourceAudioVolume ?? 1 },
                            set: { volume in
                                guard var current = store.selectedProject else { return }
                                current.sourceAudioVolume = volume
                                store.replaceProject(current)
                            }
                        ), format: .number)
                        Toggle("Mute original audio", isOn: Binding(
                            get: { store.selectedProject?.sourceAudioMuted ?? false },
                            set: { muted in
                                guard var current = store.selectedProject else { return }
                                current.sourceAudioMuted = muted
                                store.replaceProject(current)
                            }
                        ))
                    }
                    Section("Audio Assets") {
                        HStack {
                            Button("Import Audio…") { importAudio(projectID: project.id) }
                            Button("Record Voice…") { showRecorder = true }
                        }.disabled(isWorking)
                        Text("WAV, MP3 or M4A. Voice recording is optional; an agent can generate speech from text using an existing profile.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(project.availableAudioAssets) { asset in
                            VStack(alignment: .leading) {
                                Text(asset.name).lineLimit(2)
                                Text(String(format: "%.2f seconds · %@", asset.duration, asset.origin.rawValue))
                                    .font(.caption).foregroundStyle(.secondary)
                                AudioWaveformView(url: store.repository.assetURL(projectID: project.id, filename: asset.filename))
                                    .frame(height: 26)
                                HStack {
                                    Button("Listen") { listenAsset(asset, projectID: project.id) }
                                    Button("Add Layer") {
                                        do {
                                            _ = try store.placeAudioAsset(projectID: project.id, assetID: asset.id,
                                                expectedRevision: project.revision, startTime: narrationStart, timingMode: timingMode)
                                            audioError = nil
                                        } catch { audioError = error.localizedDescription }
                                    }.disabled(isWorking)
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                    Section("TTS Drafts") {
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
                if let audioError { Section { Text(audioError).foregroundStyle(.red) } }
                Section("Voice Settings") {
                    Text("Create voice profiles and prepare the local model in Settings.")
                        .font(.callout).foregroundStyle(.secondary)
                    SettingsLink { Label("Open Settings", systemImage: "gearshape") }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Audio & TTS")
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
        .sheet(isPresented: $showRecorder) {
            if let id = store.selectedProjectID { ProjectAudioRecordingView(store: store, projectID: id) }
        }
    }

    /// Native file selection is optional; agents reuse registered sounds without
    /// receiving a file-picker or arbitrary microphone command.
    private func importAudio(projectID: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do { _ = try await store.importProjectAudio(projectID: projectID, sourceURL: url); audioError = nil }
            catch { audioError = error.localizedDescription }
        }
    }

    /// Auditions only an existing project-owned asset selected by the user.
    private func listenAsset(_ asset: ProjectAudioAsset, projectID: UUID) {
        do {
            player?.stop()
            player = try AVAudioPlayer(contentsOf: store.repository.assetURL(projectID: projectID, filename: asset.filename))
            player?.play()
        } catch { audioError = error.localizedDescription }
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
