import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

struct ScreenVideoRecordingResult: Sendable {
    let duration: Double
    let width: Int
    let height: Int
}

enum ScreenVideoWriterError: LocalizedError {
    case outputAlreadyExists
    case noFrames
    case cannotCreateWriter
    case appendFailed(String)

    var errorDescription: String? {
        switch self {
        case .outputAlreadyExists:
            return "The recording output already exists."
        case .noFrames:
            return "No video frames were recorded."
        case .cannotCreateWriter:
            return "Storybird could not start the video encoder."
        case let .appendFailed(message):
            return "Storybird could not encode the recording: \(message)"
        }
    }
}

final class ScreenVideoWriter: @unchecked Sendable {
    private struct FinishState {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let first: CMTime
        let last: CMTime
        let frameDuration: CMTime
        let dimensions: (width: Int, height: Int)
    }

    private let outputURL: URL
    private let eventClockProvider: @Sendable () -> Double
    private let lock = NSLock()

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstPresentationTime: CMTime?
    private var firstEventClockSeconds: Double?
    private var lastPresentationTime: CMTime?
    private var lastFrameDuration = CMTime(value: 1, timescale: 30)
    private var dimensions: (width: Int, height: Int)?
    private var failure: Error?
    private var isFinishing = false

    /// Claims one unique project-owned output so no existing recording can be overwritten.
    init(
        outputURL: URL,
        eventClockProvider: @escaping @Sendable () -> Double = {
            ProcessInfo.processInfo.systemUptime
        }
    ) throws {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ScreenVideoWriterError.outputAlreadyExists
        }
        self.outputURL = outputURL
        self.eventClockProvider = eventClockProvider
    }

    /// Appends capture samples in presentation order so the saved video preserves source motion.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let activeWriter: AVAssetWriter
        let activeInput: AVAssetWriterInput
        do {
            lock.lock()
            do {
                guard !isFinishing,
                      failure == nil,
                      presentationTime.isValid,
                      lastPresentationTime.map({
                          CMTimeCompare(presentationTime, $0) > 0
                      }) ?? true
                else {
                    lock.unlock()
                    return
                }
                if writer == nil {
                    try start(
                        pixelBuffer: pixelBuffer,
                        sampleBuffer: sampleBuffer,
                        presentationTime: presentationTime
                    )
                }
                guard let writer, let input else {
                    throw ScreenVideoWriterError.cannotCreateWriter
                }
                activeWriter = writer
                activeInput = input
                lock.unlock()
            } catch {
                lock.unlock()
                throw error
            }

            var waitCount = 0
            while !activeInput.isReadyForMoreMediaData,
                  activeWriter.status == .writing,
                  waitCount < 1_000 {
                Thread.sleep(forTimeInterval: 0.001)
                waitCount += 1
            }
            guard activeWriter.status == .writing else {
                throw activeWriter.error
                    ?? ScreenVideoWriterError.cannotCreateWriter
            }
            guard activeInput.isReadyForMoreMediaData else {
                throw ScreenVideoWriterError.appendFailed(
                    "The video encoder remained backpressured."
                )
            }
            guard activeInput.append(sampleBuffer) else {
                throw activeWriter.error
                    ?? ScreenVideoWriterError.appendFailed(
                        "The video input rejected a frame."
                    )
            }

            lock.lock()
            lastPresentationTime = presentationTime
            let duration = CMSampleBufferGetDuration(sampleBuffer)
            if duration.isValid, duration > .zero {
                lastFrameDuration = duration
            }
            lock.unlock()
        } catch {
            lock.lock()
            failure = error
            lock.unlock()
        }
    }

    /// Returns the host-clock time on the same zero-based timeline used by click metadata.
    func currentTime() -> Double? {
        recordingTime(
            atEventSeconds: eventClockProvider()
        )
    }

    /// Converts an event's system-uptime timestamp onto the first-frame video timeline.
    func recordingTime(atEventSeconds eventSeconds: Double) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let firstEventClockSeconds else { return nil }
        let elapsed = eventSeconds - firstEventClockSeconds
        guard elapsed.isFinite else { return nil }
        return max(elapsed, 0)
    }

    /// Finalizes the complete file only after capture callbacks have stopped appending frames.
    func finish() async throws -> ScreenVideoRecordingResult {
        let state: FinishState
        do {
            state = try prepareToFinish()
        } catch {
            cancel()
            throw error
        }

        state.input.markAsFinished()
        let endTime = CMTimeAdd(state.last, state.frameDuration)
        state.writer.endSession(atSourceTime: endTime)
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            state.writer.finishWriting {
                continuation.resume()
            }
        }

        guard state.writer.status == .completed else {
            let error = state.writer.error
                ?? ScreenVideoWriterError.appendFailed("Finalization failed.")
            cancel()
            throw error
        }
        let duration = CMTimeGetSeconds(
            CMTimeSubtract(endTime, state.first)
        )
        return ScreenVideoRecordingResult(
            duration: max(duration, 0),
            width: state.dimensions.width,
            height: state.dimensions.height
        )
    }

    /// Freezes encoder references synchronously before the asynchronous finalization callback.
    private func prepareToFinish() throws -> FinishState {
        lock.lock()
        defer { lock.unlock() }
        if let failure {
            throw failure
        }
        guard let writer,
              let input,
              let firstPresentationTime,
              let lastPresentationTime,
              let dimensions
        else {
            throw ScreenVideoWriterError.noFrames
        }
        isFinishing = true
        return FinishState(
            writer: writer,
            input: input,
            first: firstPresentationTime,
            last: lastPresentationTime,
            frameDuration: lastFrameDuration,
            dimensions: dimensions
        )
    }

    /// Cancels an incomplete encode and removes only this session's unreferenced output.
    func cancel() {
        lock.lock()
        let writer = self.writer
        isFinishing = true
        lock.unlock()
        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }

    /// Configures one real-time H.264 input from the first ScreenCaptureKit sample.
    private func start(
        pixelBuffer: CVPixelBuffer,
        sampleBuffer: CMSampleBuffer,
        presentationTime: CMTime
    ) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ],
            sourceFormatHint: CMSampleBufferGetFormatDescription(sampleBuffer)
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw ScreenVideoWriterError.cannotCreateWriter
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? ScreenVideoWriterError.cannotCreateWriter
        }
        writer.startSession(atSourceTime: presentationTime)
        self.writer = writer
        self.input = input
        firstPresentationTime = presentationTime
        firstEventClockSeconds = Self.displayTimeSeconds(
            from: sampleBuffer
        ) ?? eventClockProvider()
        dimensions = (width, height)
    }

    /// Converts ScreenCaptureKit display mach time into the system-uptime clock used by mouse events.
    private static func displayTimeSeconds(
        from sampleBuffer: CMSampleBuffer
    ) -> Double? {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]]
        guard let displayTime = attachments?.first?[.displayTime] as? UInt64
        else {
            return nil
        }
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS,
              timebase.denom != 0
        else {
            return nil
        }
        return Double(displayTime)
            * Double(timebase.numer)
            / Double(timebase.denom)
            / 1_000_000_000
    }
}
