import AVFoundation
import Foundation
import StorybirdCore
@testable import Storybird
import XCTest

@MainActor
final class ProjectAudioTests: XCTestCase {
    func test_longSilence_preservesLateSoundAndRangePreviewTiming() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("late.wav")
        try TestVideoFactory.makeToneWAV(at: source, duration: 1)
        var project = DemoProject(name: "Long silence", recording: VideoRecordingAsset(
            filename: "synthetic.mp4", duration: 1800, width: 64, height: 48))
        project.narrations = [NarrationClip(filename: source.lastPathComponent, text: "",
            startTime: 1798.5, duration: 1)]
        let composition = AVMutableComposition()
        let built = try await NarrationCompositionBuilder.addNarrations(
            project: project, assetsDirectory: root, composition: composition, sourceAudioTrack: nil)
        XCTAssertEqual(composition.duration.seconds, 1800, accuracy: 0.0001)
        let output = root.appendingPathComponent("range.wav")
        try AudioPreviewRenderer.write(asset: composition, tracks: built.tracks, mix: built.audioMix,
            startTime: 1798.3, duration: 1.4, destination: output)
        let summary = try ProjectAudioFiles.inspect(output)
        XCTAssertEqual(summary.duration, 1.4, accuracy: 0.001)
        let samples = try readSamples(output)
        XCTAssertLessThan(rms(samples, start: 0.01, end: 0.15), 0.0001)
        XCTAssertGreaterThan(rms(samples, start: 0.25, end: 1.15), 0.1)
        XCTAssertLessThan(rms(samples, start: 1.25, end: 1.39), 0.0001)
    }

    /// Uses a synthetic video and isolated library, never the user's media.
    private func fixture(includeAudio: Bool = false) async throws -> (URL, AppStore, DemoProject) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = ProjectRepository(rootURL: root)
        try repo.prepare()
        let id = UUID()
        let target = try repo.prepareVideoRecordingURL(projectID: id)
        let media = try await TestVideoFactory.makeMovie(at: target.url, includeAudio: includeAudio, duration: 5)
        let project = DemoProject(id: id, name: "Audio fixture", recording: VideoRecordingAsset(
            filename: target.filename, duration: media.duration, width: media.width, height: media.height
        ))
        try repo.saveProjects([project])
        let store = AppStore(repository: repo)
        return (root, store, try XCTUnwrap(store.project(id: id)))
    }

    func test_importAudio_registersReusableAssetWithoutRevisionAndSurvivesRestart() async throws {
        let (root, store, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.wav")
        try TestVideoFactory.makeToneWAV(at: input, duration: 2)
        let asset = try await store.importProjectAudio(projectID: project.id, sourceURL: input)
        try FileManager.default.removeItem(at: input)
        let reopened = AppStore(repository: store.repository)
        let restored = try XCTUnwrap(reopened.project(id: project.id))
        XCTAssertEqual(restored.revision, 0)
        XCTAssertEqual(restored.audioAssets, [asset])
        XCTAssertTrue(restored.narrations.isEmpty)
        XCTAssertNil(asset.voiceProfileID)
        let measured = try ProjectAudioFiles.inspect(store.repository.assetURL(projectID: project.id, filename: asset.filename))
        XCTAssertEqual(measured.duration, 2, accuracy: 0.001)
        XCTAssertGreaterThan(measured.peak, 0.01)
        XCTAssertEqual(measured.waveform.count, 128)
        XCTAssertThrowsError(try reopened.undo(projectID: project.id))
    }

    func test_importAudio_invalidFileAndSaveFailureLeaveProjectUnchanged() async throws {
        let (root, store, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("invalid.wav")
        try Data("not audio".utf8).write(to: input)
        do {
            _ = try await store.importProjectAudio(projectID: project.id, sourceURL: input)
            XCTFail("Invalid audio must fail")
        } catch {}
        XCTAssertEqual(store.project(id: project.id), project)
        try TestVideoFactory.makeToneWAV(at: root.appendingPathComponent("valid.wav"), duration: 1)
        let library = root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: library)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        do {
            _ = try await store.importProjectAudio(projectID: project.id, sourceURL: root.appendingPathComponent("valid.wav"))
            XCTFail("Failed publication must not expose an asset")
        } catch {}
        XCTAssertEqual(store.project(id: project.id), project)
        XCTAssertNil(store.storageChangeDisabledReason)
        let files = try FileManager.default.contentsOfDirectory(atPath: store.repository.assetsDirectory(projectID: project.id).path)
        XCTAssertEqual(files, [project.recording!.filename])
    }

    func test_legacyAudio_decodePreservesPlaybackDefaults() throws {
        let clip = NarrationClip(voiceProfileID: UUID(), filename: "legacy.wav", text: "Hello", startTime: 1, duration: 2)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(clip)) as? [String: Any])
        for key in ["assetID", "name", "sourceStart", "sourceDuration", "isMuted", "fadeIn", "fadeOut"] {
            json.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(NarrationClip.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, clip)
    }

    func test_audioLayers_overlapMixContainsThreeVoicesAndExportsOneTrack() async throws {
        let (root, store, initial) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = initial
        for frequency in [330.0, 550.0, 770.0] {
            let file = root.appendingPathComponent("\(frequency).wav")
            try TestVideoFactory.makeToneWAV(at: file, duration: 2, frequency: frequency)
            let asset = try await store.importProjectAudio(projectID: project.id, sourceURL: file)
            project = try store.placeAudioAsset(projectID: project.id, assetID: asset.id,
                expectedRevision: project.revision, startTime: 1)
        }
        XCTAssertEqual(project.narrations.count, 3)
        let source = store.repository.assetURL(projectID: project.id, filename: project.recording!.filename)
        let preview = try await AudioPreviewRenderer.render(project: project, sourceURL: source, startTime: 0, duration: 5)
        defer { try? FileManager.default.removeItem(atPath: preview.path) }
        let samples = try readSamples(URL(fileURLWithPath: preview.path))
        XCTAssertEqual(preview.duration, 5, accuracy: 0.001)
        XCTAssertLessThan(rms(samples, start: 0.1, end: 0.8), 0.0001)
        XCTAssertLessThan(rms(samples, start: 3.2, end: 4.8), 0.0001)
        for frequency in [330.0, 550.0, 770.0] {
            XCTAssertGreaterThan(toneAmplitude(samples, frequency: frequency, start: 1.3, end: 2.5), 0.1)
        }
        let output = root.appendingPathComponent("layered.mp4")
        _ = try await LayeredVideoExporter().export(project: project, sourceURL: source, destinationURL: output)
        let audio = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
        let exported = try await AudioPreviewRenderer.render(
            project: DemoProject(name: "Export inspection", recording: VideoRecordingAsset(
                filename: output.lastPathComponent, duration: 5, width: 64, height: 48
            )), sourceURL: output, startTime: 0, duration: 5
        )
        defer { try? FileManager.default.removeItem(atPath: exported.path) }
        let encoded = try readSamples(URL(fileURLWithPath: exported.path))
        for frequency in [330.0, 550.0, 770.0] {
            XCTAssertGreaterThan(toneAmplitude(encoded, frequency: frequency, start: 1.3, end: 2.5), 0.08)
        }
    }

    func test_audioLayers_fadeTrimMuteAndRangePreviewUseSameMix() async throws {
        let (root, store, initial) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("tone.wav")
        try TestVideoFactory.makeToneWAV(at: input, duration: 3)
        let asset = try await store.importProjectAudio(projectID: initial.id, sourceURL: input)
        var project = try store.placeAudioAsset(projectID: initial.id, assetID: asset.id, expectedRevision: 0,
            startTime: 1, sourceStart: 0.5, duration: 2)
        project.narrations[0].volume = 0.5
        project.narrations[0].fadeIn = 0.5
        project.narrations[0].fadeOut = 0.5
        project = try store.saveProject(project, expectedRevision: project.revision)
        let source = store.repository.assetURL(projectID: project.id, filename: project.recording!.filename)
        let preview = try await AudioPreviewRenderer.render(project: project, sourceURL: source, startTime: 1, duration: 2)
        defer { try? FileManager.default.removeItem(atPath: preview.path) }
        let samples = try readSamples(URL(fileURLWithPath: preview.path))
        XCTAssertEqual(preview.duration, 2, accuracy: 0.001)
        let full = rms(samples, start: 0.6, end: 1.4)
        XCTAssertGreaterThan(full, 0.04)
        XCTAssertLessThan(rms(samples, start: 0.01, end: 0.1), full * 0.3)
        XCTAssertLessThan(rms(samples, start: 1.9, end: 1.99), full * 0.3)
        project.narrations[0].isMuted = true
        let muted = try await AudioPreviewRenderer.render(project: project, sourceURL: source, startTime: 1, duration: 2)
        defer { try? FileManager.default.removeItem(atPath: muted.path) }
        XCTAssertEqual(muted.peak, 0, accuracy: 0.0001)
    }

    func test_audioLayers_gainAboveUnityIsNotClampedByVolumeRamp() async throws {
        let (root, store, initial) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("gain.wav")
        try TestVideoFactory.makeToneWAV(at: input, duration: 1)
        let asset = try await store.importProjectAudio(projectID: initial.id, sourceURL: input)
        var project = try store.placeAudioAsset(projectID: initial.id, assetID: asset.id, expectedRevision: 0, startTime: 1)
        project.narrations[0].volume = 2
        let preview = try await AudioPreviewRenderer.render(project: project,
            sourceURL: store.repository.assetURL(projectID: project.id, filename: project.recording!.filename), startTime: 1, duration: 1)
        defer { try? FileManager.default.removeItem(atPath: preview.path) }
        XCTAssertEqual(preview.peak, 0.5, accuracy: 0.02)
    }

    func test_audioLayers_splitInsideFadePreservesAudibleEnvelope() async throws {
        let (root, store, initial) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("split.wav")
        try TestVideoFactory.makeToneWAV(at: input, duration: 2)
        let asset = try await store.importProjectAudio(projectID: initial.id, sourceURL: input)
        var project = try store.placeAudioAsset(projectID: initial.id, assetID: asset.id, expectedRevision: 0, startTime: 1)
        project.narrations[0].fadeIn = 0.8
        project.narrations[0].fadeOut = 0.8
        project = try store.saveProject(project, expectedRevision: project.revision)
        let source = store.repository.assetURL(projectID: project.id, filename: project.recording!.filename)
        let before = try await AudioPreviewRenderer.render(project: project, sourceURL: source, startTime: 1, duration: 2)
        defer { try? FileManager.default.removeItem(atPath: before.path) }
        let split = try AudioLayerEditor.split(layerID: project.narrations[0].id, in: project, at: 1.4)
        let saved = try store.saveProject(split, expectedRevision: project.revision)
        let after = try await AudioPreviewRenderer.render(project: saved, sourceURL: source, startTime: 1, duration: 2)
        defer { try? FileManager.default.removeItem(atPath: after.path) }
        let originalSamples = try readSamples(URL(fileURLWithPath: before.path))
        let splitSamples = try readSamples(URL(fileURLWithPath: after.path))
        for start in stride(from: 0.1, through: 1.8, by: 0.1) {
            XCTAssertEqual(rms(splitSamples, start: start, end: start + 0.08),
                rms(originalSamples, start: start, end: start + 0.08), accuracy: 0.002)
        }
        XCTAssertEqual(saved.narrations[1].sourceStart, 0.4, accuracy: 0.0001)
        XCTAssertEqual(saved.narrations[0].assetID, saved.narrations[1].assetID)
    }

    func test_audioLayers_mcpEditsAreAtomicAndUndoRetainsReusableAsset() async throws {
        let (root, store, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("tone.wav")
        try TestVideoFactory.makeToneWAV(at: input, duration: 2)
        let asset = try await store.importProjectAudio(projectID: project.id, sourceURL: input)
        let host = StorybirdExternalControlHost(store: store)
        let placed = try await command(host, "storybird_place_audio_asset", [
            "project_id": project.id.uuidString, "expected_revision": 0, "asset_id": asset.id.uuidString, "start_time": 1.0,
        ])
        XCTAssertFalse(placed.isError, placed.text)
        var current = try XCTUnwrap(store.project(id: project.id))
        let layerID = current.narrations[0].id
        for fields: [String: Any] in [
            ["source_start": 1.0, "duration": 2.0], ["fade_in": -1.0],
            ["fade_in": 2.0, "fade_out": 1.0], ["muted": 1],
            ["start_time": 4.0], ["volume": -0.1], ["unexpected": true],
        ] {
            let response = try await command(host, "storybird_update_audio_layer", [
                "project_id": project.id.uuidString, "expected_revision": current.revision, "layer_id": layerID.uuidString,
            ].merging(fields) { _, new in new })
            XCTAssertTrue(response.isError, response.text)
            XCTAssertEqual(store.project(id: project.id), current)
        }
        let edited = try await command(host, "storybird_update_audio_layer", [
            "project_id": project.id.uuidString, "expected_revision": current.revision, "layer_id": layerID.uuidString,
            "source_start": 0.5, "duration": 1.0, "volume": 0.25, "muted": true, "fade_in": 0.1, "fade_out": 0.2,
        ])
        XCTAssertFalse(edited.isError, edited.text)
        current = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(current.revision, 2)
        let duplicate = try await command(host, "storybird_duplicate_audio_layer", [
            "project_id": project.id.uuidString, "expected_revision": 2, "layer_id": layerID.uuidString,
        ])
        XCTAssertFalse(duplicate.isError, duplicate.text)
        XCTAssertEqual(store.project(id: project.id)?.narrations.count, 2)
        let split = try await command(host, "storybird_split_audio_layer", [
            "project_id": project.id.uuidString, "expected_revision": 3, "layer_id": layerID.uuidString, "time": 1.5,
        ])
        XCTAssertFalse(split.isError, split.text)
        current = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(current.narrations.count, 3)
        XCTAssertEqual(Set(current.narrations.map(\.filename)), [asset.filename])
        _ = try store.undo(projectID: project.id)
        XCTAssertEqual(store.project(id: project.id)?.narrations.count, 2)
        _ = try store.redo(projectID: project.id)
        XCTAssertEqual(store.project(id: project.id)?.narrations.count, 3)
        let listed = try await command(host, "storybird_list_audio_assets", ["project_id": project.id.uuidString])
        XCTAssertFalse(listed.isError, listed.text)
        XCTAssertTrue(listed.text.contains("waveform"))
        let stale = try await command(host, "storybird_delete_audio_layer", [
            "project_id": project.id.uuidString, "expected_revision": 0, "layer_id": layerID.uuidString,
        ])
        XCTAssertTrue(stale.isError)
    }

    func test_microphoneLease_excludesScreenAndOtherMicrophonesBeforeInputStarts() async throws {
        let (root, store, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try store.beginMicrophoneOperation()
        XCTAssertFalse(store.canStartScreenRecording)
        XCTAssertThrowsError(try store.beginMicrophoneOperation())
        store.endStorageOperation(lease)
        XCTAssertTrue(store.canStartScreenRecording)
        let screen = store.beginStorageOperation(.recording)
        XCTAssertThrowsError(try store.beginMicrophoneOperation())
        store.endStorageOperation(screen)
        let next = try store.beginMicrophoneOperation()
        store.endStorageOperation(next)
        XCTAssertNil(store.storageChangeDisabledReason)
    }

    func test_sourceAudio_gainAndMuteApplyToUneditedMovieExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        let media = try await TestVideoFactory.makeMovie(at: source, includeAudio: true, audioStart: 0.25, duration: 2)
        var project = DemoProject(name: "Source gain", recording: VideoRecordingAsset(
            filename: source.lastPathComponent, duration: media.duration, width: media.width, height: media.height
        ))
        let baseline = try await TestVideoFactory.averageAmplitude(in: source, from: 0.5, to: 1.5)
        project.sourceAudioVolume = 2
        let boosted = root.appendingPathComponent("boosted.mp4")
        _ = try await LayeredVideoExporter().export(project: project, sourceURL: source, destinationURL: boosted)
        let amplified = try await TestVideoFactory.averageAmplitude(in: boosted, from: 0.5, to: 1.5)
        XCTAssertEqual(amplified / baseline, 2, accuracy: 0.1)
        project.sourceAudioMuted = true
        let muted = root.appendingPathComponent("muted.mp4")
        _ = try await LayeredVideoExporter().export(project: project, sourceURL: source, destinationURL: muted)
        let silence = try await TestVideoFactory.averageAmplitude(in: muted, from: 0.5, to: 1.5)
        XCTAssertLessThan(silence, 0.001)
    }

    func test_audioImport_compressedFilesAndShortRecordingProduceReusableWAVs() async throws {
        let (root, store, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let short = root.appendingPathComponent("short.wav")
        try TestVideoFactory.makeToneWAV(at: short, duration: 0.2)
        let recorded = try await store.importProjectAudio(projectID: project.id, sourceURL: short, origin: .recorded)
        XCTAssertEqual(recorded.duration, 0.2, accuracy: 0.002)
        XCTAssertEqual(recorded.origin, .recorded)
        let mp3 = root.appendingPathComponent("compressed.mp3")
        try TestVideoFactory.makeMP3(at: mp3, duration: 1)
        let imported = try await store.importProjectAudio(projectID: project.id, sourceURL: mp3)
        XCTAssertEqual(imported.duration, 1, accuracy: 0.1)
        let m4a = root.appendingPathComponent("compressed.m4a")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: short), presetName: AVAssetExportPresetAppleM4A))
        exporter.outputURL = m4a
        exporter.outputFileType = .m4a
        await exporter.export()
        XCTAssertEqual(exporter.status, .completed, exporter.error?.localizedDescription ?? "")
        let importedM4A = try await store.importProjectAudio(projectID: project.id, sourceURL: m4a)
        XCTAssertEqual(importedM4A.duration, 0.2, accuracy: 0.05)
        XCTAssertEqual(store.project(id: project.id)?.revision, 0)
    }

    func test_amplificationLease_reusesLiveFileAndDeletesAfterFinalConsumer() async throws {
        let (root, _, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("leased.wav")
        try TestVideoFactory.makeToneWAV(at: source, duration: 1)
        let cache = AmplifiedAudioFiles()
        var first: AudioFileLease? = try await cache.lease(for: source, gain: 2)
        let path = try XCTUnwrap(first?.url)
        var second: AudioFileLease? = try await cache.lease(for: source, gain: 2)
        XCTAssertTrue(first === second)
        first = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        second = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        for gain in [2.0, 3.0, 4.0] {
            var lease: AudioFileLease? = try await cache.lease(for: source, gain: gain)
            let temporary = try XCTUnwrap(lease?.url)
            lease = nil
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func test_waveformCache_sharesConcurrentReadsAndRefreshesReplacedSource() async throws {
        let (root, _, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("waveform.wav")
        try TestVideoFactory.makeToneWAV(at: source, duration: 1)
        let counter = AudioReadCounter()
        let cache = AudioWaveformCache { url in
            counter.increment()
            return try ProjectAudioFiles.inspect(url)
        }
        async let first = cache.summary(for: source)
        async let second = cache.summary(for: source)
        let values = try await (first, second)
        XCTAssertEqual(values.0.waveform, values.1.waveform)
        XCTAssertEqual(counter.count, 1)
        try TestVideoFactory.makeToneWAV(at: source, duration: 2)
        let changed = try await cache.summary(for: source)
        XCTAssertEqual(changed.duration, 2, accuracy: 0.001)
        XCTAssertEqual(counter.count, 2)
    }

    func test_audioExport_stereoSurvivesMonoRowsAndRowReordering() async throws {
        for includePrimary in [false, true] {
            let (root, store, initial) = try await fixture(includeAudio: includePrimary)
            defer { try? FileManager.default.removeItem(at: root) }
            let mono = root.appendingPathComponent("mono.wav")
            try TestVideoFactory.makeToneWAV(at: mono, duration: 1, frequency: 330)
            let stereo = root.appendingPathComponent("stereo.wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            do {
                let file = try AVAudioFile(forWriting: stereo, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
                buffer.frameLength = 48_000
                for frame in 0..<48_000 {
                    let sample = Float(0.2 * sin(2 * Double.pi * 660 * Double(frame) / 48_000))
                    buffer.floatChannelData![0][frame] = sample
                    buffer.floatChannelData![1][frame] = -sample
                }
                try file.write(from: buffer)
            }
            var project = initial
            for url in [mono, stereo] {
                let asset = try await store.importProjectAudio(projectID: initial.id, sourceURL: url)
                project = try store.placeAudioAsset(projectID: initial.id, assetID: asset.id, expectedRevision: project.revision, startTime: 1)
            }
            for order in 0..<2 {
                if order == 1 { project.narrations.reverse() }
                let output = root.appendingPathComponent("order-\(order).mp4")
                _ = try await LayeredVideoExporter().export(project: project,
                    sourceURL: store.repository.assetURL(projectID: initial.id, filename: initial.recording!.filename),
                    destinationURL: output)
                let movie = AVURLAsset(url: output)
                let tracks = try await movie.loadTracks(withMediaType: .audio)
                XCTAssertEqual(tracks.count, 1)
                let descriptions = try await tracks[0].load(.formatDescriptions)
                XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(descriptions[0])?.pointee.mChannelsPerFrame, 2)
                let inspected = try await AudioPreviewRenderer.render(
                    project: DemoProject(name: "Stereo verification", recording: VideoRecordingAsset(
                        filename: output.lastPathComponent, duration: 5, width: 64, height: 48
                    )), sourceURL: output, startTime: 0, duration: 5
                )
                defer { try? FileManager.default.removeItem(atPath: inspected.path) }
                let samples = try readSamples(URL(fileURLWithPath: inspected.path))
                XCTAssertGreaterThan(toneAmplitude(samples, frequency: 660, start: 1.2, end: 1.8), 0.18)
            }
        }
    }

    func test_fullReplacement_rejectsDanglingAssetIdentityAndDurationWithoutEditing() async throws {
        let (root, store, initial) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("identity.wav")
        try TestVideoFactory.makeToneWAV(at: input, duration: 2)
        let asset = try await store.importProjectAudio(projectID: initial.id, sourceURL: input)
        let saved = try store.placeAudioAsset(projectID: initial.id, assetID: asset.id, expectedRevision: 0, startTime: 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let host = StorybirdExternalControlHost(store: store)
        for changeID in [true, false] {
            var forged = saved
            if changeID { forged.narrations[0].assetID = UUID() }
            else { forged.narrations[0].sourceDuration += 0.01 }
            let response = try await command(host, "storybird_replace_project", [
                "project_id": saved.id.uuidString, "expected_revision": saved.revision,
                "project_json": String(decoding: try encoder.encode(forged), as: UTF8.self),
            ])
            XCTAssertTrue(response.isError, response.text)
            XCTAssertEqual(store.project(id: saved.id), saved)
        }
    }

    /// Runs actual host routing with JSON rather than bypassing wire validation.
    private func command(_ host: StorybirdExternalControlHost, _ name: String, _ arguments: [String: Any]) async throws -> StorybirdControlResponse {
        await host.handle(StorybirdControlRequest(name: name, argumentsJSON: try JSONSerialization.data(withJSONObject: arguments)))
    }

    /// Reads one test WAV in float format for signal-level assertions.
    private func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// Measures audible energy without relying on a particular encoder's bytes.
    private func rms(_ samples: [Float], start: Double, end: Double) -> Double {
        let part = samples[Int(start * 48_000)..<min(samples.count, Int(end * 48_000))]
        return sqrt(part.reduce(0.0) { $0 + Double($1 * $1) } / Double(part.count))
    }

    /// Correlates both phases so AAC phase shifts cannot hide a missing voice.
    private func toneAmplitude(_ samples: [Float], frequency: Double, start: Double, end: Double) -> Double {
        let first = Int(start * 48_000)
        let last = min(samples.count, Int(end * 48_000))
        var sine = 0.0
        var cosine = 0.0
        for index in first..<last {
            let phase = 2 * Double.pi * frequency * Double(index) / 48_000
            sine += Double(samples[index]) * sin(phase)
            cosine += Double(samples[index]) * cos(phase)
        }
        return 2 * hypot(sine, cosine) / Double(last - first)
    }
}

private final class AudioReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
