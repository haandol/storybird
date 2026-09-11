import AppKit
import StorybirdCore
import SwiftUI

struct VoiceProfileCreationView<Recorder: VoiceSampleRecording>: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: VoiceProfileCreationModel
    @StateObject private var recorder: Recorder
    @StateObject private var preview = VoicePreviewPlayer()
    @State private var startTask: Task<Void, Never>?
    @State private var isStarting = false
    @FocusState private var nameIsFocused: Bool

    /// Each presentation owns a fresh form and recorder so abandoned input
    /// and voice-use consent never carry over to another profile.
    init(store: AppStore) where Recorder == VoiceSampleRecorder {
        let recorder = VoiceSampleRecorder(store: store)
        self.init(
            model: VoiceProfileCreationModel(store: store, recorder: recorder),
            recorder: recorder
        )
    }

    /// Uses the same sheet for live input and synthetic UI checks; the injected
    /// model still owns saving, failure retention, and cancellation cleanup.
    init(model: VoiceProfileCreationModel, recorder: Recorder) {
        _recorder = StateObject(wrappedValue: recorder)
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Create Voice Profile")
                    .font(.title2.weight(.semibold))
                Text("Give your voice a name, then record or import a sample.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)

            Form {
                Section("Profile Details") {
                    TextField("Profile name", text: $model.profileName)
                        .focused($nameIsFocused)
                        .disabled(model.isSaving)
                    if recorder.hasSession {
                        LabeledContent("Reference language", value: model.referenceLanguage.displayName)
                    } else {
                        Picker("Reference language", selection: $model.referenceLanguage) {
                            ForEach(VoiceLanguage.allCases, id: \.self) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .disabled(inputIsLocked)
                        Toggle(
                            "I own this voice or have permission to use it",
                            isOn: $model.consentConfirmed
                        )
                        .disabled(inputIsLocked)
                    }
                }
                if !recorder.hasSession {
                    Section("Voice Sample") {
                        Picker("Input method", selection: $model.inputMethod) {
                            Text("Record").tag(VoiceProfileCreationModel.InputMethod.record)
                            Text("Import File").tag(VoiceProfileCreationModel.InputMethod.importFile)
                        }
                        .pickerStyle(.segmented)
                        .disabled(inputIsLocked)
                        if model.inputMethod == .importFile {
                            importedSample
                        } else {
                            Text(model.referenceLanguage.referencePrompt)
                                .font(.body)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                            Text("Read the full script naturally (\(model.referenceLanguage.referenceDurationDescription)). Record at least 10 seconds. You can pause, preview, and record again.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(isStarting ? "Starting…" : "Start Recording") {
                                startRecording()
                            }
                            .disabled(!canStartInput)
                        }
                        if !model.consentConfirmed {
                            Label("Confirm voice ownership or permission to enable recording and file selection.", systemImage: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if recorder.hasSession {
                    GuidedVoiceRecordingSection(
                        recorder: recorder,
                        preview: preview,
                        prompt: model.referenceLanguage.referencePrompt,
                        targetDurationDescription: model.referenceLanguage.referenceDurationDescription,
                        isWorking: model.isSaving,
                        onRestart: restartRecording,
                        onError: { model.errorMessage = $0.localizedDescription }
                    )
                    if let name = recorder.activeDeviceName {
                        Label(
                            recorder.isUsingFallbackDevice
                                ? "Using \(name) as a temporary fallback."
                                : "Microphone: \(name)",
                            systemImage: "mic.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                if let error = model.errorMessage ?? recorder.errorMessage ?? preview.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if model.isSaving {
                    ProgressView().controlSize(.small)
                    Text("Saving profile…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isSaving)
                Button("Create Profile") {
                    preview.stop()
                    Task { await model.save(recordedURL: recorder.recordedURL) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave(recordedURL: recorder.recordedURL))
            }
            .padding(20)
        }
        .frame(width: 620, height: 650)
        .interactiveDismissDisabled(model.isSaving)
        .onAppear { nameIsFocused = true }
        .onChange(of: model.isClosed) { _, isClosed in
            if isClosed {
                preview.stop()
                dismiss()
            }
        }
        .onDisappear {
            preview.stop()
            startTask?.cancel()
            model.cancel()
        }
    }

    private var importedSample: some View {
        Group {
            HStack {
                Text(model.selectedFileURL?.lastPathComponent ?? "No file selected")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose MP3/WAV…") { selectFile() }
                    .disabled(!canStartInput)
            }
            TextField(
                "Exact spoken transcript",
                text: $model.transcript,
                axis: .vertical
            )
            .lineLimit(3...6)
            .disabled(model.isSaving)
        }
    }

    private var inputIsLocked: Bool {
        isStarting || recorder.hasSession || model.isSaving
    }

    private var canStartInput: Bool {
        !model.isClosed && VoiceInputPermissionPolicy.canStart(
            consentConfirmed: model.consentConfirmed,
            hasSession: recorder.hasSession,
            isWorking: model.isSaving || isStarting
        )
    }

    /// Stages the user's supported file choice without creating a profile.
    /// Cancelling the picker preserves the form and any earlier selected file.
    private func selectFile() {
        guard canStartInput else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3, .wav]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.selectFile(url)
    }

    /// Locks the input choice while microphone permission is pending and drops
    /// late results when cancellation has already closed the creation attempt.
    private func startRecording() {
        guard canStartInput else { return }
        preview.stop()
        isStarting = true
        model.errorMessage = nil
        startTask = Task {
            defer { isStarting = false }
            do {
                try await recorder.start(
                    preferredDeviceUID: VoiceInputPreferences.preferredDeviceUID()
                )
            } catch {
                if !Task.isCancelled, !model.isClosed {
                    model.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Replaces only the temporary recording and reuses the consented language.
    private func restartRecording() {
        guard !model.isSaving, !model.isClosed, !isStarting else { return }
        preview.stop()
        recorder.discard()
        startRecording()
    }

    /// Cancels pending permission work before discarding active capture; save
    /// ownership is checked again so keyboard actions cannot bypass the lock.
    private func cancel() {
        guard !model.isSaving else { return }
        preview.stop()
        startTask?.cancel()
        model.cancel()
    }
}
