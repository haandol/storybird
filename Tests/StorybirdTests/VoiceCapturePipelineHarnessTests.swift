import AVFoundation
import Foundation
import XCTest
@testable import Storybird

@MainActor
final class VoiceCapturePipelineHarnessTests: XCTestCase {
    func test_initializationFormatError_cleansPartialFileAndRetriesWithUsableWAV() async throws {
        let harness = try fixture(plans: [
            .init(initialRate: 48_000, inputRate: nil, initializationError: -10868),
            .init(initialRate: 24_000, inputRate: 24_000),
        ])
        let capture = try await harness.start()

        XCTAssertEqual(harness.sessions.count, 2)
        XCTAssertEqual(harness.stoppedSessions, [0])
        XCTAssertEqual(capture.id, 1)
        XCTAssertGreaterThan(capture.sink.snapshot().duration, 0)
        try assertFinalizedWAV(capture)
    }

    func test_repeatedInitializationFormatErrors_leaveNoPartialFile() async throws {
        let harness = try fixture(plans: [
            .init(initialRate: 48_000, inputRate: nil, initializationError: -10868),
            .init(initialRate: 24_000, inputRate: nil, initializationError: -10868),
        ])
        do {
            _ = try await harness.start()
            XCTFail("A failed open must not publish a recording.")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSOSStatusErrorDomain)
            XCTAssertEqual((error as NSError).code, -10868)
        }
        XCTAssertEqual(harness.sessions.count, 2)
        XCTAssertEqual(harness.stoppedSessions, [0, 1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.url.path))
    }

    func test_hardwareFormatChangesWithoutCallbacks_rebuildsOnNextPollAndWritesAudio() async throws {
        let harness = try fixture(plans: [
            .init(initialRate: 48_000, inputRate: nil, changedRate: 24_000),
            .init(initialRate: 24_000, inputRate: 24_000),
        ])
        let capture = try await harness.start()

        XCTAssertEqual(harness.sessions.count, 2)
        XCTAssertEqual(harness.stoppedSessions, [0])
        XCTAssertEqual(harness.waits, 2, "One format-change poll plus one audio-arrival poll.")
        XCTAssertEqual(capture.id, 1)
        XCTAssertGreaterThan(capture.sink.snapshot().duration, 0)
        try assertFinalizedWAV(capture)
    }

    func test_bluetoothStartupStalls_rebuildsWithChangedFormatAndAdvancingWAV() async throws {
        let harness = try fixture(plans: [
            .init(initialRate: 48_000, inputRate: nil),
            .init(initialRate: 48_000, inputRate: 24_000),
        ])
        let capture = try await harness.start()

        XCTAssertEqual(harness.sessions.count, 2)
        XCTAssertEqual(harness.stoppedSessions, [0])
        XCTAssertEqual(capture.id, 1)
        XCTAssertGreaterThan(capture.sink.snapshot().duration, 0)
        XCTAssertGreaterThan(capture.sink.snapshot().decibels, -10)
        let firstDuration = capture.sink.snapshot().duration
        try harness.deliverInput(to: capture, rate: 24_000)
        XCTAssertGreaterThan(capture.sink.snapshot().duration, firstDuration)
        XCTAssertNil(capture.sink.snapshot().failure)
        try assertFinalizedWAV(capture)
    }

    func test_builtinStyleInput_startsOnceAndConvertsNativeRateToProfileFormat() async throws {
        for rate in [44_100.0, 48_000.0] {
            let harness = try fixture(plans: [
                .init(initialRate: rate, inputRate: rate),
            ])
            let capture = try await harness.start()

            XCTAssertEqual(harness.sessions.count, 1)
            XCTAssertTrue(harness.stoppedSessions.isEmpty)
            XCTAssertGreaterThan(capture.sink.snapshot().duration, 0)
            try assertFinalizedWAV(capture)
        }
    }

    func test_repeatedColdAndWarmStarts_neverReusePreviousFramesOrFailedWAV() async throws {
        for _ in 0..<3 {
            let harness = try fixture(plans: [
                .init(initialRate: 48_000, inputRate: nil),
                .init(initialRate: 24_000, inputRate: 24_000),
                .init(initialRate: 24_000, inputRate: 24_000),
            ])
            let cold = try await harness.start()
            let coldDuration = cold.sink.snapshot().duration
            XCTAssertGreaterThan(coldDuration, 0)
            harness.stop(cold)
            XCTAssertFalse(FileManager.default.fileExists(atPath: harness.url.path))

            let warm = try await harness.start()
            XCTAssertFalse(cold === warm)
            XCTAssertEqual(harness.sessions.count, 3)
            XCTAssertEqual(warm.sink.snapshot().duration, coldDuration, accuracy: 1 / 24_000)
            try assertFinalizedWAV(warm)
        }
    }

    func test_allAttemptsStall_removesEveryPartialWAVAndFailsWithinBudget() async throws {
        let harness = try fixture(plans: [
            .init(initialRate: 48_000, inputRate: nil),
            .init(initialRate: 24_000, inputRate: nil),
        ])
        do {
            _ = try await harness.start()
            XCTFail("No-input startup must not be reported as successful.")
        } catch VoiceProfileError.microphoneUnavailable {
            // Expected: the bounded retry cannot produce an empty recording.
        }
        XCTAssertEqual(harness.sessions.count, 2)
        XCTAssertEqual(harness.stoppedSessions, [0, 1])
        XCTAssertEqual(harness.waits, 50)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.url.path))
    }

    func test_cancelDuringRetry_rejectsArrivingFramesAndIgnoresLateCallbacks() async throws {
        let harness = try fixture(plans: [
            .init(initialRate: 48_000, inputRate: nil),
            .init(initialRate: 24_000, inputRate: 24_000),
        ])
        harness.cancelOnAttempt = 1
        do {
            _ = try await harness.start()
            XCTFail("Cancellation must win over arriving audio.")
        } catch is CancellationError {
            // Expected even though the second attempt already wrote real PCM.
        }
        let cancelled = try XCTUnwrap(harness.sessions.last)
        let duration = cancelled.sink.snapshot().duration
        XCTAssertGreaterThan(duration, 0)
        XCTAssertEqual(harness.stoppedSessions, [0, 1])
        try harness.deliverInput(to: cancelled, rate: 24_000)
        XCTAssertEqual(cancelled.sink.snapshot().duration, duration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.url.path))
    }

    /// Each scenario owns a temporary directory and synthesized PCM only.
    private func fixture(plans: [CapturePipelineHarness.Plan]) throws -> CapturePipelineHarness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storybird-capture-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return CapturePipelineHarness(
            url: root.appendingPathComponent("sample.wav"),
            plans: plans
        )
    }

    /// The UI clock must reflect frames actually stored in the normalized WAV.
    private func assertFinalizedWAV(_ session: CapturePipelineHarness.Session) throws {
        let duration = session.sink.snapshot().duration
        session.sink.finish()
        let file = try AVAudioFile(forReading: session.url)
        XCTAssertEqual(file.fileFormat.sampleRate, 24_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mBitsPerChannel, 16)
        XCTAssertGreaterThan(file.length, 0)
        XCTAssertEqual(Double(file.length) / 24_000, duration, accuracy: 1 / 24_000)
    }
}

/// Scripts only the hardware boundary; readiness, conversion, metering and WAV
/// writes run through production code. No microphone or Bluetooth device opens.
@MainActor
private final class CapturePipelineHarness {
    struct Plan {
        let initialRate: Double
        let inputRate: Double?
        var changedRate: Double? = nil
        var initializationError: Int? = nil
    }

    final class Session {
        let id: Int
        let url: URL
        let sink: VoiceCaptureSink
        let plan: Plan
        var currentRate: Double

        init(id: Int, url: URL, sink: VoiceCaptureSink, plan: Plan) {
            self.id = id
            self.url = url
            self.sink = sink
            self.plan = plan
            currentRate = plan.initialRate
        }
    }

    let url: URL
    let plans: [Plan]
    var sessions: [Session] = []
    var stoppedSessions: [Int] = []
    var waits = 0
    var cancelOnAttempt: Int?
    private var cancelled = false

    init(url: URL, plans: [Plan]) {
        self.url = url
        self.plans = plans
    }

    func start() async throws -> Session {
        try await VoiceCaptureStartup.start(
            makeSession: { try self.open() },
            snapshot: { $0.sink.snapshot() },
            inputFormatChanged: { $0.currentRate != $0.plan.initialRate },
            stopSession: { self.stop($0) },
            checkCancellation: {
                if self.cancelled { throw CancellationError() }
                try Task.checkCancellation()
            },
            waitForInput: {
                self.waits += 1
                let session = try XCTUnwrap(self.sessions.last)
                if self.cancelOnAttempt == session.id { self.cancelled = true }
                if let rate = session.plan.changedRate {
                    session.currentRate = rate
                }
                if let rate = session.plan.inputRate {
                    session.currentRate = rate
                    try self.deliverInput(to: session, rate: rate)
                }
            }
        )
    }

    func stop(_ session: Session) {
        session.sink.finish()
        stoppedSessions.append(session.id)
        try? FileManager.default.removeItem(at: session.url)
    }

    func deliverInput(to session: Session, rate: Double) throws {
        let format = try format(rate: rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(rate / 10)
        ))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            samples[0][frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / Float(rate))
        }
        session.sink.consume(buffer)
    }

    private func open() throws -> Session {
        let index = sessions.count
        guard plans.indices.contains(index) else {
            XCTFail("Startup exceeded the scripted attempt budget.")
            throw VoiceProfileError.microphoneUnavailable
        }
        let plan = plans[index]
        let sink = try XCTUnwrap(VoiceCaptureSink(
            file: VoiceCaptureSink.makeFile(at: url),
            sourceFormat: format(rate: plan.initialRate)
        ))
        let session = Session(id: index, url: url, sink: sink, plan: plan)
        XCTAssertEqual(sink.snapshot().duration, 0, "Every new attempt must start empty.")
        sessions.append(session)
        if let code = plan.initializationError {
            // Native construction owns cleanup when prepare/start throws before
            // it can return the session to the startup coordinator.
            stop(session)
            throw NSError(domain: NSOSStatusErrorDomain, code: code)
        }
        return session
    }

    private func format(rate: Double) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 1,
            interleaved: false
        ))
    }
}
