import AVFoundation
import AppKit
import StorybirdCore
import SwiftUI

@MainActor
final class VoiceSampleRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var recordedURL: URL?
    @Published private(set) var errorMessage: String?
    private var recorder: AVAudioRecorder?

    /// Requests microphone access only for this explicit recording action and
    /// starts one local mono WAV when permission is available.
    func start() async throws {
        errorMessage = nil
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let allowed: Bool
        switch status {
        case .authorized:
            allowed = true
        case .notDetermined:
            allowed = await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            allowed = false
        @unknown default:
            allowed = false
        }
        guard allowed else {
            errorMessage =
                "Enable Storybird in System Settings › Privacy & Security › Microphone."
            throw VoiceProfileError.microphonePermissionDenied
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("storybird-voice-\(UUID().uuidString).wav")
        let recorder = try AVAudioRecorder(
            url: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
        )
        recorder.delegate = self
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw VoiceProfileError.invalidInput
        }
        self.recorder = recorder
        recordedURL = nil
        isRecording = true
    }

    /// Stops the active recorder and exposes its complete temporary WAV for
    /// preview or profile validation.
    func stop() {
        guard let recorder else { return }
        recorder.stop()
        recordedURL = recorder.url
        isRecording = false
        self.recorder = nil
    }

    /// Removes the temporary microphone sample so an abandoned recording never
    /// becomes profile data.
    func discard() {
        stop()
        if let recordedURL {
            try? FileManager.default.removeItem(at: recordedURL)
        }
        recordedURL = nil
    }
}

struct VoiceStudioView: View {
    static let recordingPrompt =
        "안녕하세요. 저는 Storybird로 서비스의 중요한 기능과 사용 방법을 차분하게 설명하고 있습니다."

    @ObservedObject var store: AppStore
    @StateObject private var recorder = VoiceSampleRecorder()
    @Environment(\.dismiss) private var dismiss

    @State private var profileName = "My voice"
    @State private var transcript = ""
    @State private var consentConfirmed = false
    @State private var narrationText = ""
    @State private var narrationStart = 0.0
    @State private var selectedProfileID: UUID?
    @State private var isWorking = false
    @State private var showPrepareConfirmation = false
    @State private var profilePendingDeletion: UUID?

    var body: some View {
        NavigationStack {
            Form {
                runtimeSection
                profileCreationSection
                profilesSection
                narrationSection
            }
            .formStyle(.grouped)
            .navigationTitle("Voice Narration")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 620, height: 720)
        .confirmationDialog(
            "Prepare the local voice model?",
            isPresented: $showPrepareConfirmation
        ) {
            Button("Download and Prepare") {
                isWorking = true
                Task {
                    await store.prepareVoiceRuntime()
                    isWorking = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Storybird will install a local MLX runtime and download the approximately 2 GB Qwen3-TTS 1.7B Base 8-bit model. Voice synthesis stays on this Mac afterward.")
        }
        .task {
            await store.refreshVoiceRuntimeState()
        }
        .confirmationDialog(
            "Delete this voice profile?",
            isPresented: Binding(
                get: { profilePendingDeletion != nil },
                set: { if !$0 { profilePendingDeletion = nil } }
            )
        ) {
            Button("Delete Profile", role: .destructive) {
                guard let id = profilePendingDeletion else { return }
                do {
                    try store.deleteVoiceProfile(id: id)
                } catch {
                    store.errorMessage = error.localizedDescription
                }
                profilePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The reference audio and transcript will be removed. Existing project narration remains.")
        }
    }

    private var runtimeSection: some View {
        Section("Local MLX Model") {
            LabeledContent("Model") {
                Text("Qwen3-TTS 1.7B Base 8-bit")
            }
            LabeledContent("Status") {
                Text(runtimeStatus)
            }
            Button("Prepare Model") {
                showPrepareConfirmation = true
            }
            .disabled(isWorking || store.voiceRuntimeState == .ready)
        }
    }

    private var profileCreationSection: some View {
        Section("Create Voice Profile") {
            TextField("Profile name", text: $profileName)
            TextField("Exact reference transcript", text: $transcript, axis: .vertical)
                .lineLimit(3)
            Toggle(
                "I own this voice or have permission to use it",
                isOn: $consentConfirmed
            )
            HStack {
                Button("Import MP3/WAV") { importReference() }
                if recorder.isRecording {
                    Button("Stop Recording", role: .destructive) {
                        recorder.stop()
                        transcript = Self.recordingPrompt
                    }
                } else {
                    Button("Record Prompt") {
                        transcript = Self.recordingPrompt
                        Task {
                            do {
                                try await recorder.start()
                            } catch {
                                store.errorMessage = error.localizedDescription
                            }
                        }
                    }
                }
            }
            Text(Self.recordingPrompt)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorMessage = recorder.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let recordedURL = recorder.recordedURL {
                HStack {
                    Button("Preview Recording") {
                        NSWorkspace.shared.open(recordedURL)
                    }
                    Button("Save Recording as Profile") {
                        createProfile(
                            from: recordedURL,
                            transcriptOverride: Self.recordingPrompt,
                            source: .microphone
                        )
                    }
                    Button("Discard", role: .destructive) {
                        recorder.discard()
                    }
                }
            }
        }
    }

    private var profilesSection: some View {
        Section("Voice Profiles") {
            if store.voiceProfiles.isEmpty {
                Text("No voice profiles yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.voiceProfiles) { profile in
                HStack {
                    VStack(alignment: .leading) {
                        Text(profile.name)
                        Text(profile.language)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(
                            store.repository.voiceReferenceURL(
                                profileID: profile.id,
                                filename: profile.referenceFilename
                            )
                        )
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless)
                    Button(role: .destructive) {
                        profilePendingDeletion = profile.id
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var narrationSection: some View {
        Section("Generate Project Narration") {
            Picker("Voice", selection: $selectedProfileID) {
                Text("Choose a profile").tag(UUID?.none)
                ForEach(store.voiceProfiles) {
                    Text($0.name).tag(Optional($0.id))
                }
            }
            TextField("Narration text", text: $narrationText, axis: .vertical)
                .lineLimit(4)
            TextField("Start time", value: $narrationStart, format: .number)
            Button("Generate at Project Time") {
                generateNarration()
            }
            .disabled(
                isWorking
                    || store.voiceRuntimeState != .ready
                    || store.selectedProject == nil
                    || selectedProfileID == nil
                    || narrationText.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
            )
        }
    }

    private var runtimeStatus: String {
        switch store.voiceRuntimeState {
        case .notPrepared: "Not prepared"
        case .preparing: "Preparing…"
        case .ready: "Ready"
        case let .failed(message): "Failed: \(message)"
        }
    }

    /// Lets the user explicitly select one supported local reference file before
    /// profile validation copies it into Storybird-owned storage.
    private func importReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .audio,
            .mp3,
            .wav,
        ]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        createProfile(from: url)
    }

    /// Sends imported references with the user's exact transcript, while guided
    /// recordings always keep the fixed prompt they were recorded against.
    private func createProfile(
        from url: URL,
        transcriptOverride: String? = nil,
        source: VoiceReferenceSource = .importedFile
    ) {
        isWorking = true
        Task {
            do {
                let profile = try await store.importVoiceProfile(
                    name: profileName,
                    sourceURL: url,
                    transcript: transcriptOverride ?? transcript,
                    source: source,
                    consentConfirmed: consentConfirmed
                )
                selectedProfileID = profile.id
                recorder.discard()
            } catch {
                store.errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    /// Generates one narration at the selected project time using only the
    /// existing consented profile chosen in the native UI.
    private func generateNarration() {
        guard let project = store.selectedProject,
              let selectedProfileID else { return }
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
