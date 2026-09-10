import AppKit
import StorybirdCore
import SwiftUI

struct VoiceStudioView: View {

    static let recordingPrompt = VoiceLanguage.korean.referencePrompt

    @ObservedObject var store: AppStore
    private let refreshRuntimeOnAppear: Bool

    @State private var isCreationPresented = false
    @StateObject private var preview = VoicePreviewPlayer()
    @State private var isWorking = false
    @State private var showPrepareConfirmation = false
    @State private var profilePendingDeletion: UUID?
    @State private var availableInputDevices: [VoiceInputDevice] = []
    @State private var preferredInputDeviceUID =
        VoiceInputPreferences.preferredDeviceUID()

    /// Keeps shared model, microphone, and profile management in Settings;
    /// individual creation state belongs to each newly presented sheet.
    init(
        store: AppStore,
        refreshRuntimeOnAppear: Bool = true
    ) {
        self.store = store
        self.refreshRuntimeOnAppear = refreshRuntimeOnAppear
    }

    var body: some View {
        Form {
            profilesSection
            inputDeviceSection
            runtimeSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isCreationPresented) {
            VoiceProfileCreationView(store: store)
        }
        .onDisappear { preview.stop() }
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
                    preview.stop()
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
        }
    }

    private var profilesSection: some View {
        Section("Voice Profiles") {
            if store.voiceProfiles.isEmpty {
                Text("No voice profiles yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.voiceProfiles) { profile in
                let referenceURL = store.repository.voiceReferenceURL(
                    profileID: profile.id, filename: profile.referenceFilename
                )
                let isPlaying = preview.playingURL == referenceURL
                HStack {
                    VStack(alignment: .leading) {
                        Text(profile.name)
                        Text(profile.language)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        preview.toggle(referenceURL)
                    } label: {
                        Image(systemName: isPlaying ? "stop.circle" : "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(isPlaying ? "Stop previewing \(profile.name)" : "Preview \(profile.name)")
                    Button(role: .destructive) {
                        profilePendingDeletion = profile.id
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete \(profile.name)")
                }
            }
            if let error = preview.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button {
                preview.stop()
                isCreationPresented = true
            } label: {
                Label("Create Voice Profile…", systemImage: "plus")
            }
            .disabled(isWorking)
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
