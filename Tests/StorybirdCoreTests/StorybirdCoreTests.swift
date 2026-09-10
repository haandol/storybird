import AppKit
import CoreGraphics
import Darwin
import Foundation
@testable import StorybirdCore
import XCTest

final class StorybirdCoreTests: XCTestCase {
    func test_hotspotCoordinates_clampToUnitRange() {
        let hotspot = Hotspot(x: -0.25, y: 1.8)

        XCTAssertEqual(hotspot.x, 0)
        XCTAssertEqual(hotspot.y, 1)
    }

    func test_legacyProjectDecode_missingVideoFields_remainsScreenshotProject() throws {
        let projectID = UUID()
        let json = """
        {
          "id": "\(projectID.uuidString)",
          "name": "Legacy",
          "summary": "",
          "createdAt": "2026-09-01T00:00:00Z",
          "updatedAt": "2026-09-01T00:00:00Z",
          "steps": [],
          "events": [],
          "theme": {
            "accentHex": "#5B5CE2",
            "backgroundHex": "#11131A",
            "showsBranding": true
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let project = try decoder.decode(
            DemoProject.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(project.recording)
        XCTAssertTrue(project.clicks.isEmpty)
        XCTAssertTrue(project.subtitles.isEmpty)
    }

    func test_textOverlayOpacity_clampsToSupportedRange() {
        var style = TextOverlayStyle(backgroundOpacity: 2)
        XCTAssertEqual(style.backgroundOpacity, 1)

        style.backgroundOpacity = -1
        XCTAssertEqual(style.backgroundOpacity, 0)
    }

    func test_aspectFit_centersWideContent() {
        let frame = AspectFit.frame(
            contentSize: CGSize(width: 1_600, height: 900),
            in: CGRect(x: 0, y: 0, width: 800, height: 800)
        )

        XCTAssertEqual(frame.width, 800)
        XCTAssertEqual(frame.height, 450)
        XCTAssertEqual(frame.minY, 175)
    }

    func test_recordingGeometry_appKitScreenCoordinatesFlipYAxis() {
        let point = RecordingGeometry.normalizedClick(
            screenPoint: CGPoint(x: 50, y: 125),
            screenFrame: CGRect(x: 0, y: 100, width: 200, height: 100)
        )

        XCTAssertEqual(point?.x, 0.25)
        XCTAssertEqual(point?.y, 0.75)
    }

    func test_recordingGeometry_normalizesQuartzClick() {
        let point = RecordingGeometry.normalizedCaptureClick(
            capturePoint: CGPoint(x: 500, y: 250),
            captureFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )

        XCTAssertEqual(point?.x, 0.5)
        XCTAssertEqual(point?.y, 0.25)
    }

    func test_captureFrame_sampleRectTracksMovedWindow() {
        let frame = CaptureFrameGeometry.preferredFrame(
            sampleFrame: CGRect(x: 420, y: 180, width: 640, height: 480),
            liveWindowFrame: CGRect(x: 300, y: 120, width: 640, height: 480),
            fallbackFrame: CGRect(x: 100, y: 80, width: 640, height: 480)
        )

        XCTAssertEqual(frame.origin.x, 420)
        XCTAssertEqual(frame.origin.y, 180)
    }

    func test_controlWire_socketPair_roundTripsRequestAndResponse() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let request = StorybirdControlRequest(
            name: "storybird_list_projects",
            argumentsJSON: Data("{}".utf8)
        )

        try StorybirdControlWire.send(
            request,
            fileDescriptor: descriptors[0]
        )
        let received = try StorybirdControlWire.receive(
            StorybirdControlRequest.self,
            fileDescriptor: descriptors[1]
        )
        try StorybirdControlWire.send(
            StorybirdControlResponse(text: "ok"),
            fileDescriptor: descriptors[1]
        )
        let response = try StorybirdControlWire.receive(
            StorybirdControlResponse.self,
            fileDescriptor: descriptors[0]
        )

        XCTAssertEqual(received.name, request.name)
        XCTAssertEqual(received.argumentsJSON, request.argumentsJSON)
        XCTAssertEqual(response.text, "ok")
        XCTAssertFalse(response.isError)
    }

    func test_repository_roundTripsVideoProjectLibrary() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = DemoProject(
            name: "Video",
            recording: VideoRecordingAsset(
                filename: "recording.mp4",
                duration: 3,
                width: 1_280,
                height: 720
            ),
            clicks: [
                TimedPointerClick(time: 1, x: 0.25, y: 0.75),
            ],
            subtitles: [
                TimedSubtitle(
                    startTime: 0.5,
                    endTime: 2,
                    text: "Hello"
                ),
            ]
        )

        try repository.saveProjects([project])
        let loaded = try repository.loadProjects()

        XCTAssertEqual(loaded.map(\.id), [project.id])
        XCTAssertEqual(loaded.first?.recording, project.recording)
        XCTAssertEqual(loaded.first?.clicks, project.clicks)
        XCTAssertEqual(loaded.first?.subtitles, project.subtitles)
        XCTAssertEqual(loaded.first?.clips, project.clips)
        XCTAssertEqual(loaded.first?.revision, 0)
    }

    func test_repository_roundTripsVoiceProfiles() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let profile = VoiceProfile(
            name: "My voice",
            referenceFilename: "reference.mp3",
            referenceText: "안녕하세요. 제 목소리입니다.",
            consentConfirmed: true
        )

        try repository.saveVoiceProfiles([profile])

        let loaded = try XCTUnwrap(
            repository.loadVoiceProfiles().first
        )
        XCTAssertEqual(loaded.id, profile.id)
        XCTAssertEqual(loaded.name, profile.name)
        XCTAssertEqual(loaded.referenceFilename, profile.referenceFilename)
        XCTAssertEqual(loaded.referenceText, profile.referenceText)
        XCTAssertEqual(loaded.language, profile.language)
        XCTAssertEqual(loaded.consentConfirmed, profile.consentConfirmed)
    }

    func test_videoProjectValidation_acceptsNonOverlappingNarration() throws {
        var project = validVideoProject()
        project.narrations = [
            NarrationClip(
                voiceProfileID: UUID(),
                filename: "narration.wav",
                text: "서비스를 소개합니다.",
                startTime: 0.5,
                duration: 1
            ),
        ]

        XCTAssertNoThrow(try VideoProjectValidator.validate(project))
    }

    func test_videoProjectValidation_acceptsOverlappingNarration() {
        var project = validVideoProject()
        let profileID = UUID()
        project.narrations = [
            NarrationClip(
                voiceProfileID: profileID,
                filename: "first.wav",
                text: "첫 문장",
                startTime: 0.5,
                duration: 1
            ),
            NarrationClip(
                voiceProfileID: profileID,
                filename: "second.wav",
                text: "둘째 문장",
                startTime: 1,
                duration: 1
            ),
        ]

        XCTAssertNoThrow(try VideoProjectValidator.validate(project))
    }

    func test_clickCue_newRecording_hasEmptyDescriptionAndSubtitleSlots() {
        let cue = TimedPointerClick(time: 1, x: 0.25, y: 0.75)

        XCTAssertEqual(cue.sourceTime, 1)
        XCTAssertTrue(cue.description.text.isEmpty)
        XCTAssertTrue(cue.cueSubtitle.text.isEmpty)
        XCTAssertFalse(cue.isComplete)
        XCTAssertLessThanOrEqual(cue.indicator.startTime, cue.time)
        XCTAssertGreaterThan(cue.indicator.endTime, cue.time)
    }

    func test_videoTimeline_speedRemapsCueOntoProjectClock() throws {
        var project = validVideoProject()
        let clipID = try XCTUnwrap(project.clips.first?.id)
        project.clicks = [
            TimedPointerClick(sourceTime: 2, time: 2, x: 0.5, y: 0.5),
        ]

        let edited = try VideoTimelineEditor.setSpeed(
            project: project,
            clipID: clipID,
            rate: 2
        )

        XCTAssertEqual(edited.timelineDuration, 2.5, accuracy: 0.001)
        XCTAssertEqual(edited.clicks[0].time, 1, accuracy: 0.001)
        XCTAssertLessThanOrEqual(
            edited.clicks[0].indicator.endTime,
            edited.timelineDuration
        )
        XCTAssertLessThanOrEqual(
            edited.clicks[0].description.endTime,
            edited.timelineDuration
        )
        XCTAssertLessThanOrEqual(
            edited.clicks[0].cueSubtitle.endTime,
            edited.timelineDuration
        )
        XCTAssertNoThrow(try VideoProjectValidator.validate(edited))
    }

    func test_videoTimelineSchedule_mapsTitleClipAndCTAOnOneClock() throws {
        var project = validVideoProject()
        project = try DemoEffectEditor.insertTitle(
            in: project,
            after: nil,
            duration: 1,
            title: "Welcome"
        )
        project = try DemoEffectEditor.insertCTA(
            in: project,
            duration: 1,
            title: "Next",
            buttonLabel: "Continue"
        )

        let schedule = VideoTimelineSchedule(project: project)

        XCTAssertTrue(schedule.isStructurallyValid)
        XCTAssertEqual(schedule.duration, 7, accuracy: 0.001)
        XCTAssertNil(schedule.sourceTime(at: 0.5))
        XCTAssertEqual(
            try XCTUnwrap(schedule.sourceTime(at: 1)),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(schedule.sourceTime(at: 2)),
            1,
            accuracy: 0.001
        )
        XCTAssertNil(schedule.sourceTime(at: 6))
        XCTAssertNil(schedule.sourceTime(at: 7))
    }

    func test_videoTimelineSchedule_insertionTimeFollowsExistingBoundaryCards() throws {
        var project = validVideoProject()
        let originalClipID = try XCTUnwrap(project.clips.first?.id)
        project = try VideoTimelineEditor.split(
            project: project,
            clipID: originalClipID,
            sourceTime: 2.5
        )
        let clipID = try XCTUnwrap(project.clips.first?.id)
        project = try DemoEffectEditor.insertTitle(
            in: project,
            after: clipID,
            duration: 1,
            title: "First"
        )

        let schedule = VideoTimelineSchedule(project: project)

        XCTAssertEqual(
            try XCTUnwrap(schedule.insertionTime(after: clipID)),
            3.5,
            accuracy: 0.001
        )
    }

    func test_videoTimeline_trimRemovesCueOutsideRemainingSource() throws {
        var project = validVideoProject()
        let clipID = try XCTUnwrap(project.clips.first?.id)
        project.clicks = [
            TimedPointerClick(sourceTime: 1, time: 1, x: 0.2, y: 0.2),
            TimedPointerClick(sourceTime: 4, time: 4, x: 0.8, y: 0.8),
        ]

        let edited = try VideoTimelineEditor.trim(
            project: project,
            clipID: clipID,
            sourceStart: 2,
            sourceEnd: 5
        )

        XCTAssertEqual(edited.clicks.map(\.sourceTime), [4])
        XCTAssertEqual(edited.clicks[0].time, 2, accuracy: 0.001)
    }

    func test_clickSuggestionGenerator_reusesOneBundlePerCue() {
        var project = validVideoProject()
        project.clicks = [
            TimedPointerClick(time: 1, x: 0.5, y: 0.5),
        ]
        let first = ClickSuggestionGenerator.generate(for: project)
        project.suggestions = first

        let second = ClickSuggestionGenerator.generate(for: project)

        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].id, first[0].id)
        XCTAssertEqual(second[0].spotlight, first[0].spotlight)
    }

    func test_clickSuggestion_applyCreatesEffectsAndBecomesTerminal() throws {
        var project = validVideoProject()
        project.clicks = [
            TimedPointerClick(time: 1, x: 0.5, y: 0.5),
        ]
        project.suggestions = ClickSuggestionGenerator.generate(for: project)
        let id = try XCTUnwrap(project.suggestions.first?.id)

        let applied = try ClickSuggestionGenerator.apply(id, to: project)

        XCTAssertEqual(
            applied.suggestions.first(where: { $0.id == id })?.state,
            .applied
        )
        XCTAssertEqual(applied.effects.count, 2)
        XCTAssertThrowsError(
            try ClickSuggestionGenerator.apply(id, to: applied)
        )
    }

    func test_clickSuggestion_rejectDoesNotChangeOutputTimeline() throws {
        var project = validVideoProject()
        project.clicks = [
            TimedPointerClick(time: 1, x: 0.5, y: 0.5),
        ]
        project.suggestions = ClickSuggestionGenerator.generate(for: project)
        let id = try XCTUnwrap(project.suggestions.first?.id)

        let rejected = try ClickSuggestionGenerator.reject(id, in: project)

        XCTAssertEqual(rejected.suggestions[0].state, .rejected)
        XCTAssertEqual(rejected.clips, project.clips)
        XCTAssertEqual(rejected.effects, project.effects)
    }

    func test_videoProjectValidation_rejectsOverlappingSpotlights() {
        var project = validVideoProject()
        project.effects = [
            .spotlight(
                SpotlightEffect(
                    startTime: 0,
                    endTime: 2,
                    x: 0.1,
                    y: 0.1,
                    width: 0.3,
                    height: 0.3
                )
            ),
            .spotlight(
                SpotlightEffect(
                    startTime: 1,
                    endTime: 3,
                    x: 0.5,
                    y: 0.5,
                    width: 0.3,
                    height: 0.3
                )
            ),
        ]

        XCTAssertThrowsError(try VideoProjectValidator.validate(project))
    }

    func test_videoProjectValidation_allowsSlowTimelinePastSourceDuration() throws {
        var project = validVideoProject()
        let clipID = try XCTUnwrap(project.clips.first?.id)
        project.clicks = [
            TimedPointerClick(sourceTime: 4, time: 4, x: 0.5, y: 0.5),
        ]
        project = try VideoTimelineEditor.setSpeed(
            project: project,
            clipID: clipID,
            rate: 0.5
        )

        XCTAssertEqual(project.clicks[0].time, 8, accuracy: 0.001)
        XCTAssertNoThrow(try VideoProjectValidator.validate(project))
    }

    func test_demoEffectEditor_titleCardShiftsCueAndCreatesTimelineGap() throws {
        var project = validVideoProject()
        project.clicks = [
            TimedPointerClick(time: 1, x: 0.5, y: 0.5),
        ]

        let edited = try DemoEffectEditor.insertTitle(
            in: project,
            after: nil,
            duration: 1,
            title: "Welcome"
        )

        XCTAssertEqual(edited.timelineDuration, 6, accuracy: 0.001)
        XCTAssertEqual(edited.clicks[0].time, 2, accuracy: 0.001)
        XCTAssertNil(VideoTimelineEditor.sourceTime(in: edited, at: 0.5))
        let sourceTime = try XCTUnwrap(
            VideoTimelineEditor.sourceTime(in: edited, at: 2)
        )
        XCTAssertEqual(
            sourceTime,
            1,
            accuracy: 0.001
        )
        XCTAssertNoThrow(try VideoProjectValidator.validate(edited))
    }

    func test_demoEffectEditor_titleInsertionAndDeletionKeepNarrationAligned() throws {
        var project = validVideoProject()
        project.narrations = [
            NarrationClip(
                voiceProfileID: UUID(),
                filename: "narration.wav",
                text: "장면을 설명합니다.",
                startTime: 1,
                duration: 2
            ),
        ]
        let original = project.narrations[0]
        let edited = try DemoEffectEditor.insertTitle(
            in: project,
            after: nil,
            duration: 2,
            title: "Introduction"
        )

        XCTAssertEqual(edited.narrations[0].startTime, 3)
        XCTAssertEqual(edited.narrations[0].duration, original.duration)
        XCTAssertEqual(edited.narrations[0].filename, original.filename)
        try VideoProjectValidator.validate(edited)
        let restored = try DemoEffectEditor.delete(
            XCTUnwrap(edited.effects.first?.id),
            from: edited
        )
        XCTAssertEqual(restored.narrations, project.narrations)
    }

    func test_demoEffectEditor_ctaStaysAtProjectEnd() throws {
        let project = validVideoProject()

        let edited = try DemoEffectEditor.insertCTA(
            in: project,
            duration: 1
        )

        guard case let .cta(cta) = edited.effects.last else {
            return XCTFail("Expected CTA")
        }
        XCTAssertEqual(cta.endTime, edited.timelineDuration, accuracy: 0.001)
        XCTAssertNil(
            VideoTimelineEditor.sourceTime(
                in: edited,
                at: edited.timelineDuration - 0.5
            )
        )
        XCTAssertNoThrow(try VideoProjectValidator.validate(edited))
    }

    func test_demoEffectEditor_titleAfterFinalClip_isRejected() throws {
        let project = validVideoProject()
        let finalClipID = try XCTUnwrap(project.clips.last?.id)

        XCTAssertThrowsError(
            try DemoEffectEditor.insertTitle(
                in: project,
                after: finalClipID,
                duration: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? DemoEffectEditError,
                .invalidTitlePosition
            )
        }
    }

    func test_demoEffectEditor_deleteTitleClosesTimelineGap() throws {
        let project = validVideoProject()
        let withTitle = try DemoEffectEditor.insertTitle(
            in: project,
            after: nil,
            duration: 1
        )
        let titleID = try XCTUnwrap(withTitle.effects.first?.id)

        let restored = try DemoEffectEditor.delete(
            titleID,
            from: withTitle
        )

        XCTAssertEqual(restored.timelineDuration, project.timelineDuration)
        XCTAssertTrue(restored.effects.isEmpty)
    }

    func test_legacyMigration_copiesLibraryAndKeepsOriginal() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("OpenLane", isDirectory: true)
        let storybird = root.appendingPathComponent(
            "Storybird",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacy,
            withIntermediateDirectories: true
        )
        let marker = legacy.appendingPathComponent("library.json")
        try Data("legacy".utf8).write(to: marker)

        try ProjectRepository.migrateLegacyLibraryIfNeeded(
            from: legacy,
            to: storybird
        )

        XCTAssertEqual(
            try Data(contentsOf: marker),
            Data("legacy".utf8)
        )
        XCTAssertEqual(
            try Data(
                contentsOf: storybird.appendingPathComponent("library.json")
            ),
            Data("legacy".utf8)
        )
    }

    func test_videoProjectValidation_acceptsBoundedTimedLayers() throws {
        let project = validVideoProject()
        XCTAssertNoThrow(try VideoProjectValidator.validate(project))
    }

    func test_videoProjectValidation_clickAfterDuration_isRejected() {
        var project = validVideoProject()
        project.clicks = [
            TimedPointerClick(time: 6, x: 0.5, y: 0.5),
        ]

        XCTAssertThrowsError(
            try VideoProjectValidator.validate(project)
        ) { error in
            guard case VideoProjectValidationError.invalidClick = error else {
                return XCTFail("Expected invalid click, got \(error)")
            }
        }
    }

    func test_videoProjectValidation_subtitlePastDuration_isRejected() {
        var project = validVideoProject()
        project.subtitles = [
            TimedSubtitle(
                startTime: 4,
                endTime: 6,
                text: "Too late"
            ),
        ]

        XCTAssertThrowsError(
            try VideoProjectValidator.validate(project)
        ) { error in
            guard case VideoProjectValidationError.invalidSubtitle = error else {
                return XCTFail("Expected invalid subtitle, got \(error)")
            }
        }
    }

    func test_videoProjectValidation_blankSubtitle_isRejected() {
        var project = validVideoProject()
        project.subtitles = [
            TimedSubtitle(
                startTime: 0,
                endTime: 1,
                text: "   "
            ),
        ]

        XCTAssertThrowsError(
            try VideoProjectValidator.validate(project)
        ) { error in
            guard case VideoProjectValidationError.invalidSubtitle = error else {
                return XCTFail("Expected blank subtitle rejection, got \(error)")
            }
        }
    }

    func test_videoProjectValidation_emptyTimeline_isAllowedForEditing() {
        var project = validVideoProject()
        project.clips = []
        project.clicks = []
        project.subtitles = []
        project.effects = []
        project.suggestions = []

        XCTAssertNoThrow(
            try VideoProjectValidator.validate(project)
        )
    }

    func test_videoProjectValidation_clickTimeRegression_isRejected() {
        var project = validVideoProject()
        project.clicks = [
            TimedPointerClick(time: 2, x: 0.2, y: 0.2),
            TimedPointerClick(time: 1, x: 0.8, y: 0.8),
        ]

        XCTAssertThrowsError(
            try VideoProjectValidator.validate(project)
        ) { error in
            guard case VideoProjectValidationError.invalidClick = error else {
                return XCTFail("Expected time-order rejection, got \(error)")
            }
        }
    }

    func test_videoProjectValidation_invalidOverlayColor_isRejected() {
        var project = validVideoProject()
        project.clicks[0].captionStyle.backgroundHex = "not-a-color"

        XCTAssertThrowsError(
            try VideoProjectValidator.validate(project)
        ) { error in
            guard case VideoProjectValidationError.invalidClick = error else {
                return XCTFail("Expected invalid style rejection, got \(error)")
            }
        }
    }

    func test_videoProjectValidation_quickTimeSource_isAccepted() throws {
        var project = validVideoProject()
        project.recording?.filename = "imported.mov"

        XCTAssertNoThrow(try VideoProjectValidator.validate(project))
    }

    func test_videoTimeline_addClickCue_linksProjectAndSourceTime() throws {
        var project = validVideoProject()
        project.clicks = []
        project.suggestions = []

        let edited = try VideoTimelineEditor.addClickCue(
            to: project,
            at: 2,
            x: 0.25,
            y: 0.75
        )
        let click = try XCTUnwrap(edited.clicks.first)

        XCTAssertEqual(click.time, 2, accuracy: 0.001)
        XCTAssertEqual(click.sourceTime, 2, accuracy: 0.001)
        XCTAssertEqual(click.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(click.y, 0.75, accuracy: 0.001)
        XCTAssertFalse(click.isComplete)
        XCTAssertEqual(edited.suggestions.first?.clickID, click.id)
    }

    func test_videoTimeline_addClickCue_outsidePlayableFrame_isRejected() {
        let project = validVideoProject()

        XCTAssertThrowsError(
            try VideoTimelineEditor.addClickCue(
                to: project,
                at: project.timelineDuration,
                x: 0.5,
                y: 0.5
            )
        ) { error in
            XCTAssertEqual(
                error as? VideoTimelineEditError,
                .invalidClickPlacement
            )
        }
    }

    func test_videoTimeline_addClickCue_invalidCoordinatesAreRejected() {
        let project = validVideoProject()

        for value in [-0.1, 1.1, .infinity, .nan] {
            XCTAssertThrowsError(
                try VideoTimelineEditor.addClickCue(
                    to: project,
                    at: 1,
                    x: value,
                    y: 0.5
                )
            )
        }
    }

    func test_videoTimeline_addClickCue_titleCardTimeIsRejected() throws {
        var project = validVideoProject()
        project = try DemoEffectEditor.insertTitle(
            in: project,
            after: nil,
            duration: 1,
            title: "Title"
        )

        XCTAssertThrowsError(
            try VideoTimelineEditor.addClickCue(
                to: project,
                at: 0.5,
                x: 0.5,
                y: 0.5
            )
        )
    }

    func test_videoTimeline_addClickCue_freezeFrameKeepsSourceTime() throws {
        var project = validVideoProject()
        let clipID = try XCTUnwrap(project.clips.first?.id)
        project = try VideoTimelineEditor.insertFreeze(
            project: project,
            after: clipID,
            sourceTime: 4,
            duration: 1
        )

        let edited = try VideoTimelineEditor.addClickCue(
            to: project,
            at: 5.5,
            x: 0.4,
            y: 0.6
        )
        let added = try XCTUnwrap(
            edited.clicks.first { $0.time > 5 }
        )

        XCTAssertEqual(added.sourceTime, 4, accuracy: 0.001)
        XCTAssertEqual(added.sourceAnchor?.clipKind, .freeze)

        let persisted = VideoTimelineEditor.remapContentLayers(edited)
        let persistedClick = try XCTUnwrap(
            persisted.clicks.first { $0.id == added.id }
        )
        XCTAssertEqual(persistedClick.time, 5.5, accuracy: 0.001)

        let freezeID = try XCTUnwrap(
            persisted.clips.first { $0.kind == .freeze }?.id
        )
        let moved = try VideoTimelineEditor.move(
            project: persisted,
            clipID: freezeID,
            destination: 0
        )
        let movedClick = try XCTUnwrap(
            moved.clicks.first { $0.id == added.id }
        )
        XCTAssertEqual(movedClick.time, 0.5, accuracy: 0.001)
        XCTAssertEqual(movedClick.sourceAnchor?.clipID, freezeID)
    }

    func test_videoTimeline_deleteAnchoredClip_doesNotAdoptCueIntoOverlappingClip() throws {
        let first = VideoClip(sourceStart: 0, sourceEnd: 5)
        let second = VideoClip(sourceStart: 0, sourceEnd: 5)
        let click = TimedPointerClick(
            sourceTime: 1,
            time: 1,
            x: 0.5,
            y: 0.5,
            sourceAnchor: ClickSourceAnchor(
                clipID: first.id,
                clipKind: .video,
                clipOffset: 1
            )
        ).bounded(to: 10)
        let project = DemoProject(
            name: "Overlap",
            recording: VideoRecordingAsset(
                filename: "recording.mp4",
                duration: 5,
                width: 640,
                height: 480
            ),
            clips: [first, second],
            clicks: [click]
        )

        let edited = try VideoTimelineEditor.delete(
            project: project,
            clipID: first.id
        )

        XCTAssertTrue(edited.clicks.isEmpty)
    }

    func test_videoTimeline_splitTransfersAnchoredAndLegacyCuesExactlyOnce() throws {
        let clip = VideoClip(sourceStart: 0, sourceEnd: 5)
        let anchored = TimedPointerClick(
            sourceTime: 2,
            time: 2,
            x: 0.4,
            y: 0.4,
            sourceAnchor: ClickSourceAnchor(
                clipID: clip.id,
                clipKind: .video,
                clipOffset: 2
            )
        ).bounded(to: 5)
        let legacy = TimedPointerClick(
            sourceTime: 3,
            time: 3,
            x: 0.6,
            y: 0.6
        ).bounded(to: 5)
        let project = DemoProject(
            name: "Split anchors",
            recording: VideoRecordingAsset(
                filename: "recording.mp4",
                duration: 5,
                width: 640,
                height: 480
            ),
            clips: [clip],
            clicks: [anchored, legacy]
        )

        let edited = try VideoTimelineEditor.split(
            project: project,
            clipID: clip.id,
            sourceTime: 2
        )

        XCTAssertEqual(edited.clicks.count, 2)
        XCTAssertEqual(Set(edited.clicks.map(\.id)).count, 2)
        let anchoredResult = try XCTUnwrap(
            edited.clicks.first { $0.id == anchored.id }
        )
        XCTAssertEqual(anchoredResult.sourceAnchor?.clipID, edited.clips[1].id)
        let legacyResult = try XCTUnwrap(
            edited.clicks.first { $0.id == legacy.id }
        )
        XCTAssertEqual(legacyResult.sourceAnchor?.clipID, edited.clips[1].id)
    }

    func test_videoTimeline_contentEffectsFollowMoveAndSpeed() throws {
        let first = VideoClip(sourceStart: 0, sourceEnd: 2)
        let second = VideoClip(sourceStart: 2, sourceEnd: 4)
        var project = DemoProject(
            name: "Effects",
            recording: VideoRecordingAsset(
                filename: "recording.mp4",
                duration: 4,
                width: 640,
                height: 480
            ),
            clips: [first, second]
        )
        project.effects = [
            VideoTimelineEditor.anchorContentEffect(
                .spotlight(
                    SpotlightEffect(
                        startTime: 0.5,
                        endTime: 1.5,
                        x: 0.2,
                        y: 0.2,
                        width: 0.3,
                        height: 0.3
                    )
                ),
                in: project,
                at: 0.5
            ),
            VideoTimelineEditor.anchorContentEffect(
                .panZoom(
                    PanZoomEffect(
                        startTime: 0.5,
                        endTime: 1.5,
                        endX: 0.5,
                        endY: 0.5,
                        endScale: 1.5
                    )
                ),
                in: project,
                at: 0.5
            ),
        ]

        let moved = try VideoTimelineEditor.move(
            project: project,
            clipID: first.id,
            destination: 1
        )
        XCTAssertEqual(moved.effects[0].startTime, 2.5, accuracy: 0.001)
        XCTAssertEqual(moved.effects[1].endTime, 3.5, accuracy: 0.001)

        let sped = try VideoTimelineEditor.setSpeed(
            project: project,
            clipID: first.id,
            rate: 2
        )
        XCTAssertEqual(sped.effects[0].startTime, 0.25, accuracy: 0.001)
        XCTAssertEqual(sped.effects[1].endTime, 0.75, accuracy: 0.001)
    }

    func test_videoTimeline_contentEffectsTrimDeleteAndSplitWithOwner() throws {
        let clip = VideoClip(sourceStart: 0, sourceEnd: 4)
        var project = DemoProject(
            name: "Effects",
            recording: VideoRecordingAsset(
                filename: "recording.mp4",
                duration: 4,
                width: 640,
                height: 480
            ),
            clips: [clip]
        )
        project.effects = [
            VideoTimelineEditor.anchorContentEffect(
                .spotlight(
                    SpotlightEffect(
                        startTime: 0.5,
                        endTime: 1.5,
                        x: 0.2,
                        y: 0.2,
                        width: 0.3,
                        height: 0.3
                    )
                ),
                in: project,
                at: 0.5
            ),
        ]

        let trimmed = try VideoTimelineEditor.trim(
            project: project,
            clipID: clip.id,
            sourceStart: 1,
            sourceEnd: 4
        )
        XCTAssertEqual(trimmed.effects[0].startTime, 0, accuracy: 0.001)
        XCTAssertEqual(trimmed.effects[0].endTime, 0.5, accuracy: 0.001)

        let split = try VideoTimelineEditor.split(
            project: project,
            clipID: clip.id,
            sourceTime: 2
        )
        guard case let .spotlight(splitEffect) = split.effects[0] else {
            return XCTFail("Expected spotlight")
        }
        XCTAssertEqual(splitEffect.sourceAnchor?.clipID, split.clips[0].id)

        let deleted = try VideoTimelineEditor.delete(
            project: project,
            clipID: clip.id
        )
        XCTAssertTrue(deleted.effects.isEmpty)
    }

    func test_videoTimeline_splitPartitionsSpanningContentEffectsWithoutGap() throws {
        let clip = VideoClip(sourceStart: 0, sourceEnd: 4)
        var project = DemoProject(
            name: "Spanning effects",
            recording: VideoRecordingAsset(
                filename: "recording.mp4",
                duration: 4,
                width: 640,
                height: 480
            ),
            clips: [clip]
        )
        project.effects = [
            VideoTimelineEditor.anchorContentEffect(
                .spotlight(
                    SpotlightEffect(
                        startTime: 0.5,
                        endTime: 3.5,
                        x: 0.2,
                        y: 0.2,
                        width: 0.3,
                        height: 0.3
                    )
                ),
                in: project,
                at: 1
            ),
            VideoTimelineEditor.anchorContentEffect(
                .panZoom(
                    PanZoomEffect(
                        startTime: 0.5,
                        endTime: 3.5,
                        endX: 0.5,
                        endY: 0.5,
                        endScale: 1.5
                    )
                ),
                in: project,
                at: 1
            ),
        ]

        let edited = try VideoTimelineEditor.split(
            project: project,
            clipID: clip.id,
            sourceTime: 2
        )

        XCTAssertEqual(edited.effects.count, 4)
        XCTAssertEqual(Set(edited.effects.map(\.id)).count, 4)
        let ranges = edited.effects.map {
            $0.startTime...$0.endTime
        }.sorted { $0.lowerBound < $1.lowerBound }
        XCTAssertEqual(ranges[0].lowerBound, 0.5, accuracy: 0.001)
        XCTAssertEqual(ranges[0].upperBound, 2, accuracy: 0.001)
        XCTAssertEqual(ranges[2].lowerBound, 2, accuracy: 0.001)
        XCTAssertEqual(ranges[2].upperBound, 3.5, accuracy: 0.001)
    }

    func test_videoTimeline_directEffectTimingEditRebuildsSourceAnchor() throws {
        let clip = VideoClip(sourceStart: 0, sourceEnd: 4)
        var current = DemoProject(
            name: "Timing edit",
            recording: VideoRecordingAsset(
                filename: "recording.mp4",
                duration: 4,
                width: 640,
                height: 480
            ),
            clips: [clip]
        )
        current.effects = [
            VideoTimelineEditor.anchorContentEffect(
                .spotlight(
                    SpotlightEffect(
                        startTime: 0.5,
                        endTime: 1.5,
                        x: 0.2,
                        y: 0.2,
                        width: 0.3,
                        height: 0.3
                    )
                ),
                in: current,
                at: 1
            ),
        ]
        var draft = current
        guard case var .spotlight(value) = draft.effects[0] else {
            return XCTFail("Expected spotlight")
        }
        value.startTime = 0.8
        value.endTime = 1.8
        draft.effects[0] = .spotlight(value)

        let reanchored =
            try VideoTimelineEditor.reanchorChangedContentEffectTimes(
                from: current,
                to: draft
            )
        let saved = VideoTimelineEditor.remapContentLayers(reanchored)

        XCTAssertEqual(saved.effects[0].startTime, 0.8, accuracy: 0.001)
        XCTAssertEqual(saved.effects[0].endTime, 1.8, accuracy: 0.001)
        guard case let .spotlight(savedValue) = saved.effects[0] else {
            return XCTFail("Expected spotlight")
        }
        let anchor = try XCTUnwrap(savedValue.sourceAnchor)
        XCTAssertEqual(
            anchor.sourceStart,
            0.8,
            accuracy: 0.001
        )
        XCTAssertEqual(
            anchor.sourceEnd,
            1.8,
            accuracy: 0.001
        )
    }

    func test_videoTimeline_invalidEffectTimingEditRejectsWholeChange() {
        let first = VideoClip(sourceStart: 0, sourceEnd: 2)
        let second = VideoClip(sourceStart: 2, sourceEnd: 4)
        var current = DemoProject(
            name: "Invalid timing",
            recording: VideoRecordingAsset(
                filename: "recording.mp4",
                duration: 4,
                width: 640,
                height: 480
            ),
            clips: [first, second]
        )
        current.effects = [
            VideoTimelineEditor.anchorContentEffect(
                .panZoom(
                    PanZoomEffect(
                        startTime: 0.5,
                        endTime: 1.5,
                        endX: 0.5,
                        endY: 0.5,
                        endScale: 1.5
                    )
                ),
                in: current,
                at: 1
            ),
        ]

        for (start, end) in [
            (1.5, 2.5),
            (2.0, 1.0),
            (-1.0, 0.5),
            (3.5, 4.5),
        ] {
            var draft = current
            guard case var .panZoom(value) = draft.effects[0] else {
                return XCTFail("Expected pan zoom")
            }
            value.startTime = start
            value.endTime = end
            value.endScale = 2
            draft.effects[0] = .panZoom(value)

            XCTAssertThrowsError(try VideoTimelineEditor.reanchorChangedContentEffectTimes(
                from: current, to: draft
            )) { error in
                XCTAssertEqual(error as? VideoProjectValidationError, .invalidEffect(value.id))
            }
        }
    }

    func test_videoOverlayLayout_captionStaysInsideBothCoordinateSystems() {
        let frame = CGRect(x: 10, y: 20, width: 320, height: 180)
        let metrics = VideoOverlayMetrics(frameSize: frame.size)
        let label = CGSize(width: 120, height: 42)

        for axis in [VideoOverlayAxis.topDown, .bottomUp] {
            let origin = VideoOverlayLayout.captionOrigin(
                labelSize: label,
                x: 0.98,
                y: 0.02,
                in: frame,
                axis: axis,
                metrics: metrics
            )
            let caption = CGRect(origin: origin, size: label)

            XCTAssertGreaterThanOrEqual(caption.minX, frame.minX)
            XCTAssertGreaterThanOrEqual(caption.minY, frame.minY)
            XCTAssertLessThanOrEqual(caption.maxX, frame.maxX)
            XCTAssertLessThanOrEqual(caption.maxY, frame.maxY)
        }
    }

    func test_videoOverlayTiming_previewAndExportWindowsShareBoundaries() {
        XCTAssertTrue(
            VideoOverlayTiming.clickIsVisible(
                clickTime: 2,
                at: 2 - VideoOverlayTiming.clickLead
            )
        )
        XCTAssertTrue(
            VideoOverlayTiming.captionIsVisible(
                clickTime: 2,
                at: 2 + VideoOverlayTiming.captionTail
            )
        )
        XCTAssertFalse(
            VideoOverlayTiming.clickIsVisible(
                clickTime: 2,
                at: 2 + VideoOverlayTiming.clickTail + 0.001
            )
        )
    }

    func test_videoOverlayPresentation_customDescriptionSeparatesClickAndCaptionCoordinates() {
        var click = TimedPointerClick(
            time: 1,
            x: 0.2,
            y: 0.3,
            caption: "Description"
        )
        click.description.position = .custom
        click.description.x = 0.8
        click.description.y = 0.7
        let camera = VideoCameraPresentation.identity

        let ring = VideoOverlayPresentation.clickPoint(
            for: click,
            camera: camera
        )
        let description = VideoOverlayPresentation.descriptionPoint(
            for: click,
            camera: camera
        )

        XCTAssertEqual(ring.x, 0.2, accuracy: 0.001)
        XCTAssertEqual(ring.y, 0.3, accuracy: 0.001)
        XCTAssertEqual(description.x, 0.8, accuracy: 0.001)
        XCTAssertEqual(description.y, 0.7, accuracy: 0.001)
    }

    func test_videoOverlayPresentation_clickRingAnimationMatchesPreviewCurve() {
        let click = TimedPointerClick(time: 2, x: 0.5, y: 0.5)
        let camera = VideoCameraPresentation.identity
        let start = VideoOverlayPresentation.clickRing(
            for: click,
            at: click.time - VideoOverlayTiming.clickLead,
            camera: camera
        )
        let middle = VideoOverlayPresentation.clickRing(
            for: click,
            at: (
                click.time - VideoOverlayTiming.clickLead
                    + click.time + VideoOverlayTiming.clickTail
            ) / 2,
            camera: camera
        )
        let end = VideoOverlayPresentation.clickRing(
            for: click,
            at: click.time + VideoOverlayTiming.clickTail,
            camera: camera
        )

        XCTAssertEqual(start.diameterScale, 0.65, accuracy: 0.001)
        XCTAssertEqual(start.opacityScale, 1, accuracy: 0.001)
        XCTAssertEqual(middle.diameterScale, 1, accuracy: 0.001)
        XCTAssertEqual(middle.opacityScale, 0.575, accuracy: 0.001)
        XCTAssertEqual(end.diameterScale, 1.35, accuracy: 0.001)
        XCTAssertEqual(end.opacityScale, 0.15, accuracy: 0.001)
    }

    func test_videoOverlayPresentation_visibleLayerIDs_includeAnyActiveCueComponent() {
        var click = TimedPointerClick(
            time: 0.5,
            x: 0.5,
            y: 0.5,
            caption: "Description"
        )
        click.indicator.startTime = 0
        click.indicator.endTime = 1
        click.description.startTime = 2
        click.description.endTime = 3
        click.cueSubtitle.text = "Cue subtitle"
        click.cueSubtitle.startTime = 4
        click.cueSubtitle.endTime = 5
        let project = DemoProject(
            name: "Visibility",
            recording: VideoRecordingAsset(
                filename: "recording.mp4",
                duration: 6,
                width: 640,
                height: 480
            ),
            clicks: [click]
        )

        XCTAssertEqual(
            VideoOverlayPresentation.visibleLayerIDs(
                in: project,
                at: 2.5
            ),
            [click.id]
        )
        XCTAssertEqual(
            VideoOverlayPresentation.visibleLayerIDs(
                in: project,
                at: 4.5
            ),
            [click.id]
        )
        XCTAssertTrue(
            VideoOverlayPresentation.visibleLayerIDs(
                in: project,
                at: 5.5
            ).isEmpty
        )
    }

    func test_videoOverlayPresentation_cameraInterpolatesAndTransformsPoint() {
        let project = DemoProject(
            name: "Camera",
            recording: VideoRecordingAsset(
                filename: "recording.mp4",
                duration: 10,
                width: 640,
                height: 480
            ),
            effects: [
                .panZoom(
                    PanZoomEffect(
                        startTime: 0,
                        endTime: 10,
                        startX: 0.2,
                        startY: 0.3,
                        startScale: 1,
                        endX: 0.8,
                        endY: 0.7,
                        endScale: 3
                    )
                ),
            ]
        )

        let camera = VideoOverlayPresentation.camera(
            in: project,
            at: 5
        )
        let transformed = camera.transform(x: 0.6, y: 0.5)

        XCTAssertEqual(camera.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(camera.y, 0.5, accuracy: 0.001)
        XCTAssertEqual(camera.scale, 2, accuracy: 0.001)
        XCTAssertEqual(transformed.x, 0.7, accuracy: 0.001)
        XCTAssertEqual(transformed.y, 0.5, accuracy: 0.001)
    }

    func test_videoOverlayPresentation_fontSizeUsesPersistedStyle() {
        let metrics = VideoOverlayMetrics(
            frameSize: CGSize(width: 720, height: 720)
        )
        let style = TextOverlayStyle(fontSize: 30)

        XCTAssertEqual(
            VideoOverlayPresentation.fontSize(
                style: style,
                metrics: metrics
            ),
            30,
            accuracy: 0.001
        )
        XCTAssertEqual(
            VideoOverlayPresentation.fontSize(
                style: style,
                metrics: metrics,
                contentScale: 2
            ),
            60,
            accuracy: 0.001
        )
    }

    private func validVideoProject() -> DemoProject {
        DemoProject(
            name: "Video",
            recording: VideoRecordingAsset(
                filename: "recording.mp4",
                duration: 5,
                width: 1_280,
                height: 720
            ),
            clicks: [
                TimedPointerClick(time: 1, x: 0.25, y: 0.75),
            ],
            subtitles: [
                TimedSubtitle(
                    startTime: 0.5,
                    endTime: 2,
                    text: "Hello"
                ),
            ]
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
