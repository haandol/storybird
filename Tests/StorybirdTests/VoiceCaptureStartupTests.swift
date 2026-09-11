import Foundation
import XCTest
@testable import Storybird

@MainActor
final class VoiceCaptureStartupTests: XCTestCase {
    func test_initializationThrowsFormatError_retriesAndWaitsForActualInput() async throws {
        let receiving = Session()
        var opens = 0
        var waits = 0
        let capture = try await VoiceCaptureStartup.start(
            makeSession: {
                opens += 1
                if opens == 1 {
                    throw NSError(domain: NSOSStatusErrorDomain, code: -10868)
                }
                return receiving
            },
            snapshot: { $0.snapshot },
            stopSession: { $0.stops += 1 },
            checkCancellation: {},
            waitForInput: {
                waits += 1
                if opens == 2 { receiving.duration = 0.08 }
            }
        )

        XCTAssertTrue(capture === receiving)
        XCTAssertEqual(opens, 2)
        XCTAssertEqual(waits, 2)
        XCTAssertEqual(receiving.stops, 0)
        XCTAssertGreaterThan(receiving.snapshot.duration, 0)
    }

    func test_repeatedInitializationFailure_stopsAtAttemptBudgetAndPreservesLastError() async {
        var opens = 0
        var waits = 0
        do {
            _ = try await VoiceCaptureStartup.start(
                makeSession: { () throws -> Session in
                    opens += 1
                    throw NSError(domain: NSOSStatusErrorDomain, code: -10868)
                },
                snapshot: { $0.snapshot },
                stopSession: { _ in XCTFail("The factory never transferred a session.") },
                checkCancellation: {},
                waitForInput: { waits += 1 }
            )
            XCTFail("Repeated initialization errors must fail.")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSOSStatusErrorDomain)
            XCTAssertEqual((error as NSError).code, -10868)
        }
        XCTAssertEqual(opens, 2)
        XCTAssertEqual(waits, 1)
    }

    func test_cancelAfterInitializationFailure_neverOpensRetry() async {
        var opens = 0
        var cancelled = false
        do {
            _ = try await VoiceCaptureStartup.start(
                makeSession: { () throws -> Session in
                    opens += 1
                    throw NSError(domain: NSOSStatusErrorDomain, code: -10868)
                },
                snapshot: { $0.snapshot },
                stopSession: { _ in XCTFail("The factory never transferred a session.") },
                checkCancellation: {
                    if cancelled { throw CancellationError() }
                },
                waitForInput: { cancelled = true }
            )
            XCTFail("Cancelled startup must not retry.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(opens, 1)
    }

    func test_staleInputFormatWithoutFrames_rebuildsBeforeTimeoutAndLetsRetrySettle() async throws {
        let stalled = Session()
        let receiving = Session()
        var sessions = [stalled, receiving]
        var waits = 0

        let capture = try await VoiceCaptureStartup.start(
            makeSession: { sessions.removeFirst() },
            snapshot: { $0.snapshot },
            inputFormatChanged: { _ in true },
            stopSession: { $0.stops += 1 },
            checkCancellation: {},
            waitForInput: {
                waits += 1
                if waits == 2 { receiving.duration = 0.08 }
            }
        )

        XCTAssertTrue(capture === receiving)
        XCTAssertEqual(stalled.stops, 1)
        XCTAssertEqual(receiving.stops, 0)
        XCTAssertEqual(waits, 2, "A known format mismatch must not consume the no-input timeout.")
    }

    func test_inputArrivesDespiteFormatChange_keepsReceivingSession() async throws {
        let receiving = Session()
        var opens = 0
        var waits = 0
        let capture = try await VoiceCaptureStartup.start(
            makeSession: { opens += 1; return receiving },
            snapshot: { $0.snapshot },
            inputFormatChanged: { _ in waits > 0 },
            stopSession: { $0.stops += 1 },
            checkCancellation: {},
            waitForInput: {
                waits += 1
                receiving.duration = 0.08
            }
        )

        XCTAssertTrue(capture === receiving)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(receiving.stops, 0)
        XCTAssertEqual(waits, 1)
    }

    func test_firstEngineRunsWithoutInput_rebuildsAndReturnsOnlyReceivingSession() async throws {
        let stalled = Session()
        let receiving = Session()
        var sessions = [stalled, receiving]
        var waits = 0

        let capture = try await VoiceCaptureStartup.start(
            makeSession: { sessions.removeFirst() },
            snapshot: { $0.snapshot },
            stopSession: { $0.stops += 1 },
            checkCancellation: {},
            waitForInput: {
                waits += 1
                if sessions.isEmpty {
                    receiving.duration = 0.08
                }
            }
        )

        XCTAssertTrue(capture === receiving)
        XCTAssertEqual(stalled.stops, 1)
        XCTAssertEqual(receiving.stops, 0)
        XCTAssertEqual(waits, 26)
        XCTAssertGreaterThan(capture.snapshot.duration, 0)
    }

    func test_firstInputIsSilent_acceptsWrittenFramesWithoutRebuilding() async throws {
        let session = Session()
        var opens = 0
        let capture = try await VoiceCaptureStartup.start(
            makeSession: { opens += 1; return session },
            snapshot: { $0.snapshot },
            stopSession: { $0.stops += 1 },
            checkCancellation: {},
            waitForInput: { session.duration = 0.08 }
        )

        XCTAssertTrue(capture === session)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(session.stops, 0)
        XCTAssertEqual(capture.snapshot.decibels, -80)
    }

    func test_bothEnginesReceiveNoFrames_stopsBothAndFailsInsteadOfHanging() async {
        var sessions: [Session] = []
        var waits = 0
        do {
            _ = try await VoiceCaptureStartup.start(
                makeSession: {
                    let session = Session()
                    sessions.append(session)
                    return session
                },
                snapshot: { $0.snapshot },
                stopSession: { $0.stops += 1 },
                checkCancellation: {},
                waitForInput: { waits += 1 }
            )
            XCTFail("An engine with no audio must not become an active recording.")
        } catch {
            XCTAssertTrue(error is VoiceProfileError)
        }
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.map(\.stops), [1, 1])
        XCTAssertEqual(waits, 50)
    }

    func test_cancelWhileWaiting_closesPendingSessionAndNeverRetries() async {
        let pending = Session()
        var cancelled = false
        var opens = 0
        do {
            _ = try await VoiceCaptureStartup.start(
                makeSession: { opens += 1; return pending },
                snapshot: { $0.snapshot },
                stopSession: { $0.stops += 1 },
                checkCancellation: {
                    if cancelled { throw CancellationError() }
                },
                waitForInput: {
                    cancelled = true
                    pending.duration = 0.08
                }
            )
            XCTFail("Late input must not publish a cancelled session.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(pending.stops, 1)
    }

    func test_waitCancellation_stopsPendingCapture() async {
        let session = Session()
        do {
            _ = try await VoiceCaptureStartup.start(
                makeSession: { session },
                snapshot: { $0.snapshot },
                stopSession: { $0.stops += 1 },
                checkCancellation: {},
                waitForInput: { throw CancellationError() }
            )
            XCTFail("Cancelled polling must fail.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(session.stops, 1)
    }

    func test_failedSinkWithWrittenFrames_stopsAndRejectsPartialAudio() async {
        let session = Session()
        session.duration = 0.08
        session.failure = "Synthetic write failure"
        do {
            _ = try await VoiceCaptureStartup.start(
                makeSession: { session },
                snapshot: { $0.snapshot },
                stopSession: { $0.stops += 1 },
                checkCancellation: {},
                waitForInput: { XCTFail("A failed writer must fail immediately.") }
            )
            XCTFail("Partial failed audio must not become ready.")
        } catch {
            XCTAssertTrue(error is VoiceProfileError)
        }
        XCTAssertEqual(session.stops, 1)
    }
}

@MainActor
private final class Session {
    var duration = 0.0
    var failure: String?
    var stops = 0

    var snapshot: VoiceCaptureSnapshot {
        VoiceCaptureSnapshot(duration: duration, decibels: -80, failure: failure)
    }
}
