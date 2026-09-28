import AVFoundation
import AudioToolbox
import Foundation
import StorybirdCore

struct VoiceCaptureSnapshot: Sendable {
    let duration: Double
    let decibels: Float
    let failure: String?
    var hasClipped = false
}

final class VoiceCaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: VoiceAudioStreamConverter?
    private var sourceFormat: AVAudioFormat?
    private var frameCount: AVAudioFramePosition = 0
    private var decibels: Float = -80
    private var failure: String?
    private var inputGain: VoiceRecordingGain
    private var hasClipped = false

    /// Each capture owns its writer, conversion state and starting volume;
    /// retries may reuse the selected volume without reusing previous samples.
    init?(file: AVAudioFile, sourceFormat: AVAudioFormat, inputGain: VoiceRecordingGain = .unity) {
        guard let converter = VoiceAudioStreamConverter(
            from: sourceFormat,
            to: file.processingFormat
        ) else {
            return nil
        }
        self.file = file
        self.converter = converter
        self.sourceFormat = sourceFormat
        self.inputGain = inputGain
    }

    /// Creates the same 24 kHz mono 16-bit WAV for every microphone so device
    /// sample rate and channel count never change the stored profile contract.
    static func makeFile(at url: URL) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: VoiceRecordingFormat.settings)
    }

    /// Changes only future output under the same lock as writing. Already
    /// written frames and the source capture buffer are never modified.
    func setInputGain(_ gain: VoiceRecordingGain) {
        lock.withLock { inputGain = gain }
    }

    /// Normalizes callback formats, applies the current input volume, and
    /// meters the adjusted samples while retaining clipping until capture ends.
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
            // A valid short input may still be buffered by the converter.
            // Meter that input, but only written frames advance duration.
            guard converted.frameLength > 0 else {
                decibels = Self.decibels(amplitude: buffer.voicePeakAmplitude() * Float(inputGain.multiplier))
                return
            }
            guard let samples = converted.floatChannelData else {
                decibels = Self.decibels(amplitude: buffer.voicePeakAmplitude() * Float(inputGain.multiplier))
                failure = "Storybird could not convert microphone audio."
                return
            }
            let gain = Float(inputGain.multiplier)
            var peak: Float = 0
            for channel in 0..<Int(converted.format.channelCount) {
                for frame in 0..<Int(converted.frameLength) {
                    let scaled = samples[channel][frame] * gain
                    peak = max(peak, abs(scaled))
                    samples[channel][frame] = min(1, max(-1, scaled))
                }
            }
            hasClipped = hasClipped || peak > 1
            decibels = Self.decibels(amplitude: peak)
            do {
                try file.write(from: converted)
                frameCount += AVAudioFramePosition(converted.frameLength)
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
                duration: Double(frameCount) / VoiceRecordingFormat.sampleRate,
                decibels: decibels,
                failure: failure,
                hasClipped: hasClipped
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

    /// Maps adjusted peak amplitude into the meter's finite silence-to-full
    /// scale range; clipping is reported separately from the saturated level.
    private static func decibels(amplitude: Float) -> Float {
        Float(20 * log10(max(min(amplitude, 1), 0.000_1)))
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
        let pending = VoiceConversionInput(input)
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { requestedFrames, inputStatus in
            guard let buffer = pending.take(maximumFrameCount: requestedFrames) else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        guard !pending.failed else { return nil }
        switch status {
        case .haveData, .inputRanDry:
            // A 1-frame 44.1 kHz input produced zero 24 kHz frames without an
            // error. Keep this successful empty result distinct from failure.
            return output
        case .endOfStream, .error:
            return nil
        @unknown default:
            return nil
        }
    }
}

private final class VoiceConversionInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?
    private var offset: AVAudioFrameCount = 0
    private var copyingFailed = false

    var failed: Bool { lock.withLock { copyingFailed } }

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    /// Supplies each input frame once, respecting the converter's packet limit.
    /// Returning all 4,800 frames to a 4,096-frame request lost the last 704.
    func take(maximumFrameCount: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        lock.withLock {
            guard let buffer, maximumFrameCount > 0 else { return nil }
            let count = min(maximumFrameCount, buffer.frameLength - offset)
            guard count > 0 else { return nil }
            if offset == 0, count == buffer.frameLength {
                self.buffer = nil
                return buffer
            }
            guard let part = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count) else {
                copyingFailed = true
                return nil
            }
            part.frameLength = count
            let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let destination = UnsafeMutableAudioBufferListPointer(part.mutableAudioBufferList)
            for index in source.indices {
                guard let input = source[index].mData, let output = destination[index].mData else {
                    copyingFailed = true
                    return nil
                }
                output.copyMemory(from: input.advanced(by: Int(offset) * bytesPerFrame), byteCount: Int(count) * bytesPerFrame)
            }
            offset += count
            if offset == buffer.frameLength { self.buffer = nil }
            return part
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
