import AVFoundation
import AudioToolbox
import Foundation

struct VoiceCaptureSnapshot: Sendable {
    let duration: Double
    let decibels: Float
    let failure: String?
}

final class VoiceCaptureSink: @unchecked Sendable {
    private static let sampleRate = 24_000.0
    private static var outputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: VoiceAudioStreamConverter?
    private var sourceFormat: AVAudioFormat?
    private var frameCount: AVAudioFramePosition = 0
    private var decibels: Float = -80
    private var failure: String?

    init?(file: AVAudioFile, sourceFormat: AVAudioFormat) {
        guard let converter = VoiceAudioStreamConverter(
            from: sourceFormat,
            to: file.processingFormat
        ) else {
            return nil
        }
        self.file = file
        self.converter = converter
        self.sourceFormat = sourceFormat
    }

    /// Creates the same 24 kHz mono 16-bit WAV for every microphone so device
    /// sample rate and channel count never change the stored profile contract.
    static func makeFile(at url: URL) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: outputSettings)
    }

    /// Rebuilds conversion when the callback format changes, writes normalized
    /// mono frames, and meters the original capture layout before resampling.
    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard failure == nil, let file else { return }
            if sourceFormat != buffer.format {
                converter = VoiceAudioStreamConverter(
                    from: buffer.format,
                    to: file.processingFormat
                )
                sourceFormat = buffer.format
            }
            guard let converter,
                  let converted = converter.convert(buffer)
            else {
                failure = "Storybird could not convert microphone audio."
                return
            }
            do {
                try file.write(from: converted)
                frameCount += AVAudioFramePosition(converted.frameLength)
                decibels = Self.decibels(in: buffer)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// Returns a value-only snapshot for ordered UI updates and duration
    /// enforcement without sharing callback-owned mutable audio state.
    func snapshot() -> VoiceCaptureSnapshot {
        lock.withLock {
            VoiceCaptureSnapshot(
                duration: Self.sampleRate > 0
                    ? Double(frameCount) / Self.sampleRate
                    : 0,
                decibels: decibels,
                failure: failure
            )
        }
    }

    /// Releases the WAV writer after the tap has stopped so its container is
    /// finalized before profile validation or temporary-file deletion.
    func finish() {
        lock.withLock {
            file = nil
        }
    }

    /// Reads float or integer PCM in interleaved and deinterleaved layouts so
    /// valid device audio is never misreported as silence.
    private static func decibels(in buffer: AVAudioPCMBuffer) -> Float {
        let amplitude = buffer.voicePeakAmplitude()
        return Float(20 * log10(max(amplitude, 0.000_1)))
    }
}

private final class VoiceAudioStreamConverter {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let ratio: Double

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(
            from: inputFormat,
            to: outputFormat
        ) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
        ratio = outputFormat.sampleRate / inputFormat.sampleRate
    }

    /// Converts one callback buffer exactly once and reserves enough output
    /// capacity for sample-rate conversion latency.
    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let capacity =
            AVAudioFrameCount(Double(input.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            return nil
        }
        let pending = VoiceOneShotBuffer(input)
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            guard let buffer = pending.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        switch status {
        case .haveData, .inputRanDry:
            return output.frameLength > 0 ? output : nil
        case .endOfStream, .error:
            return nil
        @unknown default:
            return nil
        }
    }
}

private final class VoiceOneShotBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    /// Transfers one non-Sendable audio buffer into AVAudioConverter's
    /// Sendable input callback and returns nil on every later request.
    func take() -> AVAudioPCMBuffer? {
        lock.withLock {
            defer { buffer = nil }
            return buffer
        }
    }
}

private extension AVAudioPCMBuffer {
    /// Samples a bounded subset of every channel in its actual memory layout,
    /// matching Scribird's fix for interleaved buffers that looked silent.
    func voicePeakAmplitude(sampleCount: Int = 256) -> Float {
        guard frameLength > 0 else { return 0 }
        let step = max(1, Int(frameLength) / sampleCount)
        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = floatChannelData else { return 0 }
            return voiceScanPeak(data, step: step) { abs($0) }
        case .pcmFormatInt16:
            guard let data = int16ChannelData else { return 0 }
            let scale = Float(Int16.max)
            return voiceScanPeak(data, step: step) {
                abs(Float($0) / scale)
            }
        case .pcmFormatInt32:
            guard let data = int32ChannelData else { return 0 }
            let scale = Float(Int32.max)
            return voiceScanPeak(data, step: step) {
                abs(Float($0) / scale)
            }
        case .otherFormat, .pcmFormatFloat64:
            return 1
        @unknown default:
            return 1
        }
    }

    /// Scans channels according to interleaved or deinterleaved storage rather
    /// than assuming channel zero owns one contiguous frame array.
    func voiceScanPeak<Sample>(
        _ data: UnsafePointer<UnsafeMutablePointer<Sample>>,
        step: Int,
        magnitude: (Sample) -> Float
    ) -> Float {
        let frames = Int(frameLength)
        let channels = Int(format.channelCount)
        var peak: Float = 0
        if format.isInterleaved {
            let samples = data[0]
            for frame in Swift.stride(from: 0, to: frames, by: step) {
                for channel in 0..<channels {
                    peak = max(
                        peak,
                        magnitude(samples[frame * channels + channel])
                    )
                }
            }
        } else {
            for channel in 0..<channels {
                let samples = data[channel]
                for frame in Swift.stride(
                    from: 0,
                    to: frames,
                    by: step
                ) {
                    peak = max(peak, magnitude(samples[frame]))
                }
            }
        }
        return peak
    }
}
