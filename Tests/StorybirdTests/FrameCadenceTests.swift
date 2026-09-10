import AVFoundation
import StorybirdCore
import XCTest
@testable import Storybird

@MainActor
final class FrameCadenceTests: XCTestCase {
    func test_validMetadata_avoidsReadingAllSourceSamples() throws {
        var reads = 0
        let metadata = CMTime(value: 1001, timescale: 60_000)
        let duration = VideoFrameCadence.sourceFrameDuration(metadata: metadata) {
            reads += 1
            return CMTime(value: 1, timescale: 30)
        }
        XCTAssertEqual(duration, metadata)
        XCTAssertEqual(reads, 0)
    }

    func test_missingOrInvalidMetadata_measuresExactlyOnceAndPreservesReadFailure() {
        for metadata in [CMTime.zero, .invalid, .indefinite, CMTime(value: -1, timescale: 30)] {
            var reads = 0
            let measured = CMTime(value: 1, timescale: 120)
            let result = VideoFrameCadence.sourceFrameDuration(metadata: metadata) {
                reads += 1
                return measured
            }
            XCTAssertEqual(result, measured)
            XCTAssertEqual(reads, 1)
            XCTAssertThrowsError(try VideoFrameCadence.sourceFrameDuration(metadata: metadata) {
                throw CocoaError(.fileReadCorruptFile)
            }) {
                XCTAssertEqual(($0 as? CocoaError)?.code, .fileReadCorruptFile)
            }
        }
    }

    func test_missingMetadata_readsRealVideoSamplesAndIgnoresCodecMarkers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cadence.mp4")
        _ = try await TestVideoFactory.makeMovie(at: url, includeAudio: false, duration: 0.3)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let measured = try VideoFrameCadence.sourceFrameDuration(metadata: .invalid) {
            try VideoFrameCadence.measuredFrameDuration(sourceAsset: asset, sourceTrack: track)
        }
        XCTAssertEqual(measured.seconds, 1.0 / 30, accuracy: 0.000001)
        let empty = AVMutableComposition()
        let emptyTrack = try XCTUnwrap(empty.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        XCTAssertThrowsError(try VideoFrameCadence.measuredFrameDuration(sourceAsset: empty, sourceTrack: emptyTrack))
    }
}
