import AppKit
import AVFAudio
import StorybirdCore
import SwiftUI
import UniformTypeIdentifiers

struct TimelineAudioPanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var model: TimelineAudioModel
    let projectID: UUID
    let playhead: Double
    @State private var profileID: UUID?
    @State private var text = ""
    @State private var language: VoiceLanguage = .korean
    @State private var showGenerator = false
    @State private var showRecorder = false
    @State private var isImporting = false
    @State private var player: AVAudioPlayer?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Project audio", systemImage: "waveform").font(.headline)
                HStack {
                    Button { importAudio() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                        .accessibilityIdentifier("timeline-audio-import")
                    Button { showRecorder = true } label: { Label("Record", systemImage: "mic") }
                }
                .disabled(isImporting || model.isPlacing)
                DisclosureGroup("Generate speech", isExpanded: $showGenerator) {
                    generator.padding(.top, 8)
                }
                if let project = store.project(id: projectID) {
                    ForEach(project.narrationDrafts.filter { $0.state != .placed && $0.state != .cancelled }) { draft in
                        draftCard(draft, project: project)
                    }
                    ForEach(project.availableAudioAssets) { asset in
                        soundCard(
                            title: asset.name, duration: asset.duration, filename: asset.filename,
                            itemID: asset.id, kind: .asset, project: project
                        )
                    }
                    if project.availableAudioAssets.isEmpty && project.narrationDrafts.isEmpty {
                        ContentUnavailableView("Add your first sound", systemImage: "waveform",
                            description: Text("Import a file, record your voice, or generate speech."))
                    }
                }
                Text("Drag a sound onto Audio, or add it at \(playhead, format: .number.precision(.fractionLength(2)))s.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Placement", selection: $model.timingMode) {
                    Text("Follow scene").tag(LayerTimingMode.scene)
                    Text("Fixed time").tag(LayerTimingMode.project)
                }
                .font(.caption)
                if let error = errorMessage ?? model.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red)
                        .accessibilityIdentifier("timeline-audio-error")
                }
                SettingsLink { Label("Voice settings", systemImage: "gearshape") }
                    .font(.caption)
            }
            .padding(12)
        }
        .accessibilityIdentifier("timeline-audio-panel")
        .task {
            await store.refreshVoiceRuntimeState()
            profileID = profileID ?? store.voiceProfiles.first?.id
        }
        .sheet(isPresented: $showRecorder) { ProjectAudioRecordingView(store: store, projectID: projectID) }
        .onDisappear { player?.stop() }
    }

    private var generator: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Voice", selection: $profileID) {
                Text("Choose a voice").tag(UUID?.none)
                ForEach(store.voiceProfiles) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Language", selection: $language) {
                ForEach(VoiceLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            TextField("What should the narrator say?", text: $text, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
            Button("Generate audio") {
                guard let profileID else { return }
                do {
                    _ = try store.startNarrationDraft(
                        projectID: projectID, voiceProfileID: profileID, text: text, language: language.rawValue
                    )
                    text = ""
                    errorMessage = nil
                } catch { errorMessage = error.localizedDescription }
            }
            .disabled(profileID == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || store.voiceRuntimeState != .ready)
            if store.voiceRuntimeState != .ready {
                Text("Prepare the voice model in Settings first.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// A ready card shows the real waveform and supports both dragging and
    /// playhead placement through the same revision-checked operation.
    private func soundCard(
        title: String, duration: Double, filename: String, itemID: UUID,
        kind: TimelineAudioReference.Kind, project: DemoProject
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.callout.weight(.medium)).lineLimit(2)
                Spacer(minLength: 4)
                Text(duration, format: .number.precision(.fractionLength(1))) + Text("s")
            }
            AudioWaveformView(url: store.repository.assetURL(projectID: projectID, filename: filename))
                .frame(height: 28)
            HStack {
                Button { listen(filename) } label: { Label("Listen", systemImage: "play.fill") }
                Spacer(minLength: 0)
                Button {
                    let reference = TimelineAudioReference(
                        projectID: projectID, itemID: itemID, kind: kind, revision: project.revision, token: UUID()
                    )
                    player?.stop()
                    Task { await model.place(reference, at: playhead, in: store) }
                } label: { Label("Add", systemImage: "plus") }
                .help("Add at playhead")
                .accessibilityIdentifier("timeline-audio-add-\(itemID)")
                .disabled(model.isPlacing)
            }
            .font(.caption)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onDrag {
            player?.stop()
            return model.beginDrag(itemID: itemID, kind: kind, project: project)
        }
        .accessibilityIdentifier("timeline-audio-card-\(itemID)")
    }

    /// Incomplete jobs remain visible but never become draggable audio.
    @ViewBuilder
    private func draftCard(_ draft: NarrationDraft, project: DemoProject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if draft.state == .ready, let duration = draft.duration {
                soundCard(title: draft.text, duration: duration, filename: draft.filename,
                    itemID: draft.id, kind: .draft, project: project)
            } else {
                HStack {
                    if draft.state == .generating { ProgressView().controlSize(.small) }
                    Text(draft.state.rawValue.capitalized).font(.caption)
                }
                Text(draft.text).lineLimit(2)
                if let error = draft.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            if draft.state == .ready || draft.state == .generating {
                Button(draft.state == .ready ? "Discard draft" : "Cancel generation") {
                    do { try store.cancelNarrationDraft(projectID: projectID, draftID: draft.id) }
                    catch { errorMessage = error.localizedDescription }
                }
                .font(.caption)
                .disabled(model.isPlacing)
            }
        }
    }

    /// Opens file selection only from a native button and registers a complete
    /// project-owned asset before presenting it for placement.
    private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                _ = try await store.importProjectAudio(projectID: projectID, sourceURL: url)
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Auditions only project-owned media selected by the user.
    private func listen(_ filename: String) {
        do {
            player?.stop()
            player = try AVAudioPlayer(contentsOf: store.repository.assetURL(projectID: projectID, filename: filename))
            player?.play()
        } catch { errorMessage = error.localizedDescription }
    }
}
