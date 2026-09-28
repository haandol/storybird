import AVFoundation
import AudioToolbox

enum VoiceRecordingFormat {
    static let sampleRate = 24_000.0
    static let channelCount: AVAudioChannelCount = 1

    static var settings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Keeps capture and final asset publication on the same PCM format, while
    /// distinguishing stored Int16 audio from Float32 decoding buffers.
    static func matches(_ format: AVAudioFormat) -> Bool {
        format.sampleRate == sampleRate
            && format.channelCount == channelCount
            && format.commonFormat == .pcmFormatInt16
    }
}
