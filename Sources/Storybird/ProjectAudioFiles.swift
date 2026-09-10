import AVFoundation
import Foundation
import StorybirdCore

struct AudioFileSummary: Codable, Sendable {
    let duration: Double
    let peak: Double
    let waveform: [Double]
}

enum ProjectAudioFiles {
    /// Decodes the entire source before publication and produces a project-owned
    /// PCM WAV. Invalid input or cancellation leaves no referenced partial file.
    static func importFile(from source: URL, to destination: URL) throws -> AudioFileSummary {
        guard source.isFileURL, ["wav", "mp3", "m4a"].contains(source.pathExtension.lowercased()) else {
            throw AgentEditError.invalidField("audio_file")
        }
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0, input.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else {
            throw VoiceSynthesisError.invalidResponse
        }
        do {
            let output = try AVAudioFile(forWriting: destination, settings: format.settings)
            while input.framePosition < input.length {
                try Task.checkCancellation()
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { throw VoiceSynthesisError.invalidResponse }
                try output.write(from: buffer)
            }
        }
        return try inspect(destination)
    }

    /// Streams all frames to verify readability and measure real waveform peaks
    /// with bounded memory, preserving the file's native channels and duration.
    static func inspect(_ url: URL, bucketCount: Int = 128) throws -> AudioFileSummary {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        guard file.length > 0, rate > 0, rate.isFinite,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192) else {
            throw VoiceSynthesisError.invalidResponse
        }
        let count = max(1, bucketCount)
        var waveform = [Double](repeating: 0, count: count)
        var peak = 0.0
        var offset: AVAudioFramePosition = 0
        while offset < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                throw VoiceSynthesisError.invalidResponse
            }
            for frame in 0..<Int(buffer.frameLength) {
                var value = 0.0
                for channel in 0..<Int(buffer.format.channelCount) {
                    let sample = Double(channels[channel][frame])
                    guard sample.isFinite else { throw VoiceSynthesisError.invalidResponse }
                    value = max(value, abs(sample))
                }
                peak = max(peak, value)
                let bucket = min(count - 1, Int(Double(offset + Int64(frame)) / Double(file.length) * Double(count)))
                waveform[bucket] = max(waveform[bucket], value)
            }
            offset += Int64(buffer.frameLength)
        }
        return AudioFileSummary(duration: Double(offset) / rate, peak: peak, waveform: waveform)
    }
}
