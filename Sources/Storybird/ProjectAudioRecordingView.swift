import AVFAudio
import StorybirdCore
import SwiftUI

struct ProjectAudioRecordingView: View {
    @ObservedObject var store: AppStore
    let projectID: UUID
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder: VoiceSampleRecorder
    @State private var name = "Recorded voice"
    @State private var deviceUID: String?
    @State private var isStarting = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var player: AVAudioPlayer?

    /// Owns one native user-started recording, separate from voice-profile
    /// enrollment. Cancelling this sheet discards only its temporary sample.
    init(store: AppStore, projectID: UUID) {
        self.store = store
        self.projectID = projectID
        _recorder = StateObject(wrappedValue: VoiceSampleRecorder(store: store, minimumDuration: 0))
        _deviceUID = State(initialValue: VoiceInputPreferences.preferredDeviceUID())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project voice recording") {
                    TextField("Name", text: $name).disabled(isSaving)
                    Picker("Microphone", selection: $deviceUID) {
                        ForEach(VoiceInputDeviceOption.options(
                            availableDevices: VoiceInputDeviceCatalog.devices(),
                            defaultUID: VoiceInputDeviceCatalog.defaultDeviceUID(), preferredUID: deviceUID
                        )) { option in
                            Text(option.title).tag(option.uid)
                        }
                    }
                    .disabled(recorder.hasSession || isStarting || isSaving)
                    Text("Record a separate voice clip, listen, then save it to this project's audio assets.")
                        .font(.caption).foregroundStyle(.secondary)
                    VoiceInputWaveform(levels: recorder.levelSamples)
                    Text(VoiceRecordingPresentation.formattedDuration(recorder.elapsedTime))
                        .monospacedDigit()
                    if let device = recorder.activeDeviceName {
                        Text(device + (recorder.isUsingFallbackDevice ? " · fallback" : ""))
                            .font(.caption)
                    }
                    HStack {
                        if recorder.isRecording {
                            Button("Pause") { recorder.pause() }
                            Button("Stop Recording") { recorder.finish() }.disabled(!recorder.canFinish)
                        } else if recorder.isPaused {
                            Button("Resume") {
                                do { try recorder.resume() } catch { errorMessage = error.localizedDescription }
                            }
                            Button("Stop Recording") { recorder.finish() }.disabled(!recorder.canFinish)
                        } else if let url = recorder.recordedURL {
                            Button("Listen") { listen(url) }
                            Button("Record Again") { player?.stop(); recorder.discard() }
                        } else {
                            Button("Start Recording") { start() }.disabled(isStarting)
                        }
                    }
                    .disabled(isSaving)
                }
                if let error = errorMessage ?? recorder.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Record Voice")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { player?.stop(); recorder.discard(); dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save Audio") { save() }
                        .disabled(isSaving || recorder.recordedURL == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(width: 560, height: 460)
        .interactiveDismissDisabled(isSaving)
        .onDisappear { player?.stop(); recorder.discard() }
    }

    /// Requests microphone input only from the explicit native button.
    private func start() {
        isStarting = true
        errorMessage = nil
        Task {
            defer { isStarting = false }
            do { try await recorder.start(preferredDeviceUID: deviceUID) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    /// Auditions a completed temporary sample without publishing a project asset.
    private func listen(_ url: URL) {
        do { player = try AVAudioPlayer(contentsOf: url); player?.play() }
        catch { errorMessage = error.localizedDescription }
    }

    /// A failed copy/index save leaves the sheet and sample available for retry.
    private func save() {
        guard !isSaving, let url = recorder.recordedURL else { return }
        isSaving = true
        player?.stop()
        Task {
            defer { isSaving = false }
            do {
                _ = try await store.importProjectAudio(projectID: projectID, sourceURL: url, name: name, origin: .recorded)
                recorder.discard()
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
