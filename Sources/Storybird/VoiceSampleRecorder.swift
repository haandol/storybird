import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation

enum VoiceRecordingRequirements {
    static let minimumDuration = 10.0
}

enum VoiceRecordingFinalization {
    /// Publishes only the same still-active capture whose final meter check
    /// succeeded, preventing a failure cleanup from re-exposing a deleted WAV.
    static func canPublish(
        candidateURL: URL,
        activeURL: URL?,
        meteringSucceeded: Bool,
        hasSink: Bool
    ) -> Bool {
        meteringSucceeded && activeURL == candidateURL && hasSink
    }
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
    @Published private(set) var activeDeviceName: String?
    @Published private(set) var isUsingFallbackDevice = false

    private var engine: AVAudioEngine?
    private var sink: VoiceCaptureSink?
    private var captureURL: URL?
    private var hasInputTap = false
    private var meteringTask: Task<Void, Never>?

    var hasSession: Bool {
        engine != nil || recordedURL != nil
    }

    var canFinish: Bool {
        elapsedTime >= VoiceRecordingRequirements.minimumDuration
    }

    /// Requests microphone access only for this explicit action, then records
    /// from the persisted input choice or temporarily falls back to the system
    /// default without erasing an unavailable device preference.
    func start(
        preferredDeviceUID: String? = VoiceInputPreferences
            .preferredDeviceUID()
    ) async throws {
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

        let devices = VoiceInputDeviceCatalog.devices()
        let selection = VoiceInputDeviceSelection.resolve(
            preferredUID: preferredDeviceUID,
            availableDevices: devices,
            defaultUID: VoiceInputDeviceCatalog.defaultDeviceUID()
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("storybird-voice-\(UUID().uuidString).wav")
        let attempts = VoiceInputCapturePlan.deviceUIDs(for: selection)
        var startedAttempt: Int?
        for (index, deviceUID) in attempts.enumerated() {
            do {
                try beginCapture(at: url, deviceUID: deviceUID)
                startedAttempt = index
                break
            } catch {
                stopCapture()
                try? FileManager.default.removeItem(at: url)
            }
        }
        guard let startedAttempt else {
            errorMessage = preferredDeviceUID == nil
                ? "Storybird could not open a usable microphone."
                : "Storybird could not open the selected microphone or the system default."
            throw VoiceProfileError.microphoneUnavailable
        }
        isUsingFallbackDevice =
            selection.isUsingFallback || startedAttempt > 0

        let activeUID = isUsingFallbackDevice
            ? selection.fallbackUID
            : selection.activeUID
        activeDeviceName = activeUID.flatMap(
            VoiceInputDeviceCatalog.name(forUID:)
        ) ?? "System Default"
        recordedURL = nil
        elapsedTime = 0
        levelSamples = Array(repeating: 0, count: levelSamples.count)
        isPaused = false
        isRecording = true
        startMetering()
    }

    /// Pauses capture without finalizing the WAV so the same selected-device
    /// session can continue toward the ten-second minimum.
    func pause() {
        guard let engine, isRecording else { return }
        captureMeterSample()
        engine.pause()
        stopMetering()
        isPaused = true
        isRecording = false
    }

    /// Restarts the same audio engine and file after a pause, preserving the
    /// device, accumulated frames, and minimum-duration boundary.
    func resume() throws {
        guard let engine, isPaused else {
            throw VoiceProfileError.invalidInput
        }
        try engine.start()
        isPaused = false
        isRecording = true
        startMetering()
    }

    /// Finalizes only a sample that has reached ten seconds and exposes its WAV
    /// for preview, rerecording, or profile validation.
    @discardableResult
    func finish() -> Bool {
        guard let captureURL, canFinish else { return false }
        let meteringSucceeded = captureMeterSample()
        guard VoiceRecordingFinalization.canPublish(
            candidateURL: captureURL,
            activeURL: self.captureURL,
            meteringSucceeded: meteringSucceeded,
            hasSink: sink != nil
        )
        else {
            return false
        }
        stopMetering()
        stopCapture()
        recordedURL = captureURL
        isRecording = false
        isPaused = false
        return true
    }

    /// Removes the temporary microphone sample so an abandoned recording never
    /// becomes profile data.
    func discard() {
        stopMetering()
        let url = captureURL ?? recordedURL
        stopCapture()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        isRecording = false
        isPaused = false
        recordedURL = nil
        elapsedTime = 0
        levelSamples = Array(repeating: 0, count: levelSamples.count)
        activeDeviceName = nil
        isUsingFallbackDevice = false
    }

    /// Polls the callback-owned capture snapshot on the main actor so elapsed
    /// time, fallback failures, and waveform state remain ordered for SwiftUI.
    @discardableResult
    private func captureMeterSample() -> Bool {
        guard let engine, let sink else { return false }
        let snapshot = sink.snapshot()
        if let failure = snapshot.failure {
            handleUnexpectedStop(message: failure)
            return false
        }
        if isRecording, !engine.isRunning {
            handleUnexpectedStop(
                message: "Recording stopped unexpectedly."
            )
            return false
        }
        elapsedTime = max(elapsedTime, snapshot.duration)
        let level = VoiceRecordingPresentation.normalizedLevel(
            decibels: snapshot.decibels
        )
        levelSamples.removeFirst()
        levelSamples.append(level)
        return true
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

    /// Converts an engine or file-write failure into a recoverable state and
    /// removes the partial WAV so it can never become a voice profile.
    private func handleUnexpectedStop(message: String) {
        if let sink {
            elapsedTime = max(elapsedTime, sink.snapshot().duration)
        }
        stopMetering()
        isRecording = false
        isPaused = false
        let url = captureURL
        stopCapture()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        recordedURL = nil
        errorMessage = "\(message) Please record the guided sample again."
    }

    /// Opens one device-fixed AVAudioEngine session, taps its native input
    /// format, and normalizes callbacks into the fixed profile WAV format.
    private func beginCapture(
        at url: URL,
        deviceUID: String?
    ) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceUID {
            try Self.setInputDevice(deviceUID, on: input)
        }
        // Select the device first, then read its input format. USB and virtual
        // devices can change both sample rate and channel count.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceProfileError.microphoneUnavailable
        }
        let file = try VoiceCaptureSink.makeFile(at: url)
        guard let sink = VoiceCaptureSink(
            file: file,
            sourceFormat: format
        ) else {
            throw VoiceProfileError.microphoneUnavailable
        }
        Self.installInputTap(
            on: input,
            format: format,
            sink: sink
        )
        hasInputTap = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            hasInputTap = false
            throw error
        }
        self.engine = engine
        self.sink = sink
        captureURL = url
    }

    /// Creates the Core Audio callback outside MainActor isolation so the
    /// realtime audio queue may invoke it without a Swift executor trap.
    nonisolated private static func installInputTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        sink: VoiceCaptureSink
    ) {
        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format
        ) { buffer, _ in
            sink.consume(buffer)
        }
    }

    /// Applies a stable device UID before reading the input format and verifies
    /// the audio unit actually accepted the requested microphone.
    private static func setInputDevice(
        _ uid: String,
        on input: AVAudioInputNode
    ) throws {
        var deviceID = VoiceInputDeviceCatalog.deviceID(forUID: uid)
        guard deviceID != .zero, let unit = input.audioUnit else {
            throw VoiceProfileError.microphoneUnavailable
        }
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw VoiceProfileError.microphoneUnavailable
        }
        var applied = AudioObjectID.zero
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let readback = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &applied,
            &size
        )
        guard readback == noErr, applied == deviceID else {
            throw VoiceProfileError.microphoneUnavailable
        }
    }

    /// Tears down the active device session while leaving a completed WAV in
    /// place only when the caller is finalizing a valid guided sample.
    private func stopCapture() {
        if hasInputTap {
            engine?.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        engine?.stop()
        sink?.finish()
        engine = nil
        sink = nil
        captureURL = nil
    }
}
