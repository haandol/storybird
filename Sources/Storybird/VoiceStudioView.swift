import AppKit
import StorybirdCore
import SwiftUI

struct VoiceStudioView: View {

    static let recordingPrompt =
        "안녕하세요. 처음에는 조금 복잡해 보일 수 있죠? 하지만 걱정하지 마세요. 중요한 기능은 또렷하게, 사용 방법은 차분하고 자연스럽게 안내해 드리겠습니다."

    @ObservedObject var store: AppStore
    @StateObject private var recorder = VoiceSampleRecorder()
    private let refreshRuntimeOnAppear: Bool

    @State private var profileName = "My voice"
    @State private var transcript = ""
    @State private var consentConfirmed = false
    @State private var isWorking = false
    @State private var showPrepareConfirmation = false
    @State private var profilePendingDeletion: UUID?
    @State private var availableInputDevices: [VoiceInputDevice] = []
    @State private var preferredInputDeviceUID =
        VoiceInputPreferences.preferredDeviceUID()

    init(
        store: AppStore,
        refreshRuntimeOnAppear: Bool = true
    ) {
        self.store = store
        self.refreshRuntimeOnAppear = refreshRuntimeOnAppear
    }

    var body: some View {
        Form {
            runtimeSection
            inputDeviceSection
            profileCreationSection
            if recorder.hasSession {
                GuidedVoiceRecordingSection(
                    recorder: recorder,
                    prompt: Self.recordingPrompt,
                    isWorking: isWorking,
                    consentConfirmed: consentConfirmed,
                    profileName: profileName,
                    onRestart: restartGuidedRecording,
                    onSave: { recordedURL in
                        createProfile(
                            from: recordedURL,
                            transcriptOverride: Self.recordingPrompt,
                            source: .microphone
                        )
                    },
                    onError: { error in
                        store.errorMessage = error.localizedDescription
                    }
                )
            }
            profilesSection
        }
        .formStyle(.grouped)
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
            refreshInputDevices()
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

    private var inputDeviceSection: some View {
        Section("Guided Recording Microphone") {
            Picker(
                "Input device",
                selection: Binding(
                    get: { preferredInputDeviceUID },
                    set: { selectInputDevice($0) }
                )
            ) {
                ForEach(inputDeviceOptions) { option in
                    Text(option.title).tag(option.uid)
                }
            }

            HStack {
                Text(inputDeviceStatus)
                    .font(.caption)
                    .foregroundStyle(
                        resolvedInputSelection.isUsingFallback
                            ? .orange
                            : .secondary
                    )
                Spacer()
                Button("Refresh Devices") {
                    refreshInputDevices()
                }
                .buttonStyle(.link)
            }

            if recorder.hasSession {
                Text(
                    "This recording keeps the microphone it started with. A new selection applies to the next guided recording."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let activeDeviceName = recorder.activeDeviceName {
                Label(
                    recorder.isUsingFallbackDevice
                        ? "Recording with \(activeDeviceName) as a temporary fallback."
                        : "Recording with \(activeDeviceName).",
                    systemImage: recorder.isUsingFallbackDevice
                        ? "arrow.trianglehead.branch"
                        : "mic.fill"
                )
                .font(.caption)
                .foregroundStyle(
                    recorder.isUsingFallbackDevice ? .orange : .secondary
                )
            }
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
                try await recorder.start(
                    preferredDeviceUID: preferredInputDeviceUID
                )
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
                _ = try await store.importVoiceProfile(
                    name: profileName,
                    sourceURL: url,
                    transcript: transcriptOverride ?? transcript,
                    source: source,
                    consentConfirmed: consentConfirmed
                )
                recorder.discard()
            } catch {
                store.errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private var resolvedInputSelection: VoiceInputDeviceSelection {
        VoiceInputDeviceSelection.resolve(
            preferredUID: preferredInputDeviceUID,
            availableDevices: availableInputDevices,
            defaultUID: VoiceInputDeviceCatalog.defaultDeviceUID()
        )
    }

    private var inputDeviceOptions: [VoiceInputDeviceOption] {
        VoiceInputDeviceOption.options(
            availableDevices: availableInputDevices,
            defaultUID: VoiceInputDeviceCatalog.defaultDeviceUID(),
            preferredUID: preferredInputDeviceUID
        )
    }

    private var inputDeviceStatus: String {
        let selection = resolvedInputSelection
        if selection.isUsingFallback {
            return "The selected microphone is unavailable. Storybird will use the system default and keep your selection."
        }
        if let activeUID = selection.activeUID,
           let name = VoiceInputDeviceCatalog.name(forUID: activeUID) {
            return preferredInputDeviceUID == nil
                ? "Following the system default: \(name)."
                : "Guided recordings will use \(name)."
        }
        return "No usable input device is currently available."
    }

    /// Reloads current input hardware while leaving the persisted UID intact so
    /// reconnecting a selected microphone restores it without another choice.
    private func refreshInputDevices() {
        availableInputDevices = VoiceInputDeviceCatalog.devices()
    }

    /// Persists only explicit user changes; hardware disappearance never
    /// clears the preferred UID and an active recording keeps its start device.
    private func selectInputDevice(_ uid: String?) {
        preferredInputDeviceUID = uid
        VoiceInputPreferences.save(preferredDeviceUID: uid)
    }
}
