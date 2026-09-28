import AVFoundation
import Foundation
import XCTest
@testable import Storybird

@MainActor
final class VoiceCaptureContinuityTests: XCTestCase {
    func test_startup_shortInputWithoutOutput_waitsForWrittenFrames() async throws {
        let capture = try fixture(rate: 44_100)
        var deliveries = 0
        var stops = 0
        let sink = try await VoiceCaptureStartup.start(
            makeSession: { capture.sink },
            snapshot: { $0.snapshot() },
            stopSession: { $0.finish(); stops += 1 },
            checkCancellation: {},
            waitForInput: {
                if deliveries == 0 {
                    capture.sink.consume(try self.tone(rate: 44_100, position: 0, count: 1))
                    let pending = capture.sink.snapshot()
                    XCTAssertNil(pending.failure)
                    XCTAssertEqual(pending.duration, 0)
                    XCTAssertGreaterThan(pending.decibels, -20)
                } else {
                    capture.sink.consume(try self.tone(rate: 44_100, position: 1, count: 4_096))
                }
                deliveries += 1
            }
        )

        XCTAssertTrue(sink === capture.sink)
        XCTAssertEqual(deliveries, 2, "A pending conversion must not satisfy startup readiness.")
        XCTAssertEqual(stops, 0)
        XCTAssertNil(sink.snapshot().failure)
        XCTAssertGreaterThan(sink.snapshot().duration, 0)
        _ = try finalizedSamples(capture)
    }

    func test_capture_shortInputsAtStartAndDuringRecording_preserveContinuousSamples() throws {
        let reference = try fixture(rate: 44_100)
        try writeTone(to: reference.sink, rate: 44_100, chunks: [1_024])
        let expected = try finalizedSamples(reference)
        XCTAssertEqual(Double(expected.count) / 24_000, 3, accuracy: 0.001)

        // The review measured empty output at the first 1-frame input, or the
        // seventh input after a 1024-frame start. Both poisoned the old sink.
        for chunks in [[1, 17, 512, 4_096], [1_024, 1, 17, 512, 4_096]] {
            let capture = try fixture(rate: 44_100)
            try writeTone(to: capture.sink, rate: 44_100, chunks: chunks)

            XCTAssertNil(capture.sink.snapshot().failure, "chunks=\(chunks)")
            let actual = try finalizedSamples(capture)
            XCTAssertEqual(actual.count, expected.count)
            XCTAssertTrue(actual == expected, "Short inputs must not drop, duplicate or reset samples.")
        }
    }

    func test_capture_largeStereoBuffer_preservesEveryInputFrame() throws {
        let capture = try fixture(rate: 24_000)
        let input = try tone(rate: 24_000, position: 0, count: 4_800)
        capture.sink.consume(input)
        XCTAssertEqual(capture.sink.snapshot().duration, 0.2, accuracy: 1 / 24_000)
        XCTAssertEqual(try finalizedSamples(capture).count, 4_800)
    }

    func test_capture_formatChangeWithShortFirstInput_preservesBothSpans() throws {
        let reference = try fixture(rate: 48_000)
        try writeTone(to: reference.sink, rate: 48_000, chunks: [1_024])
        try writeTone(to: reference.sink, rate: 44_100, chunks: [1_024])
        let expected = try finalizedSamples(reference)

        let capture = try fixture(rate: 48_000)
        try writeTone(to: capture.sink, rate: 48_000, chunks: [1_024])
        let beforeChange = capture.sink.snapshot().duration
        capture.sink.consume(try tone(rate: 44_100, position: 0, count: 1))
        XCTAssertNil(capture.sink.snapshot().failure)
        XCTAssertEqual(capture.sink.snapshot().duration, beforeChange)
        try writeTone(to: capture.sink, rate: 44_100, chunks: [17, 512, 4_096], position: 1)

        XCTAssertNil(capture.sink.snapshot().failure)
        XCTAssertGreaterThan(capture.sink.snapshot().duration, beforeChange)
        let actual = try finalizedSamples(capture)
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertTrue(actual == expected, "A pending format change must preserve both spans.")
    }

    func test_capture_finishedWhileAwaitingOutput_ignoresLateInput() throws {
        let capture = try fixture(rate: 44_100)
        capture.sink.consume(try tone(rate: 44_100, position: 0, count: 1))
        XCTAssertNil(capture.sink.snapshot().failure)
        capture.sink.finish()
        capture.sink.consume(try tone(rate: 44_100, position: 1, count: 4_096))

        XCTAssertNil(capture.sink.snapshot().failure)
        XCTAssertEqual(capture.sink.snapshot().duration, 0)
        XCTAssertEqual(try AVAudioFile(forReading: capture.url).length, 0)
    }

    private struct Capture {
        let url: URL
        let sink: VoiceCaptureSink
    }

    private func fixture(rate: Double) throws -> Capture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storybird-voice-continuity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.wav")
        return Capture(url: url, sink: try XCTUnwrap(VoiceCaptureSink(
            file: VoiceCaptureSink.makeFile(at: url),
            sourceFormat: format(rate: rate)
        )))
    }

    private func format(rate: Double) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 2,
            interleaved: true
        ))
    }

    private func tone(rate: Double, position: Int, count: Int) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format(rate: rate), frameCapacity: AVAudioFrameCount(count)
        ))
        buffer.frameLength = AVAudioFrameCount(count)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<count {
            let value = Float(0.2 * cos(2 * .pi * 997 * Double(position + frame) / rate))
            samples[2 * frame] = value
            samples[2 * frame + 1] = value
        }
        return buffer
    }

    private func writeTone(
        to sink: VoiceCaptureSink, rate: Double, chunks: [Int], position: Int = 0
    ) throws {
        var position = position
        var index = 0
        let total = Int(rate * 3)
        while position < total {
            let count = min(chunks[index % chunks.count], total - position)
            sink.consume(try tone(rate: rate, position: position, count: count))
            position += count
            index += 1
        }
    }

    private func finalizedSamples(_ capture: Capture) throws -> [Float] {
        let duration = capture.sink.snapshot().duration
        capture.sink.finish()
        let file = try AVAudioFile(forReading: capture.url)
        XCTAssertEqual(file.fileFormat.sampleRate, 24_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mBitsPerChannel, 16)
        XCTAssertEqual(Double(file.length) / 24_000, duration, accuracy: 1 / 24_000)
        guard file.length > 0 else { return [] }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(
            start: try XCTUnwrap(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)
        ))
    }
}
