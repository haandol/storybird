import AVFoundation
import AppKit
import StorybirdCore
import SwiftUI

enum VoiceRecordingRequirements {
    static let minimumDuration = 10.0
}

enum VoiceRecordingPresentation {
    /// Converts recorder decibels into a stable 0...1 visual level while
    /// treating room noise below -50 dB as silence.
    static func normalizedLevel(decibels: Float) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(max(Double((decibels + 50) / 50), 0), 1)
    }

    /// Reports the contract-relevant time still needed before a guided sample
    /// may be finalized and saved as a voice profile.
    static func remainingDuration(elapsed: Double) -> Double {
        let remaining = max(
            VoiceRecordingRequirements.minimumDuration - elapsed,
            0
        )
        guard remaining > 0 else { return 0 }
        return (remaining * 10).rounded(.up) / 10
    }

    /// Formats a recording clock consistently for the live and completed
    /// states without implying that fractional seconds satisfy the boundary.
    static func formattedDuration(_ duration: Double) -> String {
        let totalTenths = max(Int((duration * 10).rounded(.down)), 0)
        let minutes = totalTenths / 600
        let seconds = (totalTenths % 600) / 10
        let tenths = totalTenths % 10
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }
}

enum VoiceInputPermissionPolicy {
    /// Allows sensitive file or microphone access only after voice-use consent
    /// and while no existing recording or save operation owns the input flow.
    static func canStart(
        consentConfirmed: Bool,
        hasSession: Bool,
        isWorking: Bool
    ) -> Bool {
        consentConfirmed && !hasSession && !isWorking
    }

    /// Keeps the consent decision stable while a recording or profile write is
    /// active so permission cannot be withdrawn halfway through an input flow.
    static func consentIsLocked(
        hasSession: Bool,
        isWorking: Bool
    ) -> Bool {
        hasSession || isWorking
    }

    /// Allows an existing temporary sample to be replaced after consent while
    /// preventing a concurrent profile write from starting another recorder.
    static func canRestart(
        consentConfirmed: Bool,
        isWorking: Bool
    ) -> Bool {
        consentConfirmed && !isWorking
    }
}

@MainActor
final class VoiceSampleRecorder:
    ObservableObject
{
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var recordedURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var elapsedTime = 0.0
    @Published private(set) var levelSamples = Array(
        repeating: 0.0,
        count: 32
    )
    private var recorder: AVAudioRecorder?
    private var meteringTask: Task<Void, Never>?

    var hasSession: Bool {
        recorder != nil || recordedURL != nil
    }

    var canFinish: Bool {
        elapsedTime >= VoiceRecordingRequirements.minimumDuration
    }

    /// Requests microphone access only for this explicit recording action and
    /// starts one metered local mono WAV when permission is available.
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
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw VoiceProfileError.invalidInput
        }
        self.recorder = recorder
        recordedURL = nil
        elapsedTime = 0
        levelSamples = Array(repeating: 0, count: levelSamples.count)
        isPaused = false
        isRecording = true
        startMetering()
    }

    /// Pauses without finalizing the WAV so a user below the ten-second minimum
    /// can continue the same guided recording.
    func pause() {
        guard let recorder, isRecording else { return }
        captureMeterSample()
        recorder.pause()
        stopMetering()
        isPaused = true
        isRecording = false
    }

    /// Continues the same temporary WAV after a pause, preserving elapsed time
    /// and the minimum-duration boundary.
    func resume() throws {
        guard let recorder, isPaused, recorder.record() else {
            throw VoiceProfileError.invalidInput
        }
        isPaused = false
        isRecording = true
        startMetering()
    }

    /// Finalizes only a sample that has reached ten seconds and exposes its WAV
    /// for preview, rerecording, or profile validation.
    @discardableResult
    func finish() -> Bool {
        guard let recorder, canFinish else { return false }
        captureMeterSample()
        stopMetering()
        recorder.stop()
        recordedURL = recorder.url
        isRecording = false
        isPaused = false
        self.recorder = nil
        return true
    }

    /// Removes the temporary microphone sample so an abandoned recording never
    /// becomes profile data.
    func discard() {
        stopMetering()
        let url = recorder?.url ?? recordedURL
        recorder?.stop()
        recorder = nil
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        isRecording = false
        isPaused = false
        recordedURL = nil
        elapsedTime = 0
        levelSamples = Array(repeating: 0, count: levelSamples.count)
    }

    /// Converts live microphone power into a rolling waveform and updates the
    /// elapsed clock used by the ten-second completion guard.
    private func captureMeterSample() {
        guard let recorder else { return }
        if isRecording, !recorder.isRecording {
            handleUnexpectedStop(recorder)
            return
        }
        elapsedTime = max(elapsedTime, recorder.currentTime)
        recorder.updateMeters()
        let level = VoiceRecordingPresentation.normalizedLevel(
            decibels: recorder.averagePower(forChannel: 0)
        )
        levelSamples.removeFirst()
        levelSamples.append(level)
    }

    /// Samples metering on the main actor so SwiftUI receives ordered waveform
    /// and elapsed-time updates while recording is active.
    private func startMetering() {
        stopMetering()
        meteringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, !Task.isCancelled else { return }
                self.captureMeterSample()
            }
        }
    }

    /// Stops visual metering immediately when recording pauses, finishes, or is
    /// discarded, keeping microphone state and UI state aligned.
    private func stopMetering() {
        meteringTask?.cancel()
        meteringTask = nil
    }

    /// Converts an unexpected recorder stop into a recoverable error without
    /// exposing a short or potentially corrupt temporary WAV for saving.
    private func handleUnexpectedStop(_ recorder: AVAudioRecorder) {
        elapsedTime = max(elapsedTime, recorder.currentTime)
        stopMetering()
        isRecording = false
        isPaused = false
        self.recorder = nil
        try? FileManager.default.removeItem(at: recorder.url)
        recordedURL = nil
        errorMessage =
            "Recording stopped unexpectedly. Please record the guided sample again."
    }
}

struct VoiceStudioView: View {
    static let recordingPrompt =
        "안녕하세요. 처음에는 조금 복잡해 보일 수 있죠? 하지만 걱정하지 마세요. 중요한 기능은 또렷하게, 사용 방법은 차분하고 자연스럽게 안내해 드리겠습니다."

    @ObservedObject var store: AppStore
    @StateObject private var recorder = VoiceSampleRecorder()
    @Environment(\.dismiss) private var dismiss
    private let refreshRuntimeOnAppear: Bool

    @State private var profileName = "My voice"
    @State private var transcript = ""
    @State private var consentConfirmed = false
    @State private var narrationText = ""
    @State private var narrationStart = 0.0
    @State private var selectedProfileID: UUID?
    @State private var isWorking = false
    @State private var showPrepareConfirmation = false
    @State private var profilePendingDeletion: UUID?

    init(
        store: AppStore,
        refreshRuntimeOnAppear: Bool = true
    ) {
        self.store = store
        self.refreshRuntimeOnAppear = refreshRuntimeOnAppear
    }

    var body: some View {
        NavigationStack {
            Form {
                runtimeSection
                profileCreationSection
                if recorder.hasSession {
                    guidedRecordingSection
                }
                profilesSection
                narrationSection
            }
            .formStyle(.grouped)
            .navigationTitle("Voice Narration")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(
                            isWorking
                                || recorder.isRecording
                                || recorder.isPaused
                        )
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
            if refreshRuntimeOnAppear {
                await store.refreshVoiceRuntimeState()
            }
        }
        .onDisappear {
            recorder.discard()
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
            TextField(
                "Exact transcript for imported MP3/WAV",
                text: $transcript,
                axis: .vertical
            )
                .lineLimit(3)
                .disabled(recorder.hasSession || isWorking)
            Toggle(
                "I own this voice or have permission to use it",
                isOn: $consentConfirmed
            )
            .disabled(
                VoiceInputPermissionPolicy.consentIsLocked(
                    hasSession: recorder.hasSession,
                    isWorking: isWorking
                )
            )
            HStack {
                Button("Import MP3/WAV") { importReference() }
                    .disabled(!canStartVoiceInput)
                Button("Record Guided Sample") {
                    beginGuidedRecording()
                }
                .disabled(!canStartVoiceInput)
            }
            if !consentConfirmed {
                Label(
                    "Confirm voice ownership or permission to enable file import and recording.",
                    systemImage: "lock.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text("The guided sample takes about 10–15 seconds and captures natural questions, emphasis, pauses, and calm narration.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorMessage = recorder.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var guidedRecordingSection: some View {
        Section("Guided Voice Recording") {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Circle()
                        .fill(recordingStatusColor)
                        .frame(width: 10, height: 10)
                    Text(recordingStatusText)
                        .font(.headline)
                    Spacer()
                    Text(
                        "\(VoiceRecordingPresentation.formattedDuration(recorder.elapsedTime)) / 00:10.0"
                    )
                    .font(.system(.body, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Read this script naturally")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(Self.recordingPrompt)
                        .font(.title3)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.secondary.opacity(0.08))
                )

                VoiceInputWaveform(levels: recorder.levelSamples)

                ProgressView(
                    value: min(
                        recorder.elapsedTime
                            / VoiceRecordingRequirements.minimumDuration,
                        1
                    )
                )

                HStack {
                    if recorder.canFinish {
                        Label(
                            "Minimum reached",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    } else {
                        Text(
                            "\(VoiceRecordingPresentation.remainingDuration(elapsed: recorder.elapsedTime), format: .number.precision(.fractionLength(1))) seconds remaining"
                        )
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Target: 10–15 seconds")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                recordingControls
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var recordingControls: some View {
        if recorder.isRecording {
            HStack {
                Button("Pause") {
                    recorder.pause()
                }
                Button("Finish Recording") {
                    recorder.finish()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!recorder.canFinish)
                Button("Cancel", role: .destructive) {
                    recorder.discard()
                }
            }
        } else if recorder.isPaused {
            HStack {
                Button("Resume") {
                    do {
                        try recorder.resume()
                    } catch {
                        store.errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Finish Recording") {
                    recorder.finish()
                }
                .disabled(!recorder.canFinish)
                Button("Record Again", role: .destructive) {
                    restartGuidedRecording()
                }
                Button("Cancel", role: .destructive) {
                    recorder.discard()
                }
            }
        } else if let recordedURL = recorder.recordedURL {
            HStack {
                Button("Preview Recording") {
                    NSWorkspace.shared.open(recordedURL)
                }
                Button("Record Again") {
                    restartGuidedRecording()
                }
                Button("Save Voice Profile") {
                    createProfile(
                        from: recordedURL,
                        transcriptOverride: Self.recordingPrompt,
                        source: .microphone
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isWorking
                        || !consentConfirmed
                        || profileName.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                )
                Button("Discard", role: .destructive) {
                    recorder.discard()
                }
            }
        }
    }

    private var recordingStatusText: String {
        if recorder.isRecording {
            return "Recording"
        }
        if recorder.isPaused {
            return "Paused — continue when ready"
        }
        return "Recording complete"
    }

    private var recordingStatusColor: Color {
        if recorder.isRecording {
            return .red
        }
        if recorder.isPaused {
            return .orange
        }
        return .green
    }

    private var canStartVoiceInput: Bool {
        VoiceInputPermissionPolicy.canStart(
            consentConfirmed: consentConfirmed,
            hasSession: recorder.hasSession,
            isWorking: isWorking
        )
    }

    /// Starts a fresh guided session with the prosody-covering script and keeps
    /// incomplete samples out of profile storage.
    private func beginGuidedRecording() {
        guard canStartVoiceInput else { return }
        recorder.discard()
        Task {
            do {
                try await recorder.start()
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    /// Replaces the current temporary sample before applying the normal consent
    /// and microphone start path, so paused and completed sessions can restart.
    private func restartGuidedRecording() {
        guard VoiceInputPermissionPolicy.canRestart(
            consentConfirmed: consentConfirmed,
            isWorking: isWorking
        ) else {
            return
        }
        recorder.discard()
        beginGuidedRecording()
    }

    private struct VoiceInputWaveform: View {
        let levels: [Double]

        var body: some View {
            HStack(alignment: .center, spacing: 3) {
                ForEach(levels.indices, id: \.self) { index in
                    let level = levels[index]
                    Capsule()
                        .fill(
                            level > 0.12
                                ? Color.accentColor
                                : Color.secondary.opacity(0.28)
                        )
                        .frame(
                            width: 5,
                            height: max(6, 58 * level)
                        )
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.04))
            )
            .animation(
                .linear(duration: 0.08),
                value: levels
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live microphone input level")
            .accessibilityValue(
                levels.last.map {
                    "\((100 * $0).rounded()) percent"
                } ?? "0 percent"
            )
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
        guard canStartVoiceInput else { return }
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
