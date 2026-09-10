import AVFoundation
import Foundation
import StorybirdCore
@testable import Storybird
import XCTest

@MainActor
final class AgentProductionTests: XCTestCase {
    func test_ttsRegeneration_undoRestoresSplitFadeEnvelope() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, initial) = try await fixture(root, voice: ProductionVoice())
        try TestVideoFactory.makeToneWAV(at: store.repository.assetURL(projectID: initial.id, filename: "split-source.wav"), duration: 2)
        var project = initial
        project.narrations = [NarrationClip(
            voiceProfileID: store.voiceProfiles[0].id, filename: "split-source.wav",
            text: "Before split", startTime: 1, duration: 2, fadeIn: 0.8, fadeOut: 0.2
        )]
        project = try store.saveProject(project, expectedRevision: 0)
        let split = try store.saveProject(
            AudioLayerEditor.split(layerID: project.narrations[0].id, in: project, at: 1.4),
            expectedRevision: project.revision
        )
        let right = split.narrations[1]
        XCTAssertEqual(right.effectiveFadeEnvelope.gain(at: 0), 0.5, accuracy: 0.0001)
        let generated = try await store.updateNarration(projectID: project.id, narrationID: right.id,
            expectedRevision: split.revision, text: "New sentence")
        for _ in 0..<2 {
            let restored = try store.undo(projectID: project.id)
            XCTAssertEqual(restored.narrations, split.narrations)
            XCTAssertEqual(restored.narrations[1].effectiveFadeEnvelope.gain(at: 0), 0.5, accuracy: 0.0001)
            let redone = try store.redo(projectID: project.id)
            XCTAssertEqual(redone.narrations, generated.narrations)
        }
    }

    func test_ttsRegeneration_shorterNewAssetPreservesExplicitFadesAndUndo() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, initial) = try await fixture(root, voice: ProductionVoice())
        let filename = "long.wav"
        try TestVideoFactory.makeToneWAV(at: store.repository.assetURL(projectID: initial.id, filename: filename), duration: 2)
        var project = initial
        project.narrations = [NarrationClip(
            voiceProfileID: store.voiceProfiles[0].id, filename: filename, text: "Original sentence",
            language: "english", startTime: 1, duration: 2, name: "Custom label", fadeIn: 0.2, fadeOut: 0.3
        )]
        let original = try store.saveProject(project, expectedRevision: 0)
        let changed = try await store.updateNarration(projectID: project.id, narrationID: project.narrations[0].id,
            expectedRevision: original.revision, text: "Replacement sentence", language: "english")
        XCTAssertEqual(changed.narrations[0].duration, 1)
        XCTAssertEqual(changed.narrations[0].fadeIn, 0.2)
        XCTAssertEqual(changed.narrations[0].fadeOut, 0.3)
        XCTAssertEqual(changed.narrations[0].name, "Custom label")
        let preview = try await AudioPreviewRenderer.render(project: changed,
            sourceURL: store.repository.assetURL(projectID: project.id, filename: project.recording!.filename),
            startTime: 1, duration: 1)
        defer { try? FileManager.default.removeItem(atPath: preview.path) }
        let audio = URL(fileURLWithPath: preview.path)
        let steady = try await TestVideoFactory.averageAmplitude(in: audio, from: 0.3, to: 0.5)
        let ending = try await TestVideoFactory.averageAmplitude(in: audio, from: 0.9, to: 0.99)
        XCTAssertLessThan(ending, steady * 0.3)
        let restored = try store.undo(projectID: project.id)
        XCTAssertEqual(restored.narrations, original.narrations)
    }

    func test_promptToVideo_ttsLayersPreviewAndExportNeedNoHumanRecording() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let voice = ProductionVoice()
        let (store, original) = try await fixture(root, voice: voice)
        let host = StorybirdExternalControlHost(store: store)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var drafts: [NarrationDraft] = []
        for text in ["Introduce the service.", "Explain the audio layers."] {
            let response = try await command(host, "storybird_start_narration_draft", [
                "project_id": original.id.uuidString, "voice_profile_id": store.voiceProfiles[0].id.uuidString,
                "text": text, "language": "english",
            ])
            XCTAssertFalse(response.isError, response.text)
            let draft = try decoder.decode(NarrationDraft.self, from: Data(response.text.utf8))
            drafts.append(try await waitForDraft(store, projectID: original.id, draftID: draft.id))
        }
        XCTAssertEqual(drafts.compactMap(\.duration), [1, 1])
        XCTAssertEqual(store.project(id: original.id)?.revision, 0)
        let trim = try await command(host, "storybird_trim_clip", [
            "project_id": original.id.uuidString, "expected_revision": 0,
            "clip_id": original.clips[0].id.uuidString, "source_start": 0.0, "source_end": 0.5,
        ])
        XCTAssertFalse(trim.isError, trim.text)
        let extended = try await command(host, "storybird_insert_freeze", [
            "project_id": original.id.uuidString, "expected_revision": 1,
            "clip_id": original.clips[0].id.uuidString, "source_time": 0.25,
            "duration": drafts.compactMap(\.duration).reduce(0, +),
        ])
        XCTAssertFalse(extended.isError, extended.text)
        for (index, draft) in drafts.enumerated() {
            let response = try await command(host, "storybird_place_narration_draft", [
                "project_id": original.id.uuidString, "expected_revision": 2 + index,
                "draft_id": draft.id.uuidString, "start_time": Double(index) * 0.8, "timing_mode": "project",
            ])
            XCTAssertFalse(response.isError, response.text)
        }
        let project = try XCTUnwrap(store.project(id: original.id))
        XCTAssertEqual(project.narrations.count, 2)
        XCTAssertLessThan(project.narrations[1].startTime, project.narrations[0].endTime)
        let faded = try await command(host, "storybird_update_audio_layer", [
            "project_id": project.id.uuidString, "expected_revision": 4,
            "layer_id": project.narrations[0].id.uuidString, "fade_out": 0.2,
        ])
        XCTAssertFalse(faded.isError, faded.text)
        let subtitle = try await command(host, "storybird_upsert_subtitle", [
            "project_id": project.id.uuidString, "expected_revision": 5,
            "text": "Introduce the service.", "start_time": 0.0, "end_time": 1.0, "position": "bottom",
        ])
        XCTAssertFalse(subtitle.isError, subtitle.text)
        let mix = try await command(host, "storybird_render_audio_preview", [
            "project_id": project.id.uuidString, "start_time": 0.0, "duration": project.timelineDuration,
        ])
        XCTAssertFalse(mix.isError, mix.text)
        let preview = try decoder.decode(AudioPreviewResult.self, from: Data(mix.text.utf8))
        defer { try? FileManager.default.removeItem(atPath: preview.path) }
        XCTAssertGreaterThan(preview.peak, 0)
        let started = try await command(host, "storybird_start_export", [
            "project_id": project.id.uuidString, "parent_directory": root.path,
        ])
        XCTAssertFalse(started.isError, started.text)
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(started.text.utf8)) as? [String: Any])
        let id = try XCTUnwrap(job["id"] as? String)
        var completed: [String: Any]?
        for _ in 0..<1_000 {
            let response = try await command(host, "storybird_get_export", ["job_id": id])
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any])
            if state["state"] as? String == "completed" { completed = state; break }
            if ["failed", "cancelled"].contains(state["state"] as? String ?? "") {
                XCTFail(response.text)
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let output = try XCTUnwrap(completed?["outputPath"] as? String)
        let tracks = try await AVURLAsset(url: URL(fileURLWithPath: output)).loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertNil(store.externalControlPrompt)
        XCTAssertTrue(store.canStartScreenRecording)
        let languages = await voice.languages
        XCTAssertEqual(languages, ["english", "english"])
    }

    func test_duplicateProject_copiesAudioAndVideoIndependently() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original) = try await fixture(root)
        var source = original
        let narrationURL = store.repository.assetURL(projectID: source.id, filename: "voice.wav")
        try TestVideoFactory.makeToneWAV(at: narrationURL, duration: 1)
        source.narrations = [NarrationClip(
            voiceProfileID: UUID(), filename: "voice.wav", text: "Hello",
            language: "english", startTime: 1, duration: 1
        )]
        source = try store.saveProject(source, expectedRevision: source.revision)
        let host = StorybirdExternalControlHost(store: store)
        let response = await host.handle(StorybirdControlRequest(
            name: "storybird_duplicate_project",
            argumentsJSON: try JSONSerialization.data(withJSONObject: [
                "project_id": source.id.uuidString, "expected_revision": source.revision,
                "name": "English version",
            ])
        ))
        XCTAssertFalse(response.isError, response.text)
        let copy = try XCTUnwrap(store.projects.first { $0.id != source.id })
        XCTAssertEqual(copy.revision, 0)
        XCTAssertEqual(copy.narrations, source.narrations)
        XCTAssertEqual(copy.clips, source.clips)
        XCTAssertTrue(copy.narrationDrafts.isEmpty)
        let copiedAudio = store.repository.assetURL(projectID: copy.id, filename: "voice.wav")
        XCTAssertEqual(try Data(contentsOf: copiedAudio), try Data(contentsOf: narrationURL))
        store.deleteProject(id: source.id)
        let output = root.appendingPathComponent("copy.mp4")
        _ = try await LayeredVideoExporter().export(
            project: copy,
            sourceURL: store.repository.assetURL(projectID: copy.id, filename: copy.recording!.filename),
            destinationURL: output
        )
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertThrowsError(try store.undo(projectID: copy.id))
    }

    func test_duplicateProject_staleOrMissingAssetPublishesNothing() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, project) = try await fixture(root)
        for revision in [99, project.revision] {
            if revision == project.revision {
                try FileManager.default.removeItem(at: store.repository.assetURL(
                    projectID: project.id, filename: project.recording!.filename
                ))
            }
            do {
                _ = try await store.duplicateProject(projectID: project.id, expectedRevision: revision)
                XCTFail("Expected stale state or missing media to fail")
            } catch {}
            XCTAssertEqual(store.projects.count, 1)
            let folders = try FileManager.default.contentsOfDirectory(
                at: store.repository.assetsDirectory(projectID: project.id).deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            )
            XCTAssertEqual(folders.count, 1)
        }
    }

    func test_narrationDraft_restartAndPlacementPreserveReadyAudioAfterConflict() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, project) = try await fixture(root)
        let profileID = UUID()
        var draft = NarrationDraft(
            voiceProfileID: profileID, text: "Ready sentence", language: "english", filename: "draft.wav"
        )
        try store.saveNarrationDraft(draft, projectID: project.id)
        try TestVideoFactory.makeToneWAV(
            at: store.repository.assetURL(projectID: project.id, filename: draft.filename), duration: 2
        )
        draft.state = .ready
        draft.duration = 2
        try store.saveNarrationDraft(draft, projectID: project.id)
        let interrupted = NarrationDraft(
            voiceProfileID: profileID, text: "Interrupted", language: "korean", filename: "partial.wav"
        )
        try store.saveNarrationDraft(interrupted, projectID: project.id)
        let restarted = AppStore(repository: store.repository)
        XCTAssertEqual(restarted.project(id: project.id)?.revision, 0)
        XCTAssertEqual(restarted.project(id: project.id)?.narrationDrafts.last?.state, .failed)
        for (revision, start) in [(99, 1.0), (0, 4.0)] {
            do {
                _ = try await restarted.placeNarrationDraft(
                    projectID: project.id, draftID: draft.id, expectedRevision: revision, startTime: start
                )
                XCTFail("Expected conflict or overflow")
            } catch {}
        }
        XCTAssertEqual(restarted.project(id: project.id)?.narrationDrafts.first?.state, .ready)
        let placed = try await restarted.placeNarrationDraft(
            projectID: project.id, draftID: draft.id, expectedRevision: 0, startTime: 1
        )
        XCTAssertEqual(placed.revision, 1)
        XCTAssertEqual(placed.narrationDrafts.first?.state, .placed)
        XCTAssertEqual(placed.narrations.first?.filename, draft.filename)
        _ = try restarted.undo(projectID: project.id)
        XCTAssertEqual(restarted.project(id: project.id)?.narrationDrafts.first?.state, .placed)
        do {
            _ = try await restarted.placeNarrationDraft(
                projectID: project.id, draftID: draft.id, expectedRevision: 2, startTime: 1
            )
            XCTFail("A consumed draft cannot be replayed after undo")
        } catch {}
    }

    func test_sceneEdit_overlapIsAllowedAndTrimUndoKeepsAudio() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original) = try await fixture(root)
        var project = try VideoTimelineEditor.split(
            project: original, clipID: original.clips[0].id, sourceTime: 2.5
        )
        let file = store.repository.assetURL(projectID: project.id, filename: "kept.wav")
        try TestVideoFactory.makeToneWAV(at: file, duration: 1)
        try TestVideoFactory.makeToneWAV(
            at: store.repository.assetURL(projectID: project.id, filename: "fixed.wav"),
            duration: 0.5
        )
        project.narrations = [
            NarrationClip(
                voiceProfileID: UUID(), filename: "kept.wav", text: "scene",
                startTime: 0, duration: 1, sceneAnchor: try SceneTiming.anchor(at: 0, in: project)
            ),
            NarrationClip(voiceProfileID: UUID(), filename: "fixed.wav", text: "fixed", startTime: 3, duration: 0.5),
        ]
        project = try store.saveProject(project, expectedRevision: 0)
        let conflicting = try VideoTimelineEditor.move(project: project, clipID: project.clips[0].id, destination: 1)
        let overlapped = try store.saveProject(conflicting, expectedRevision: project.revision)
        XCTAssertEqual(overlapped.narrations.count, 2)
        project = try store.undo(projectID: project.id)
        let trimmed = try VideoTimelineEditor.trim(
            project: project, clipID: project.clips[0].id, sourceStart: 0.5, sourceEnd: 2.5
        )
        let saved = try store.saveProject(trimmed, expectedRevision: project.revision)
        XCTAssertEqual(saved.narrations.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let restored = try store.undo(projectID: project.id)
        XCTAssertEqual(restored.narrations, project.narrations)
    }

    func test_voiceDraft_englishFromKoreanProfilePersistsWithoutEditingTimeline() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let voice = ProductionVoice()
        let (store, project) = try await fixture(root, voice: voice)
        let profile = try XCTUnwrap(store.voiceProfiles.first)
        let draft = try store.startNarrationDraft(
            projectID: project.id, voiceProfileID: profile.id,
            text: "Welcome to this service.", language: "english"
        )
        let ready = try await waitForDraft(store, projectID: project.id, draftID: draft.id)
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.duration, 1)
        XCTAssertEqual(store.project(id: project.id)?.revision, 0)
        XCTAssertTrue(store.project(id: project.id)?.narrations.isEmpty == true)
        let languages = await voice.languages
        XCTAssertEqual(languages, ["english"])
        let reopened = AppStore(repository: store.repository)
        XCTAssertEqual(reopened.project(id: project.id)?.narrationDrafts.first?.state, .ready)
        let placed = try await reopened.placeNarrationDraft(
            projectID: project.id, draftID: ready.id, expectedRevision: 0,
            startTime: 1, timingMode: .scene
        )
        XCTAssertEqual(placed.narrations.first?.language, "english")
        XCTAssertNotNil(placed.narrations.first?.sceneAnchor)
    }

    func test_voiceDraft_cancelAndMissingWAVNeverPublishPlayableAudio() async throws {
        for produceFile in [true, false] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let voice = ProductionVoice(delay: produceFile ? .milliseconds(100) : .zero, produceFile: produceFile)
            let (store, project) = try await fixture(root, voice: voice)
            let draft = try store.startNarrationDraft(
                projectID: project.id, voiceProfileID: store.voiceProfiles[0].id,
                text: "한국어 문장입니다.", language: "korean"
            )
            if produceFile {
                try await Task.sleep(for: .milliseconds(10))
                XCTAssertNotNil(store.storageChangeDisabledReason)
                try store.cancelNarrationDraft(projectID: project.id, draftID: draft.id)
            }
            let result = try await waitForDraft(store, projectID: project.id, draftID: draft.id)
            XCTAssertEqual(result.state, produceFile ? .cancelled : .failed)
            XCTAssertTrue(store.project(id: project.id)?.narrations.isEmpty == true)
            XCTAssertEqual(store.project(id: project.id)?.revision, 0)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: store.repository.assetURL(projectID: project.id, filename: draft.filename).path
            ))
        }
    }

    func test_agentTextEdits_resolveSceneAndPreserveUnrequestedCueProperties() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, project) = try await fixture(root)
        let host = StorybirdExternalControlHost(store: store)
        let context = try await command(host, "storybird_get_edit_context", ["project_id": project.id.uuidString])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(context.text.utf8)) as? [String: Any])
        let scenes = try XCTUnwrap(object["scenes"] as? [[String: Any]])
        XCTAssertEqual(scenes[0]["scene_number"] as? Int, 1)
        XCTAssertEqual(scenes[0]["clip_id"] as? String, project.clips[0].id.uuidString)
        XCTAssertEqual(store.project(id: project.id), project)
        let created = try await command(host, "storybird_create_click", [
            "project_id": project.id.uuidString, "expected_revision": 0,
            "time": 1.0, "x": 0.3, "y": 0.4, "description": "프로젝트를 만듭니다.", "subtitle": "Create a project.",
        ])
        XCTAssertFalse(created.isError, created.text)
        let cue = try XCTUnwrap(store.project(id: project.id)?.clicks.first)
        XCTAssertTrue(cue.isComplete)
        let edited = try await command(host, "storybird_update_click", [
            "project_id": project.id.uuidString, "expected_revision": 1,
            "click_id": cue.id.uuidString, "description": "새 프로젝트를 만듭니다.",
            "subtitle_font_size": 24.0,
        ])
        XCTAssertFalse(edited.isError, edited.text)
        let saved = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(saved.clicks[0].description.text, "새 프로젝트를 만듭니다.")
        XCTAssertEqual(saved.clicks[0].cueSubtitle.text, cue.cueSubtitle.text)
        XCTAssertEqual(saved.clicks[0].indicator, cue.indicator)
        let invalid = try await command(host, "storybird_update_click", [
            "project_id": project.id.uuidString, "expected_revision": 2, "click_id": cue.id.uuidString,
            "description": "Must not be saved", "indicator_opacity": 2.0,
        ])
        XCTAssertTrue(invalid.isError)
        XCTAssertEqual(store.project(id: project.id), saved)
        let preview = try await command(host, "storybird_render_preview", [
            "project_id": project.id.uuidString, "time": 1.0,
        ])
        XCTAssertFalse(preview.isError, preview.text)
        XCTAssertGreaterThan(preview.imageData?.count ?? 0, 0)
    }

    func test_agentCardAndSuggestionEdits_keepTimingAndDraftRevisionRules() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original) = try await fixture(root)
        var project = try VideoTimelineEditor.addClickCue(to: original, at: 1, x: 0.5, y: 0.5)
        project.clicks[0].description.text = "Button"
        project.clicks[0].cueSubtitle.text = "Click it"
        project.narrations = [NarrationClip(voiceProfileID: UUID(), filename: "narration.wav", text: "Explain", startTime: 2, duration: 1)]
        try TestVideoFactory.makeToneWAV(
            at: store.repository.assetURL(projectID: project.id, filename: "narration.wav"), duration: 1
        )
        try store.repository.saveProjects([project])
        let loaded = AppStore(repository: store.repository)
        let host = StorybirdExternalControlHost(store: loaded)
        let rejected = try await command(host, "storybird_reject_suggestion", [
            "project_id": project.id.uuidString, "expected_revision": 0,
            "suggestion_id": project.suggestions[0].id.uuidString,
        ])
        XCTAssertFalse(rejected.isError, rejected.text)
        XCTAssertEqual(loaded.project(id: project.id)?.revision, 0)
        XCTAssertThrowsError(try loaded.undo(projectID: project.id))
        let title = try await command(host, "storybird_insert_title", [
            "project_id": project.id.uuidString, "expected_revision": 0, "title": "소개", "duration": 1.0,
        ])
        XCTAssertFalse(title.isError, title.text)
        let titleID = try XCTUnwrap(loaded.project(id: project.id)?.effects.first?.id)
        let updated = try await command(host, "storybird_update_effect", [
            "project_id": project.id.uuidString, "expected_revision": 1,
            "effect_id": titleID.uuidString, "title": "Introduction", "end_time": 3.0,
        ])
        XCTAssertFalse(updated.isError, updated.text)
        let result = try XCTUnwrap(loaded.project(id: project.id))
        XCTAssertEqual(result.narrations[0].startTime, 5)
        XCTAssertEqual(result.clicks[0].time, 4)
        XCTAssertEqual(result.timelineDuration, 8)
        let restored = try loaded.undo(projectID: project.id)
        XCTAssertEqual(restored.narrations[0].startTime, 3)
    }

    func test_draftAndCopy_saveFailurePreservesReadyAudioAndOriginalProject() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, project) = try await fixture(root, voice: ProductionVoice())
        let draft = try store.startNarrationDraft(
            projectID: project.id, voiceProfileID: store.voiceProfiles[0].id, text: "Keep this audio", language: "english"
        )
        _ = try await waitForDraft(store, projectID: project.id, draftID: draft.id)
        let before = try XCTUnwrap(store.project(id: project.id))
        let library = root.appendingPathComponent("library.json")
        let backup = root.appendingPathComponent("saved-library.json")
        try FileManager.default.moveItem(at: library, to: backup)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        do {
            _ = try await store.placeNarrationDraft(projectID: project.id, draftID: draft.id, expectedRevision: 0, startTime: 1)
            XCTFail("Expected index write failure")
        } catch {}
        do {
            _ = try await store.duplicateProject(projectID: project.id, expectedRevision: 0)
            XCTFail("Expected copy publication failure")
        } catch {}
        XCTAssertEqual(store.project(id: project.id), before)
        XCTAssertEqual(store.projects.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.repository.assetURL(projectID: project.id, filename: draft.filename).path
        ))
        try FileManager.default.removeItem(at: library)
        try FileManager.default.moveItem(at: backup, to: library)
        let reopened = AppStore(repository: store.repository)
        XCTAssertEqual(reopened.project(id: project.id)?.narrationDrafts.first?.state, .ready)
        let placed = try await reopened.placeNarrationDraft(
            projectID: project.id, draftID: draft.id, expectedRevision: 0, startTime: 1
        )
        XCTAssertEqual(placed.revision, 1)
    }

    func test_fullReplacement_cannotBypassDraftPlacementOrReplaceSource() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, project) = try await fixture(root, voice: ProductionVoice())
        let draft = try store.startNarrationDraft(
            projectID: project.id, voiceProfileID: store.voiceProfiles[0].id, text: "Draft", language: "english"
        )
        _ = try await waitForDraft(store, projectID: project.id, draftID: draft.id)
        let current = try XCTUnwrap(store.project(id: project.id))
        var forged = current
        forged.narrationDrafts[0].state = .placed
        forged.narrations = [NarrationClip(
            id: draft.id, voiceProfileID: draft.voiceProfileID, filename: draft.filename,
            text: draft.text, startTime: 1, duration: 1
        )]
        XCTAssertThrowsError(try store.saveProject(forged, expectedRevision: 0))
        forged = current
        forged.recording?.filename = "different.mp4"
        XCTAssertThrowsError(try store.saveProject(forged, expectedRevision: 0))
        XCTAssertEqual(store.project(id: project.id), current)
    }

    func test_playbackRebuild_emptyTimelineCannotBeReplacedByOlderLoad() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, project) = try await fixture(root)
        let source = store.repository.assetURL(projectID: project.id, filename: project.recording!.filename)
        let playback = VideoPlaybackModel(url: source, project: project)
        var empty = project
        empty.clips = []
        playback.rebuild(url: source, project: empty)
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(playback.player.currentItem)
        XCTAssertEqual(playback.duration, 0)
    }

    func test_voiceWorker_drainsLargeOutputAndSerializesProcesses() async throws {
        guard ProcessInfo.processInfo.environment["STORYBIRD_VOICE_PYTHON"] == nil else {
            throw XCTSkip("Uses an isolated local worker instead of a configured live runtime.")
        }
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("VoiceRuntime")
        let worker = runtime.appendingPathComponent(".venv/bin/python")
        try FileManager.default.createDirectory(at: worker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test runtime".utf8).write(to: runtime.appendingPathComponent("model-ready.txt"))
        try TestVideoFactory.makeToneWAV(at: worker.deletingLastPathComponent().appendingPathComponent("template.wav"), duration: 1)
        let script = """
        #!/bin/sh
        base=${0%/*}
        mkdir "$base/active" || exit 9
        trap 'rmdir "$base/active"' EXIT
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --output) shift; output=$1 ;;
          esac
          shift
        done
        head -c 262144 /dev/zero
        head -c 262144 /dev/zero >&2
        cp "$base/template.wav" "$output"
        printf '\\n{"ok":true,"duration":1,"sample_rate":24000}\\n'
        """
        try Data(script.utf8).write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: worker.path)
        let service = VoiceSynthesisService(rootURL: root)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                async let first = service.generate(
                    text: "One", referenceAudioURL: root, referenceText: "Reference", language: "english",
                    outputURL: root.appendingPathComponent("one.wav")
                )
                async let second = service.generate(
                    text: "Two", referenceAudioURL: root, referenceText: "Reference", language: "english",
                    outputURL: root.appendingPathComponent("two.wav")
                )
                _ = try await (first, second)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw WorkerProbeError.timeout
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("one.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("two.wav").path))
    }

    func test_agentEditState_referenceSizePublishes95Of100ChangesWithin500ms() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectRepository(rootURL: root)
        let project = DemoProject(
            name: "Reference metadata",
            recording: VideoRecordingAsset(filename: "reference.mp4", duration: 120, width: 1920, height: 1080),
            subtitles: (0..<100).map {
                TimedSubtitle(startTime: Double($0), endTime: Double($0) + 0.8, text: "Sentence \($0)")
            }
        )
        try repo.saveProjects([project])
        let store = AppStore(repository: repo)
        let host = StorybirdExternalControlHost(store: store)
        var times: [Duration] = []
        for index in 0..<100 {
            let start = ContinuousClock.now
            let response = try await command(host, "storybird_upsert_subtitle", [
                "project_id": project.id.uuidString, "expected_revision": index,
                "subtitle_id": project.subtitles[0].id.uuidString,
                "start_time": 0.0, "end_time": 0.8, "text": "Revised sentence \(index)",
            ])
            XCTAssertFalse(response.isError, response.text)
            XCTAssertEqual(store.project(id: project.id)?.subtitles[0].text, "Revised sentence \(index)")
            times.append(start.duration(to: .now))
        }
        XCTAssertGreaterThanOrEqual(times.filter { $0 <= .milliseconds(500) }.count, 95)
        print("Reference edit-state publication p95: \(times.sorted()[94]); screen paint is not measured.")
    }

    func test_projectRoundTrip_afterNativeCreationDoesNotCreateAnEdit() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(repository: ProjectRepository(rootURL: root))
        let id = store.createProject(name: "Round trip")
        let host = StorybirdExternalControlHost(store: store)
        let fetched = try await command(host, "storybird_get_project", ["project_id": id.uuidString])
        XCTAssertFalse(fetched.isError)
        let response = try await command(host, "storybird_replace_project", [
            "project_id": id.uuidString, "expected_revision": 0, "project_json": fetched.text,
        ])
        XCTAssertFalse(response.isError, response.text)
        XCTAssertEqual(store.project(id: id)?.revision, 0)
        XCTAssertThrowsError(try store.undo(projectID: id))
    }

    /// Calls the same app command boundary used by the signed companion.
    private func command(_ host: StorybirdExternalControlHost, _ name: String, _ arguments: [String: Any]) async throws -> StorybirdControlResponse {
        await host.handle(StorybirdControlRequest(
            name: name, argumentsJSON: try JSONSerialization.data(withJSONObject: arguments)
        ))
    }

    /// Waits for a bounded synthetic job and its storage lease to settle.
    private func waitForDraft(_ store: AppStore, projectID: UUID, draftID: UUID) async throws -> NarrationDraft {
        for _ in 0..<500 {
            if let draft = store.project(id: projectID)?.narrationDrafts.first(where: { $0.id == draftID }),
               draft.state != .generating, store.storageChangeDisabledReason == nil { return draft }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Synthetic narration job did not finish")
        throw NarrationDraftError.notReady
    }

    /// Builds synthetic media in a temporary library, never touching user projects.
    private func fixture(_ root: URL, voice: (any VoiceSynthesisProviding)? = nil) async throws -> (AppStore, DemoProject) {
        let repo = ProjectRepository(rootURL: root)
        try repo.prepare()
        let id = UUID()
        let target = try repo.prepareVideoRecordingURL(projectID: id)
        let media = try await TestVideoFactory.makeMovie(at: target.url, includeAudio: false, duration: 5)
        let project = DemoProject(id: id, name: "Demo", recording: VideoRecordingAsset(
            filename: target.filename, duration: media.duration, width: media.width, height: media.height
        ))
        try repo.saveProjects([project])
        try repo.saveVoiceProfiles([VoiceProfile(
            name: "Synthetic voice", referenceFilename: "reference.wav", referenceText: "안녕하세요.",
            language: "korean", consentConfirmed: true
        )])
        let store = AppStore(repository: repo, voiceService: voice)
        return (store, try XCTUnwrap(store.project(id: id)))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}

private enum WorkerProbeError: Error {
    case timeout
}

private actor ProductionVoice: VoiceSynthesisProviding {
    private let delay: Duration
    private let produceFile: Bool
    private(set) var languages: [String] = []

    init(delay: Duration = .zero, produceFile: Bool = true) {
        self.delay = delay
        self.produceFile = produceFile
    }

    func prepared() -> Bool { true }
    func prepare() async throws {}

    /// Produces deterministic audio so lifecycle checks use no model or network.
    func generate(
        text: String, referenceAudioURL: URL, referenceText: String,
        language: String, outputURL: URL
    ) async throws -> VoiceSynthesisResult {
        languages.append(language)
        try await Task.sleep(for: delay)
        if produceFile { try TestVideoFactory.makeToneWAV(at: outputURL, duration: 1) }
        return VoiceSynthesisResult(duration: 1, sampleRate: 24_000)
    }
}
