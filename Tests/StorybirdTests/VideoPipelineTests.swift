import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import ScreenCaptureKit
import StorybirdCore
@testable import Storybird
import XCTest

final class VideoPipelineTests: XCTestCase {
    func test_liveVoiceRuntime_generatesProjectWAVWithMLX8BitModel() async throws {
        guard ProcessInfo.processInfo.environment[
            "STORYBIRD_RUN_VOICE_E2E"
        ] == "1",
            let python = ProcessInfo.processInfo.environment[
                "STORYBIRD_VOICE_PYTHON"
            ],
            let hfHome = ProcessInfo.processInfo.environment[
                "STORYBIRD_VOICE_HF_HOME"
            ],
            let reference = ProcessInfo.processInfo.environment[
                "STORYBIRD_VOICE_REFERENCE"
            ]
        else {
            throw XCTSkip("Run explicitly with the prepared MLX voice runtime.")
        }
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent(
            "VoiceRuntime",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true
        )
        try Data(VoiceSynthesisService.modelID.utf8).write(
            to: runtime.appendingPathComponent("model-ready.txt")
        )
        setenv("STORYBIRD_VOICE_PYTHON", python, 1)
        setenv("STORYBIRD_VOICE_HF_HOME", hfHome, 1)
        defer {
            unsetenv("STORYBIRD_VOICE_PYTHON")
            unsetenv("STORYBIRD_VOICE_HF_HOME")
        }
        let output = root.appendingPathComponent("narration.wav")
        let service = VoiceSynthesisService(rootURL: root)

        let result = try await service.generate(
            text: "Welcome to the Storybird service demonstration.",
            referenceAudioURL: URL(fileURLWithPath: reference),
            referenceText:
                "Hello, this is the Yelena reference sample used for clone testing.",
            language: "english",
            outputURL: output
        )

        let tracks = try await AVURLAsset(url: output).loadTracks(
            withMediaType: .audio
        )
        XCTAssertGreaterThan(result.duration, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(tracks.count, 1)
    }

    @MainActor
    func test_liveAgentVoiceNarration_generatesAndExportsDemo() async throws {
        guard ProcessInfo.processInfo.environment[
            "STORYBIRD_RUN_VOICE_E2E"
        ] == "1",
            ProcessInfo.processInfo.environment[
                "STORYBIRD_VOICE_PYTHON"
            ] != nil,
            ProcessInfo.processInfo.environment[
                "STORYBIRD_VOICE_HF_HOME"
            ] != nil,
            let referencePath = ProcessInfo.processInfo.environment[
                "STORYBIRD_VOICE_REFERENCE"
            ]
        else {
            throw XCTSkip("Run explicitly with the prepared MLX voice runtime.")
        }
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        try repository.prepare()
        let runtime = root.appendingPathComponent(
            "VoiceRuntime",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true
        )
        try Data(VoiceSynthesisService.modelID.utf8).write(
            to: runtime.appendingPathComponent("model-ready.txt")
        )
        let profile = VoiceProfile(
            name: "Agent demo voice",
            referenceFilename: "reference.wav",
            referenceText:
                "Hello, this is the Yelena reference sample used for clone testing.",
            language: "english",
            consentConfirmed: true
        )
        let profileTarget = try repository.prepareVoiceReferenceURL(
            profileID: profile.id,
            fileExtension: "wav"
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: referencePath),
            to: profileTarget.url
        )
        try repository.saveVoiceProfiles([profile])
        let projectID = UUID()
        let source = try repository.prepareVideoRecordingURL(
            projectID: projectID
        )
        let video = try await TestVideoFactory.makeMovie(
            at: source.url,
            includeAudio: false,
            duration: 8
        )
        let project = DemoProject(
            id: projectID,
            name: "Agent voice demo",
            recording: VideoRecordingAsset(
                filename: source.filename,
                duration: video.duration,
                width: video.width,
                height: video.height
            )
        )
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let arguments = try JSONSerialization.data(
            withJSONObject: [
                "project_id": project.id.uuidString,
                "expected_revision": 0,
                "voice_profile_id": profile.id.uuidString,
                "text": "Welcome to Storybird.",
                "language": "english",
                "start_time": 1.0,
            ]
        )

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_generate_narration",
                argumentsJSON: arguments
            )
        )
        XCTAssertFalse(response.isError)
        let narrated = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(narrated.revision, 1)
        XCTAssertEqual(narrated.narrations.count, 1)
        let output = root.appendingPathComponent("agent-demo.mp4")
        _ = try await LayeredVideoExporter().export(
            project: narrated,
            sourceURL: source.url,
            destinationURL: output
        )
        let audioTracks = try await AVURLAsset(url: output).loadTracks(
            withMediaType: .audio
        )
        let amplitude = try await TestVideoFactory.averageAmplitude(
            in: output,
            from: 1.2,
            to: min(
                6,
                1 + narrated.narrations[0].duration
            )
        )
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertGreaterThan(amplitude, 0.005)
    }
    func test_textRaster_containsVisibleWhiteGlyphPixels() throws {
        let image = try XCTUnwrap(
            LayeredVideoExporter.makeTextImage(
                "New subtitle",
                fontSize: 20,
                size: CGSize(width: 116, height: 24)
            )
        )

        XCTAssertGreaterThan(
            try brightPixelCount(in: image),
            20
        )
    }

    func test_screenVideoWriter_writesSilentH264MP4() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("raw.mp4")
        let writer = try ScreenVideoWriter(outputURL: output)

        for frame in 0..<6 {
            writer.append(
                try sampleBuffer(
                    red: 0,
                    green: 0,
                    blue: 255,
                    presentationTime: CMTime(
                        value: CMTimeValue(frame),
                        timescale: 30
                    )
                )
            )
        }
        let result = try await writer.finish()

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(result.width, 64)
        XCTAssertEqual(result.height, 48)
        XCTAssertEqual(result.duration, 0.2, accuracy: 0.04)

        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let exportedDuration = try await asset.load(.duration)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertTrue(audioTracks.isEmpty)
        XCTAssertEqual(
            CMTimeGetSeconds(exportedDuration),
            result.duration,
            accuracy: 0.05
        )
        let formats = try await videoTracks[0].load(.formatDescriptions)
        XCTAssertEqual(
            formats.first.map(CMFormatDescriptionGetMediaSubType),
            kCMVideoCodecType_H264
        )
    }

    func test_screenVideoWriter_nonzeroPTS_mapsMouseDownHostTimeToVideoTime() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("clock.mp4")
        let writer = try ScreenVideoWriter(
            outputURL: output,
            eventClockProvider: {
                999
            }
        )
        writer.append(
            try sampleBuffer(
                red: 0,
                green: 0,
                blue: 255,
                presentationTime: CMTime(
                    seconds: 100,
                    preferredTimescale: 600
                ),
                displayTimeSeconds: 50
            )
        )

        let clickTime = try XCTUnwrap(
            writer.recordingTime(atEventSeconds: 50.25)
        )
        _ = try await writer.finish()

        XCTAssertEqual(clickTime, 0.25, accuracy: 0.001)
    }

    func test_screenVideoWriter_noFrames_removesPartialOutput() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("empty.mp4")
        let writer = try ScreenVideoWriter(outputURL: output)

        do {
            _ = try await writer.finish()
            XCTFail("Expected no-frame failure")
        } catch ScreenVideoWriterError.noFrames {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: output.path)
            )
        }
    }

    func test_layeredVideoExporter_clickAtCenter_changesCenterPixels() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("raw.mp4")
        let output = root.appendingPathComponent("export.mp4")
        let writer = try ScreenVideoWriter(outputURL: raw)
        for frame in 0..<30 {
            writer.append(
                try sampleBuffer(
                    red: 0,
                    green: 0,
                    blue: 255,
                    width: 320,
                    height: 180,
                    presentationTime: CMTime(
                        value: CMTimeValue(frame),
                        timescale: 30
                    )
                )
            )
        }
        let rawResult = try await writer.finish()
        XCTAssertEqual(rawResult.duration, 1, accuracy: 0.04)
        var completeCue = TimedPointerClick(
            time: 0.4,
            x: 0.5,
            y: 0.5,
            caption: "Click"
        )
        completeCue.cueSubtitle.text = "Cue subtitle"
        completeCue.cueSubtitle.position = .top
        completeCue = completeCue.bounded(to: rawResult.duration)
        let project = DemoProject(
            name: "Overlay",
            recording: VideoRecordingAsset(
                filename: raw.lastPathComponent,
                duration: rawResult.duration,
                width: rawResult.width,
                height: rawResult.height
            ),
            clicks: [completeCue],
            subtitles: [],
            theme: DemoTheme(
                accentHex: "#FF0000",
                backgroundHex: "#11131A",
                showsBranding: false
            )
        )

        let exporter = LayeredVideoExporter()
        let previewData = try await exporter.previewPNG(
            project: project,
            sourceURL: raw,
            projectTime: 0.45
        )
        let previewSource = try XCTUnwrap(
            CGImageSourceCreateWithData(previewData as CFData, nil)
        )
        let previewImage = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(previewSource, 0, nil)
        )
        XCTAssertGreaterThan(try brightPixelCount(in: previewImage), 20)

        _ = try await exporter.export(
            project: project,
            sourceURL: raw,
            destinationURL: output
        )

        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let exportedDuration = try await asset.load(.duration)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertTrue(audioTracks.isEmpty)
        XCTAssertEqual(
            CMTimeGetSeconds(exportedDuration),
            rawResult.duration,
            accuracy: 0.05
        )
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let image = try await generator.image(
            at: CMTime(seconds: 0.45, preferredTimescale: 600)
        ).image
        let center = try pixel(
            in: image,
            x: image.width / 2,
            y: image.height / 2
        )

        XCTAssertGreaterThan(center.red, 10)
        XCTAssertLessThan(center.blue, 255)
    }

    func test_layeredVideoExporter_customDescription_keepsRingAtClickPosition() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("raw.mp4")
        let writer = try ScreenVideoWriter(outputURL: raw)
        for frame in 0..<30 {
            writer.append(
                try sampleBuffer(
                    red: 0,
                    green: 0,
                    blue: 255,
                    width: 320,
                    height: 180,
                    presentationTime: CMTime(
                        value: CMTimeValue(frame),
                        timescale: 30
                    )
                )
            )
        }
        let result = try await writer.finish()
        var click = TimedPointerClick(
            time: 0.4,
            x: 0.2,
            y: 0.5,
            caption: "Custom description"
        ).bounded(to: result.duration)
        click.indicator.colorHex = "#FF0000"
        click.description.position = .custom
        click.description.x = 0.9
        click.description.y = 0.5
        let project = DemoProject(
            name: "Custom description",
            recording: VideoRecordingAsset(
                filename: raw.lastPathComponent,
                duration: result.duration,
                width: result.width,
                height: result.height
            ),
            clicks: [click]
        )

        let data = try await LayeredVideoExporter().previewPNG(
            project: project,
            sourceURL: raw,
            projectTime: 0.45
        )
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(data as CFData, nil)
        )
        let image = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(source, 0, nil)
        )
        let bounds = try XCTUnwrap(redDominantBounds(in: image))

        XCTAssertLessThan(
            bounds.midX / CGFloat(image.width),
            0.4
        )
    }

    func test_layeredVideoExporter_titleCardPreview_rendersCardStyle() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("raw.mp4")
        let writer = try ScreenVideoWriter(outputURL: raw)
        for frame in 0..<30 {
            writer.append(
                try sampleBuffer(
                    red: 0,
                    green: 0,
                    blue: 255,
                    width: 320,
                    height: 180,
                    presentationTime: CMTime(
                        value: CMTimeValue(frame),
                        timescale: 30
                    )
                )
            )
        }
        let result = try await writer.finish()
        var project = DemoProject(
            name: "Title preview",
            recording: VideoRecordingAsset(
                filename: raw.lastPathComponent,
                duration: result.duration,
                width: result.width,
                height: result.height
            )
        )
        project = try DemoEffectEditor.insertTitle(
            in: project,
            after: nil,
            duration: 1,
            title: "Welcome"
        )
        guard case var .title(title) = project.effects[0] else {
            return XCTFail("Expected title")
        }
        title.style = TextOverlayStyle(
            backgroundHex: "#FF0000",
            backgroundOpacity: 1,
            foregroundHex: "#00FF00",
            fontSize: 24
        )
        project.effects[0] = .title(title)

        let data = try await LayeredVideoExporter().previewPNG(
            project: project,
            sourceURL: raw,
            projectTime: 0.5
        )
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(data as CFData, nil)
        )
        let image = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(source, 0, nil)
        )
        let corner = try pixel(in: image, x: 4, y: 4)

        XCTAssertGreaterThan(corner.red, 220)
        XCTAssertLessThan(corner.green, 60)
        XCTAssertLessThan(corner.blue, 60)
    }

    func test_layeredVideoExporter_tenReferenceProjectsLoseNoTextOrEffects() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("reference.mp4")
        let result = try await TestVideoFactory.makeMovie(
            at: raw,
            includeAudio: false
        )

        for index in 0..<10 {
            var cue = TimedPointerClick(
                time: 0.4,
                x: 0.5,
                y: 0.5,
                caption: "Click \(index)"
            ).bounded(to: result.duration)
            cue.cueSubtitle.text = "Cue \(index)"
            let subtitle = TimedSubtitle(
                startTime: 0.2,
                endTime: 0.8,
                text: "Subtitle \(index)",
                position: index.isMultiple(of: 2) ? .top : .bottom
            )
            let spotlight = SpotlightEffect(
                startTime: 0.2,
                endTime: 0.8,
                x: 0.35,
                y: 0.35,
                width: 0.3,
                height: 0.3
            )
            let panZoom = PanZoomEffect(
                startTime: 0.2,
                endTime: 0.8,
                endX: 0.5,
                endY: 0.5,
                endScale: 1.2
            )
            let project = DemoProject(
                name: "Reference \(index)",
                recording: VideoRecordingAsset(
                    filename: raw.lastPathComponent,
                    duration: result.duration,
                    width: result.width,
                    height: result.height
                ),
                clicks: [cue],
                subtitles: [subtitle],
                effects: [
                    .spotlight(spotlight),
                    .panZoom(panZoom),
                ]
            )
            let expectedIDs = Set(
                VideoOverlayPresentation.visibleLayerIDs(
                    in: project,
                    at: 0.45
                )
            )
            XCTAssertEqual(expectedIDs.count, 4)
            let output = root.appendingPathComponent(
                "reference-\(index).mp4"
            )

            _ = try await LayeredVideoExporter().export(
                project: project,
                sourceURL: raw,
                destinationURL: output
            )

            let asset = AVURLAsset(url: output)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let image = try await generator.image(
                at: CMTime(
                    seconds: 0.45,
                    preferredTimescale: 600
                )
            ).image
            let corner = try pixel(in: image, x: 3, y: 3)
            XCTAssertGreaterThan(try brightPixelCount(in: image), 20)
            XCTAssertLessThan(corner.blue, 250)
        }
    }

    func test_layeredVideoExporter_invalidSource_preservesExistingOutput() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing.mp4")
        let output = root.appendingPathComponent("existing.mp4")
        let original = Data("existing".utf8)
        try original.write(to: output)
        let project = DemoProject(
            name: "Failure",
            recording: VideoRecordingAsset(
                filename: "missing.mp4",
                duration: 1,
                width: 64,
                height: 48
            )
        )

        do {
            _ = try await LayeredVideoExporter().export(
                project: project,
                sourceURL: missing,
                destinationURL: output
            )
            XCTFail("Expected export failure")
        } catch {
            XCTAssertEqual(try Data(contentsOf: output), original)
        }
    }

    func test_layeredVideoExporter_incompleteClickCue_isRejected() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("raw.mp4")
        let output = root.appendingPathComponent("output.mp4")
        let writer = try ScreenVideoWriter(outputURL: raw)
        writer.append(
            try sampleBuffer(
                red: 0,
                green: 0,
                blue: 255,
                presentationTime: .zero
            )
        )
        let result = try await writer.finish()
        let incompleteCue = TimedPointerClick(
            time: 0,
            x: 0.5,
            y: 0.5
        ).bounded(to: result.duration)
        let project = DemoProject(
            name: "Incomplete",
            recording: VideoRecordingAsset(
                filename: raw.lastPathComponent,
                duration: result.duration,
                width: result.width,
                height: result.height
            ),
            clicks: [incompleteCue]
        )

        do {
            _ = try await LayeredVideoExporter().export(
                project: project,
                sourceURL: raw,
                destinationURL: output
            )
            XCTFail("Expected incomplete cue rejection")
        } catch LayeredVideoExportError.incompleteClickCue {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func test_layeredVideoExporter_emptyTimeline_isRejectedBeforeRendering() {
        var project = DemoProject(
            name: "Empty timeline",
            recording: VideoRecordingAsset(
                filename: "recording.mp4",
                duration: 1,
                width: 64,
                height: 48
            )
        )
        project.clips = []

        XCTAssertThrowsError(
            try LayeredVideoExporter.validateForExport(project)
        )
    }

    func test_layeredVideoExporter_speedEdit_changesOutputDuration() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("raw.mp4")
        let output = root.appendingPathComponent("output.mp4")
        let writer = try ScreenVideoWriter(outputURL: raw)
        for frame in 0..<30 {
            writer.append(
                try sampleBuffer(
                    red: 0,
                    green: 0,
                    blue: 255,
                    presentationTime: CMTime(
                        value: CMTimeValue(frame),
                        timescale: 30
                    )
                )
            )
        }
        let result = try await writer.finish()
        var project = DemoProject(
            name: "Speed",
            recording: VideoRecordingAsset(
                filename: raw.lastPathComponent,
                duration: result.duration,
                width: result.width,
                height: result.height
            )
        )
        let clipID = try XCTUnwrap(project.clips.first?.id)
        project = try VideoTimelineEditor.setSpeed(
            project: project,
            clipID: clipID,
            rate: 2
        )

        _ = try await LayeredVideoExporter().export(
            project: project,
            sourceURL: raw,
            destinationURL: output
        )

        let exported = AVURLAsset(url: output)
        let exportedDuration = try await exported.load(.duration)
        XCTAssertEqual(
            CMTimeGetSeconds(exportedDuration),
            0.5,
            accuracy: 0.08
        )
    }

    func test_layeredVideoExporter_narratedSpeedEdit_preservesOneAACTrack() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("narrated.mov")
        let output = root.appendingPathComponent("output.mp4")
        let result = try await TestVideoFactory.makeMovie(
            at: raw,
            fileType: .mov,
            includeAudio: true
        )
        var project = DemoProject(
            name: "Narrated",
            recording: VideoRecordingAsset(
                filename: raw.lastPathComponent,
                duration: result.duration,
                width: result.width,
                height: result.height
            )
        )
        project = try VideoTimelineEditor.setSpeed(
            project: project,
            clipID: try XCTUnwrap(project.clips.first?.id),
            rate: 2
        )

        _ = try await LayeredVideoExporter().export(
            project: project,
            sourceURL: raw,
            destinationURL: output
        )

        let exported = AVURLAsset(url: output)
        let videoTracks = try await exported.loadTracks(
            withMediaType: .video
        )
        let audioTracks = try await exported.loadTracks(
            withMediaType: .audio
        )
        let duration = CMTimeGetSeconds(try await exported.load(.duration))
        let formats = try await XCTUnwrap(audioTracks.first).load(
            .formatDescriptions
        )

        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertEqual(duration, 0.5, accuracy: 0.08)
        XCTAssertEqual(
            formats.first.map(CMFormatDescriptionGetMediaSubType),
            kAudioFormatMPEG4AAC
        )
        let amplitude = try await TestVideoFactory.averageAmplitude(
            in: output,
            from: 0.1,
            to: 0.4
        )
        XCTAssertGreaterThan(amplitude, 0.02)
    }

    func test_layeredVideoExporter_shortAndOffsetNarrationFillSilenceToVideoBounds() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for (name, audioStart, audioDuration, silentRange, audibleRange) in [
            ("short", 0.0, 0.5, 0.65...0.9, 0.1...0.4),
            ("offset", 0.5, 0.5, 0.1...0.35, 0.65...0.9),
        ] {
            let source = root.appendingPathComponent("\(name).mov")
            let output = root.appendingPathComponent("\(name)-output.mp4")
            let result = try await TestVideoFactory.makeMovie(
                at: source,
                fileType: .mov,
                includeAudio: true,
                audioStart: audioStart,
                audioDuration: audioDuration
            )
            let project = DemoProject(
                name: name,
                recording: VideoRecordingAsset(
                    filename: source.lastPathComponent,
                    duration: result.duration,
                    width: result.width,
                    height: result.height
                )
            )

            _ = try await LayeredVideoExporter().export(
                project: project,
                sourceURL: source,
                destinationURL: output
            )

            let asset = AVURLAsset(url: output)
            let videoTracks = try await asset.loadTracks(
                withMediaType: .video
            )
            let audioTracks = try await asset.loadTracks(
                withMediaType: .audio
            )
            let videoTrack = try XCTUnwrap(
                videoTracks.first
            )
            let audioTrack = try XCTUnwrap(
                audioTracks.first
            )
            let videoRange = try await videoTrack.load(.timeRange)
            let audioRange = try await audioTrack.load(.timeRange)
            let frame = 1.0 / 30.0
            let silentAmplitude =
                try await TestVideoFactory.averageAmplitude(
                    in: output,
                    from: silentRange.lowerBound,
                    to: silentRange.upperBound
                )
            let audibleAmplitude =
                try await TestVideoFactory.averageAmplitude(
                    in: output,
                    from: audibleRange.lowerBound,
                    to: audibleRange.upperBound
                )

            XCTAssertEqual(
                CMTimeGetSeconds(audioRange.start),
                CMTimeGetSeconds(videoRange.start),
                accuracy: frame
            )
            XCTAssertEqual(
                CMTimeGetSeconds(audioRange.end),
                CMTimeGetSeconds(videoRange.end),
                accuracy: frame
            )
            XCTAssertLessThan(silentAmplitude, 0.01)
            XCTAssertGreaterThan(audibleAmplitude, 0.02)
        }
    }

    func test_layeredVideoExporter_titleAndFreezeIntervalsAreSilent() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("narrated.mov")
        let result = try await TestVideoFactory.makeMovie(
            at: source,
            fileType: .mov,
            includeAudio: true
        )

        var titleProject = DemoProject(
            name: "Title silence",
            recording: VideoRecordingAsset(
                filename: source.lastPathComponent,
                duration: result.duration,
                width: result.width,
                height: result.height
            )
        )
        titleProject = try DemoEffectEditor.insertTitle(
            in: titleProject,
            after: nil,
            duration: 1,
            title: "Title"
        )
        let titleOutput = root.appendingPathComponent("title.mp4")
        _ = try await LayeredVideoExporter().export(
            project: titleProject,
            sourceURL: source,
            destinationURL: titleOutput
        )
        let titleSilence = try await TestVideoFactory.averageAmplitude(
            in: titleOutput,
            from: 0.1,
            to: 0.8
        )
        let titleNarration = try await TestVideoFactory.averageAmplitude(
            in: titleOutput,
            from: 1.1,
            to: 1.8
        )
        XCTAssertLessThan(titleSilence, 0.01)
        XCTAssertGreaterThan(titleNarration, 0.02)

        var freezeProject = DemoProject(
            name: "Freeze silence",
            recording: VideoRecordingAsset(
                filename: source.lastPathComponent,
                duration: result.duration,
                width: result.width,
                height: result.height
            )
        )
        freezeProject = try VideoTimelineEditor.insertFreeze(
            project: freezeProject,
            after: try XCTUnwrap(freezeProject.clips.first?.id),
            sourceTime: 0.8,
            duration: 1
        )
        let freezeOutput = root.appendingPathComponent("freeze.mp4")
        _ = try await LayeredVideoExporter().export(
            project: freezeProject,
            sourceURL: source,
            destinationURL: freezeOutput
        )
        let freezeNarration = try await TestVideoFactory.averageAmplitude(
            in: freezeOutput,
            from: 0.1,
            to: 0.8
        )
        let freezeSilence = try await TestVideoFactory.averageAmplitude(
            in: freezeOutput,
            from: 1.1,
            to: 1.8
        )
        XCTAssertGreaterThan(freezeNarration, 0.02)
        XCTAssertLessThan(freezeSilence, 0.01)
    }

    func test_layeredVideoExporter_projectNarrationMixesAtRequestedTime() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        let narration = root.appendingPathComponent("narration.wav")
        let output = root.appendingPathComponent("output.mp4")
        let result = try await TestVideoFactory.makeMovie(
            at: source,
            includeAudio: false
        )
        try TestVideoFactory.makeToneWAV(
            at: narration,
            duration: 0.4
        )
        let project = DemoProject(
            name: "Narration mix",
            recording: VideoRecordingAsset(
                filename: source.lastPathComponent,
                duration: result.duration,
                width: result.width,
                height: result.height
            ),
            narrations: [
                NarrationClip(
                    voiceProfileID: UUID(),
                    filename: narration.lastPathComponent,
                    text: "서비스 소개",
                    startTime: 0.3,
                    duration: 0.4
                ),
            ]
        )

        _ = try await LayeredVideoExporter().export(
            project: project,
            sourceURL: source,
            destinationURL: output
        )

        let asset = AVURLAsset(url: output)
        let audioTracks = try await asset.loadTracks(
            withMediaType: .audio
        )
        XCTAssertEqual(audioTracks.count, 1)
        let before = try await TestVideoFactory.averageAmplitude(
            in: output,
            from: 0.05,
            to: 0.2
        )
        let during = try await TestVideoFactory.averageAmplitude(
            in: output,
            from: 0.35,
            to: 0.6
        )
        let after = try await TestVideoFactory.averageAmplitude(
            in: output,
            from: 0.8,
            to: 0.95
        )
        XCTAssertLessThan(before, 0.01)
        XCTAssertGreaterThan(during, 0.02)
        XCTAssertLessThan(after, 0.01)
    }

    @MainActor
    func test_videoPlaybackModel_compositionFailureDoesNotShowRawFallback() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        try await TestVideoFactory.makeAudioOnlyMovie(at: source)
        let project = DemoProject(
            name: "Invalid preview",
            recording: VideoRecordingAsset(
                filename: source.lastPathComponent,
                duration: 1,
                width: 64,
                height: 48
            )
        )

        let playback = VideoPlaybackModel(url: source, project: project)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(playback.player.currentItem)
        XCTAssertNotNil(playback.errorMessage)
        XCTAssertEqual(playback.duration, 0)
    }

    func test_layeredVideoExporter_titleCard_extendsOutputDuration() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("raw.mp4")
        let output = root.appendingPathComponent("output.mp4")
        let writer = try ScreenVideoWriter(outputURL: raw)
        for frame in 0..<30 {
            writer.append(
                try sampleBuffer(
                    red: 0,
                    green: 0,
                    blue: 255,
                    presentationTime: CMTime(
                        value: CMTimeValue(frame),
                        timescale: 30
                    )
                )
            )
        }
        let result = try await writer.finish()
        var project = DemoProject(
            name: "Title",
            recording: VideoRecordingAsset(
                filename: raw.lastPathComponent,
                duration: result.duration,
                width: result.width,
                height: result.height
            )
        )
        project = try DemoEffectEditor.insertTitle(
            in: project,
            after: nil,
            duration: 1,
            title: "Welcome"
        )

        _ = try await LayeredVideoExporter().export(
            project: project,
            sourceURL: raw,
            destinationURL: output
        )

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2, accuracy: 0.08)
    }

    func test_releaseBenchmark_1080p120Seconds_exportsWithin240Seconds() async throws {
        guard ProcessInfo.processInfo.environment[
            "STORYBIRD_RUN_EXPORT_BENCHMARK"
        ] == "1" else {
            throw XCTSkip("Run explicitly for release performance evidence.")
        }
        let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        guard FileManager.default.fileExists(atPath: ffmpeg.path) else {
            throw XCTSkip("ffmpeg is unavailable on this reference Mac.")
        }
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("reference.mp4")
        let output = root.appendingPathComponent("export.mp4")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-loglevel", "error",
            "-f", "lavfi",
            "-i", "color=c=blue:s=1920x1080:r=1",
            "-t", "120",
            "-pix_fmt", "yuv420p",
            raw.path,
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let asset = AVURLAsset(url: raw)
        let sourceDuration = try await asset.load(.duration)
        let project = DemoProject(
            name: "Reference export",
            recording: VideoRecordingAsset(
                filename: raw.lastPathComponent,
                duration: CMTimeGetSeconds(sourceDuration),
                width: 1_920,
                height: 1_080
            )
        )
        let started = ContinuousClock.now

        _ = try await LayeredVideoExporter().export(
            project: project,
            sourceURL: raw,
            destinationURL: output
        )

        XCTAssertLessThanOrEqual(
            started.duration(to: .now),
            .seconds(240)
        )
    }

    func test_layeredVideoExporter_destinationIsOriginal_rejectsWithoutChangingSource() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("raw.mp4")
        let writer = try ScreenVideoWriter(outputURL: raw)
        writer.append(
            try sampleBuffer(
                red: 0,
                green: 0,
                blue: 255,
                presentationTime: .zero
            )
        )
        let result = try await writer.finish()
        let before = try Data(contentsOf: raw)
        let project = DemoProject(
            name: "Original",
            recording: VideoRecordingAsset(
                filename: raw.lastPathComponent,
                duration: result.duration,
                width: result.width,
                height: result.height
            )
        )

        do {
            _ = try await LayeredVideoExporter().export(
                project: project,
                sourceURL: raw,
                destinationURL: raw
            )
            XCTFail("Expected original-protection failure")
        } catch LayeredVideoExportError.invalidDestination {
            XCTAssertEqual(try Data(contentsOf: raw), before)
        }
    }

    func test_layeredVideoExporter_cancelledTask_preservesExistingOutput() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("raw.mp4")
        let output = root.appendingPathComponent("existing.mp4")
        let original = Data("existing".utf8)
        try original.write(to: output)
        let writer = try ScreenVideoWriter(outputURL: raw)
        for frame in 0..<12 {
            writer.append(
                try sampleBuffer(
                    red: 0,
                    green: 0,
                    blue: 255,
                    presentationTime: CMTime(
                        value: CMTimeValue(frame),
                        timescale: 30
                    )
                )
            )
        }
        let result = try await writer.finish()
        let project = DemoProject(
            name: "Cancelled",
            recording: VideoRecordingAsset(
                filename: raw.lastPathComponent,
                duration: result.duration,
                width: result.width,
                height: result.height
            )
        )
        let exporter = LayeredVideoExporter()
        let task = Task {
            try await exporter.export(
                project: project,
                sourceURL: raw,
                destinationURL: output
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(try Data(contentsOf: output), original)
        }
    }

    /// Creates one BGRA ScreenCaptureKit-shaped frame at a deterministic presentation time.
    private func sampleBuffer(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        width: Int = 64,
        height: Int = 48,
        presentationTime: CMTime,
        displayTimeSeconds: Double? = nil
    ) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                [
                    kCVPixelBufferCGImageCompatibilityKey: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                ] as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                base[offset] = blue
                base[offset + 1] = green
                base[offset + 2] = red
                base[offset + 3] = 255
            }
        }

        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: buffer,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: buffer,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        let result = try XCTUnwrap(sampleBuffer)
        if let displayTimeSeconds {
            var timebase = mach_timebase_info_data_t()
            XCTAssertEqual(mach_timebase_info(&timebase), KERN_SUCCESS)
            let ticks = UInt64(
                displayTimeSeconds
                    * 1_000_000_000
                    * Double(timebase.denom)
                    / Double(timebase.numer)
            )
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                result,
                createIfNecessary: true
            ) as? [NSMutableDictionary]
            attachments?.first?[
                SCStreamFrameInfo.displayTime
            ] = NSNumber(value: ticks)
        }
        return result
    }

    /// Reads one decoded RGBA pixel so the test proves the timed click layer reached the frame.
    private func pixel(
        in image: CGImage,
        x: Int,
        y: Int
    ) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &data,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        let offset = (y * image.width + x) * 4
        return (
            red: data[offset],
            green: data[offset + 1],
            blue: data[offset + 2]
        )
    }

    /// Counts near-white glyph pixels so a background-only subtitle cannot pass export tests.
    private func brightPixelCount(in image: CGImage) throws -> Int {
        var data = [UInt8](
            repeating: 0,
            count: image.width * image.height * 4
        )
        let context = try XCTUnwrap(
            CGContext(
                data: &data,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(
            image,
            in: CGRect(
                x: 0,
                y: 0,
                width: image.width,
                height: image.height
            )
        )
        return stride(from: 0, to: data.count, by: 4).reduce(0) {
            count,
            offset in
            count + (
                data[offset] > 220
                    && data[offset + 1] > 220
                    && data[offset + 2] > 220
                    ? 1
                    : 0
            )
        }
    }

    private func redDominantBounds(
        in image: CGImage
    ) throws -> CGRect? {
        var data = [UInt8](
            repeating: 0,
            count: image.width * image.height * 4
        )
        let context = try XCTUnwrap(
            CGContext(
                data: &data,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(
            image,
            in: CGRect(
                x: 0,
                y: 0,
                width: image.width,
                height: image.height
            )
        )
        var minimumX = image.width
        var minimumY = image.height
        var maximumX = -1
        var maximumY = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                let red = Int(data[offset])
                let green = Int(data[offset + 1])
                let blue = Int(data[offset + 2])
                guard red > green + 40, red > blue + 40 else {
                    continue
                }
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }
        guard maximumX >= minimumX, maximumY >= minimumY else {
            return nil
        }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX + 1,
            height: maximumY - minimumY + 1
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
