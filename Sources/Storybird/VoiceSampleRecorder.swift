import AVFoundation
import Combine
import Foundation

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
final class VoiceSampleRecorder: ObservableObject {
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
