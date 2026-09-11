import Foundation

@MainActor
enum VoiceCaptureStartup {
    /// A running engine does not prove that its input transport started. In
    /// the 2026-09-11 AirPods logs, the first 48→24 kHz transition failed with
    /// HAL error 35 while isRunning stayed true; resuming the engine also failed.
    /// Wait for written frames, then rebuild once on the same device if needed.
    static func start<Session>(
        makeSession: () throws -> Session,
        snapshot: (Session) -> VoiceCaptureSnapshot,
        inputFormatChanged: (Session) -> Bool = { _ in false },
        stopSession: (Session) -> Void,
        checkCancellation: () throws -> Void,
        waitForInput: () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(80))
        }
    ) async throws -> Session {
        for attempt in 0..<2 {
            try checkCancellation()
            let session: Session
            do {
                session = try makeSession()
            } catch {
                // The AirPods format transition can also fail prepare/start
                // itself (-10868), before a session exists to poll. The factory
                // cleans up that partial attempt; retry within the same budget.
                if error is CancellationError { throw error }
                try checkCancellation()
                guard attempt == 0 else { throw error }
                try await waitForInput()
                continue
            }
            do {
                // Allow up to two seconds for the input transport to settle.
                for poll in 0...25 {
                    try checkCancellation()
                    let state = snapshot(session)
                    guard state.failure == nil else {
                        throw VoiceProfileError.microphoneUnavailable
                    }
                    // Silent PCM still advances duration and is valid input.
                    if state.duration > 0 {
                        return session
                    }
                    // The 16:01 AirPods trace changed the tap's 48 kHz input
                    // to 24 kHz before start, then waited 2.2 s without frames.
                    // Rebuild that stale first attempt immediately. Keep the
                    // last attempt's full budget for hardware still settling.
                    if attempt == 0, inputFormatChanged(session) {
                        break
                    }
                    if poll < 25 {
                        try await waitForInput()
                    }
                }
            } catch {
                stopSession(session)
                throw error
            }
            stopSession(session)
        }
        throw VoiceProfileError.microphoneUnavailable
    }
}
