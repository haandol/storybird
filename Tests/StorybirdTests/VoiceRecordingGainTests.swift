import AVFoundation
import Foundation
import StorybirdCore
import XCTest
@testable import Storybird

@MainActor
final class VoiceRecordingGainTests: XCTestCase {
    func test_finalization_lastInputClipping_reachesPreviewMeterAndFinalDuration() throws {
        let capture = try fixture(gain: 4)
        capture.sink.consume(try buffer(amplitude: 0.1))
        XCTAssertFalse(capture.sink.snapshot().hasClipped)
        let lateInput = try buffer(amplitude: 0.4)
        let final = try VoiceRecordingFinalization.finalize(
            stopInput: { capture.sink.consume(lateInput) },
            finishFile: { capture.sink.finish() },
            snapshot: { capture.sink.snapshot() }
        )
        let recorder = VoiceSampleRecorder()
        recorder.updateMeter(with: final)
        XCTAssertTrue(recorder.hasClipped)
        XCTAssertEqual(recorder.elapsedTime, 1_024 / 24_000, accuracy: 1 / 24_000)
        XCTAssertEqual(try read(capture).count, 1_024)
    }

    func test_finalization_lastWriteFailure_rejectsSuccessfulCompletion() throws {
        var state = VoiceCaptureSnapshot(duration: 10, decibels: -10, failure: nil)
        var events: [String] = []
        XCTAssertThrowsError(try VoiceRecordingFinalization.finalize(
            stopInput: { events.append("stop input") },
            finishFile: {
                events.append("finish file")
                state = VoiceCaptureSnapshot(duration: 10, decibels: -10, failure: "Injected final write failure")
            },
            snapshot: { events.append("snapshot"); return state }
        )) { error in
            XCTAssertEqual(error.localizedDescription, "Injected final write failure")
        }
        XCTAssertEqual(events, ["stop input", "finish file", "snapshot"])
    }

    func test_largeMonoBuffer_preservesEveryInputFrame() throws {
        let capture = try fixture()
        capture.sink.consume(try buffer(amplitude: 0.25, count: 4_800))
        XCTAssertEqual(capture.sink.snapshot().duration, 0.2, accuracy: 1 / 24_000)
        XCTAssertEqual(try read(capture).count, 4_800)
    }

    func test_adjustedCapture_updatesObservableMeterAndRetainsClippingUntilDiscard() throws {
        let capture = try fixture(gain: 4)
        let recorder = VoiceSampleRecorder()
        try recorder.setInputGain(4)
        capture.sink.consume(try buffer(amplitude: 0.4))
        recorder.updateMeter(with: capture.sink.snapshot())
        XCTAssertTrue(recorder.hasClipped)
        XCTAssertEqual(recorder.levelSamples.last, 1)
        XCTAssertGreaterThan(recorder.elapsedTime, 0)
        capture.sink.setInputGain(try VoiceRecordingGain(multiplier: 0))
        capture.sink.consume(try buffer(amplitude: 0.4))
        recorder.updateMeter(with: capture.sink.snapshot())
        XCTAssertTrue(recorder.hasClipped)
        XCTAssertEqual(recorder.levelSamples.last, 0)
        recorder.discard()
        XCTAssertFalse(recorder.hasClipped)
        XCTAssertEqual(recorder.inputGain, 4)
        capture.sink.finish()
    }

    func test_gain_validRangeAndInvalidValues_preserveRecorderSelection() throws {
        let recorder = VoiceSampleRecorder()
        XCTAssertEqual(recorder.inputGain, 1)
        for gain in [0.0, 0.5, 1, 2, 4] {
            try recorder.setInputGain(gain)
            XCTAssertEqual(recorder.inputGain, gain)
        }
        for gain in [-0.01, 4.01, Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try recorder.setInputGain(gain))
            XCTAssertEqual(recorder.inputGain, 4)
        }
        recorder.discard()
        XCTAssertEqual(recorder.inputGain, 4, "Record Again retains this recorder's volume.")
        XCTAssertFalse(recorder.hasClipped)
        XCTAssertEqual(VoiceSampleRecorder().inputGain, 1, "A new sheet gets its own default.")
    }

    func test_gainChanges_affectOnlyFutureSamplesAndMeterWhileMuteAdvancesTime() throws {
        let capture = try fixture()
        let input = try buffer(amplitude: 0.25)
        let original = samples(in: input)
        capture.sink.consume(input)
        XCTAssertEqual(capture.sink.snapshot().decibels, -12.0412, accuracy: 0.01)
        capture.sink.setInputGain(try VoiceRecordingGain(multiplier: 2))
        capture.sink.consume(input)
        XCTAssertEqual(capture.sink.snapshot().decibels, -6.0206, accuracy: 0.01)
        capture.sink.setInputGain(try VoiceRecordingGain(multiplier: 0))
        capture.sink.consume(input)
        let snapshot = capture.sink.snapshot()
        XCTAssertEqual(snapshot.duration, 1_536 / 24_000, accuracy: 1 / 24_000)
        XCTAssertEqual(snapshot.decibels, -80)
        XCTAssertFalse(snapshot.hasClipped)
        XCTAssertNil(snapshot.failure)
        XCTAssertTrue(samples(in: input) == original, "Capture input must remain unchanged.")
        let recorded = try read(capture)
        XCTAssertEqual(recorded.count, 1_536)
        guard recorded.count == 1_536 else { return }
        assertSamples(recorded[0..<512], amplitude: 0.25)
        assertSamples(recorded[512..<1_024], amplitude: 0.5)
        assertSamples(recorded[1_024..<1_536], amplitude: 0)
    }

    func test_gainAboveFullScale_limitsBothPolaritiesAndKeepsClippingWarning() throws {
        let capture = try fixture(gain: 4)
        let input = try buffer(amplitude: 0.4)
        capture.sink.consume(input)
        XCTAssertEqual(capture.sink.snapshot().decibels, 0)
        XCTAssertTrue(capture.sink.snapshot().hasClipped)
        capture.sink.setInputGain(try VoiceRecordingGain(multiplier: 0.1))
        capture.sink.consume(input)
        XCTAssertTrue(capture.sink.snapshot().hasClipped, "Lowering gain cannot repair clipped audio already stored.")
        XCTAssertLessThan(capture.sink.snapshot().decibels, -20)
        let recorded = try read(capture)
        XCTAssertTrue(capture.sink.snapshot().hasClipped, "The warning survives into preview.")
        XCTAssertEqual(recorded.count, 1_024)
        guard recorded.count == 1_024 else { return }
        assertSamples(recorded[0..<512], amplitude: 1)
        assertSamples(recorded[512..<1_024], amplitude: 0.04)
        let replacement = try fixture(gain: 4)
        XCTAssertFalse(replacement.sink.snapshot().hasClipped)
    }

    func test_formatChange_preservesSelectedGainAndPreviouslyWrittenSamples() throws {
        let capture = try fixture(gain: 2)
        capture.sink.consume(try buffer(amplitude: 0.25))
        let input = try buffer(amplitude: 0.25, rate: 48_000, count: 4_800, alternating: false)
        capture.sink.consume(input)
        XCTAssertNil(capture.sink.snapshot().failure)
        XCTAssertFalse(capture.sink.snapshot().hasClipped)
        let recorded = try read(capture)
        XCTAssertGreaterThan(recorded.count, 2_000)
        guard recorded.count > 2_000 else { return }
        assertSamples(recorded[0..<512], amplitude: 0.5)
        assertSamples(recorded.suffix(256), amplitude: 0.5, alternating: false)
    }

    func test_shortInputWithGain_waitsWithoutFailureThenStoresAdjustedAudio() throws {
        let capture = try fixture(gain: 2, rate: 44_100)
        capture.sink.consume(try buffer(amplitude: 0.25, rate: 44_100, count: 1))
        XCTAssertEqual(capture.sink.snapshot().duration, 0)
        XCTAssertNil(capture.sink.snapshot().failure)
        XCTAssertEqual(capture.sink.snapshot().decibels, -6.0206, accuracy: 0.01)
        capture.sink.consume(try buffer(amplitude: 0.25, rate: 44_100, count: 4_410, alternating: false))
        XCTAssertNil(capture.sink.snapshot().failure)
        XCTAssertGreaterThan(capture.sink.snapshot().duration, 0)
        let recorded = try read(capture)
        assertSamples(recorded.suffix(256), amplitude: 0.5, alternating: false)
    }

    private struct Capture {
        let url: URL
        let sink: VoiceCaptureSink
    }

    /// Uses a fresh writer and real converter without opening a microphone or
    /// touching the user's projects, profiles or preferences.
    private func fixture(gain: Double = 1, rate: Double = 24_000) throws -> Capture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storybird-input-gain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("recorded.wav")
        return Capture(url: url, sink: try XCTUnwrap(VoiceCaptureSink(
            file: VoiceCaptureSink.makeFile(at: url), sourceFormat: format(rate: rate),
            inputGain: VoiceRecordingGain(multiplier: gain)
        )))
    }

    /// Makes exact binary amplitudes at the native output rate for sample-level
    /// assertions; other rates exercise the production converter's rebuild.
    private func buffer(
        amplitude: Float, rate: Double = 24_000, count: Int = 512, alternating: Bool = true
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format(rate: rate), frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let data = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<count { data[frame] = alternating && frame % 2 == 1 ? -amplitude : amplitude }
        return buffer
    }

    /// Uses mono floating-point capture so gain expectations are independent of downmixing.
    private func format(rate: Double) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    }

    /// Copies samples for comparisons without retaining callback-owned memory.
    private func samples(in buffer: AVAudioPCMBuffer) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// Reopens the finalized WAV and checks the stored format as well as the
    /// samples, so metering alone cannot stand in for recording evidence.
    private func read(_ capture: Capture) throws -> [Float] {
        capture.sink.finish()
        let file = try AVAudioFile(forReading: capture.url)
        XCTAssertEqual(file.fileFormat.sampleRate, 24_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mBitsPerChannel, 16)
        let data = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: data)
        return samples(in: data)
    }

    /// Allows only 16-bit quantization error while checking both polarities.
    private func assertSamples(_ samples: ArraySlice<Float>, amplitude: Float, alternating: Bool = true) {
        let mismatch = samples.enumerated().first { index, sample in
            let expected = alternating && index % 2 == 1 ? -amplitude : amplitude
            return !(abs(sample - expected) <= 2 / 32_768)
        }
        XCTAssertNil(mismatch, "Recorded samples must match the requested gain within 16-bit quantization.")
    }
}
