import AVFoundation
import Foundation
import StorybirdCore
@testable import Storybird
import XCTest

@MainActor
final class AppStoreTests: XCTestCase {
    func test_voiceSynthesisEnvironment_disablesNetworkAfterPreparation() {
        let cache = URL(fileURLWithPath: "/tmp/storybird-model-cache")

        let preparation = VoiceSynthesisService.processEnvironment(
            base: [:],
            modelCacheURL: cache,
            allowNetwork: true
        )
        let generation = VoiceSynthesisService.processEnvironment(
            base: [:],
            modelCacheURL: cache,
            allowNetwork: false
        )

        XCTAssertEqual(preparation["HF_HOME"], cache.path)
        XCTAssertNil(preparation["HF_HUB_OFFLINE"])
        XCTAssertEqual(generation["HF_HUB_OFFLINE"], "1")
        XCTAssertEqual(generation["TRANSFORMERS_OFFLINE"], "1")
    }

    func test_replacePreparedRuntime_missingStagingRestoresActiveRuntime() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appendingPathComponent(
            "VoiceRuntime",
            isDirectory: true
        )
        let staging = root.appendingPathComponent(
            "VoiceRuntime.staging-missing",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: active,
            withIntermediateDirectories: true
        )
        let marker = active.appendingPathComponent("model-ready.txt")
        try Data("working".utf8).write(to: marker)

        XCTAssertThrowsError(
            try VoiceSynthesisService.replacePreparedRuntime(
                active: active,
                staging: staging
            )
        )

        XCTAssertEqual(
            String(decoding: try Data(contentsOf: marker), as: UTF8.self),
            "working"
        )
    }

    func test_replacePreparedRuntime_completeStagingReplacesActiveRuntime() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appendingPathComponent(
            "VoiceRuntime",
            isDirectory: true
        )
        let staging = root.appendingPathComponent(
            "VoiceRuntime.staging-ready",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: active,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(
            to: active.appendingPathComponent("model-ready.txt")
        )
        try Data("new".utf8).write(
            to: staging.appendingPathComponent("model-ready.txt")
        )

        try VoiceSynthesisService.replacePreparedRuntime(
            active: active,
            staging: staging
        )

        XCTAssertEqual(
            String(
                decoding: try Data(
                    contentsOf: active.appendingPathComponent(
                        "model-ready.txt"
                    )
                ),
                as: UTF8.self
            ),
            "new"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func test_importVoiceProfile_copiesAuthorizedReference() async throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let source = sourceRoot.appendingPathComponent("my-voice.wav")
        try TestVideoFactory.makeToneWAV(at: source, duration: 3.2)
        let repository = ProjectRepository(rootURL: root)
        let store = AppStore(repository: repository)

        let profile = try await store.importVoiceProfile(
            name: "My voice",
            sourceURL: source,
            transcript: "안녕하세요. 제 목소리입니다.",
            consentConfirmed: true
        )

        XCTAssertEqual(store.voiceProfiles.map(\.id), [profile.id])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repository.voiceReferenceURL(
                    profileID: profile.id,
                    filename: profile.referenceFilename
                ).path
            )
        )
    }

    func test_importVoiceProfile_acceptsShortExternalButRejectsMissingConsent() async throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let source = sourceRoot.appendingPathComponent("short.wav")
        try TestVideoFactory.makeToneWAV(at: source, duration: 1)
        let store = AppStore(
            repository: ProjectRepository(rootURL: root)
        )

        let profile = try await store.importVoiceProfile(
            name: "Short external",
            sourceURL: source,
            transcript: "짧은 외부 음성",
            consentConfirmed: true
        )

        do {
            _ = try await store.importVoiceProfile(
                name: "No consent",
                sourceURL: source,
                transcript: "짧은 음성",
                consentConfirmed: false
            )
            XCTFail("Expected consent rejection")
        } catch VoiceProfileError.invalidInput {}
        XCTAssertEqual(store.voiceProfiles.map(\.id), [profile.id])
    }

    func test_importVoiceProfile_microphoneRequiresTenSeconds() async throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let short = sourceRoot.appendingPathComponent("short-mic.wav")
        let long = sourceRoot.appendingPathComponent("long-mic.wav")
        try TestVideoFactory.makeToneWAV(at: short, duration: 9.9)
        try TestVideoFactory.makeToneWAV(at: long, duration: 10.1)
        let store = AppStore(
            repository: ProjectRepository(rootURL: root)
        )

        do {
            _ = try await store.importVoiceProfile(
                name: "Short microphone",
                sourceURL: short,
                transcript: VoiceStudioView.recordingPrompt,
                source: .microphone,
                consentConfirmed: true
            )
            XCTFail("Expected short microphone rejection")
        } catch VoiceProfileError.referenceTooShort {}

        let profile = try await store.importVoiceProfile(
            name: "Long microphone",
            sourceURL: long,
            transcript: VoiceStudioView.recordingPrompt,
            source: .microphone,
            consentConfirmed: true
        )
        XCTAssertEqual(store.voiceProfiles.map(\.id), [profile.id])
    }

    func test_voiceRecordingPresentation_enforcesBoundaryAndMeterRange() {
        XCTAssertEqual(VoiceRecordingRequirements.minimumDuration, 10)
        XCTAssertEqual(
            VoiceRecordingPresentation.remainingDuration(elapsed: 0),
            10
        )
        XCTAssertEqual(
            VoiceRecordingPresentation.remainingDuration(elapsed: 9.9),
            0.1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            VoiceRecordingPresentation.remainingDuration(elapsed: 9.99),
            0.1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            VoiceRecordingPresentation.remainingDuration(elapsed: 10),
            0
        )
        XCTAssertEqual(
            VoiceRecordingPresentation.normalizedLevel(decibels: -80),
            0
        )
        XCTAssertEqual(
            VoiceRecordingPresentation.normalizedLevel(decibels: -25),
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            VoiceRecordingPresentation.normalizedLevel(decibels: 0),
            1
        )
        XCTAssertEqual(
            VoiceRecordingPresentation.formattedDuration(9.99),
            "00:09.9"
        )
    }

    func test_voiceRecordingPrompt_coversQuestionsEmphasisAndConnectedNarration() {
        let prompt = VoiceStudioView.recordingPrompt

        XCTAssertGreaterThanOrEqual(
            prompt.filter { $0 == "?" }.count,
            1
        )
        XCTAssertEqual(prompt, VoiceLanguage.korean.referencePrompt)
        XCTAssertTrue(prompt.contains("중요한 부분"))
        XCTAssertTrue(prompt.contains("자연스럽게"))
    }

    func test_voiceInputPermissionPolicy_requiresConsentBeforeSensitiveInput() {
        XCTAssertFalse(
            VoiceInputPermissionPolicy.canStart(
                consentConfirmed: false,
                hasSession: false,
                isWorking: false
            )
        )
        XCTAssertTrue(
            VoiceInputPermissionPolicy.canStart(
                consentConfirmed: true,
                hasSession: false,
                isWorking: false
            )
        )
        XCTAssertFalse(
            VoiceInputPermissionPolicy.canStart(
                consentConfirmed: true,
                hasSession: true,
                isWorking: false
            )
        )
        XCTAssertFalse(
            VoiceInputPermissionPolicy.canStart(
                consentConfirmed: true,
                hasSession: false,
                isWorking: true
            )
        )
        XCTAssertFalse(
            VoiceInputPermissionPolicy.consentIsLocked(
                hasSession: false,
                isWorking: false
            )
        )
        XCTAssertTrue(
            VoiceInputPermissionPolicy.consentIsLocked(
                hasSession: true,
                isWorking: false
            )
        )
        XCTAssertTrue(
            VoiceInputPermissionPolicy.canRestart(
                consentConfirmed: true,
                isWorking: false
            )
        )
        XCTAssertFalse(
            VoiceInputPermissionPolicy.canRestart(
                consentConfirmed: false,
                isWorking: false
            )
        )
        XCTAssertFalse(
            VoiceInputPermissionPolicy.canRestart(
                consentConfirmed: true,
                isWorking: true
            )
        )
    }

    func test_voiceRecordingPrompt_defaultKoreanSpeechFitsTargetDuration() async throws {
        let output = temporaryDirectory()
            .appendingPathComponent("guided-prompt.aiff")
        defer {
            try? FileManager.default.removeItem(
                at: output.deletingLastPathComponent()
            )
        }
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-v", "Yuna",
            "-o", output.path,
            VoiceStudioView.recordingPrompt,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("The macOS Yuna Korean voice is unavailable.")
        }

        let duration = CMTimeGetSeconds(
            try await AVURLAsset(url: output).load(.duration)
        )
        XCTAssertGreaterThanOrEqual(duration, 10)
        XCTAssertLessThanOrEqual(duration, 15)
    }

    func test_importVoiceProfile_acceptsMP3() async throws {
        guard FileManager.default.fileExists(
            atPath: "/opt/homebrew/bin/ffmpeg"
        ) else {
            throw XCTSkip("ffmpeg is unavailable for the MP3 fixture.")
        }
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let source = sourceRoot.appendingPathComponent("my-voice.mp3")
        try TestVideoFactory.makeMP3(at: source, duration: 3.2)
        let store = AppStore(
            repository: ProjectRepository(rootURL: root)
        )

        let profile = try await store.importVoiceProfile(
            name: "MP3 voice",
            sourceURL: source,
            transcript: "엠피쓰리 음성입니다.",
            consentConfirmed: true
        )

        XCTAssertEqual(
            (profile.referenceFilename as NSString).pathExtension,
            "mp3"
        )
    }

    func test_generateNarration_savesCompleteAssetAndRevision() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let profile = VoiceProfile(
            name: "My voice",
            referenceFilename: "reference.wav",
            referenceText: "안녕하세요.",
            consentConfirmed: true
        )
        try repository.saveVoiceProfiles([profile])
        let reference = try repository.prepareVoiceReferenceURL(
            profileID: profile.id,
            fileExtension: "wav"
        )
        try TestVideoFactory.makeToneWAV(at: reference.url, duration: 3)
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(
            repository: repository,
            voiceService: FakeVoiceSynthesisService()
        )

        let saved = try await store.generateNarration(
            projectID: project.id,
            expectedRevision: 0,
            voiceProfileID: profile.id,
            text: "서비스를 소개합니다.",
            language: "korean",
            startTime: 1
        )

        XCTAssertEqual(saved.revision, 1)
        XCTAssertEqual(saved.narrations.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repository.assetURL(
                    projectID: project.id,
                    filename: saved.narrations[0].filename
                ).path
            )
        )
    }

    func test_generateNarration_unconfirmedProfileCreatesNoAsset() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let profile = VoiceProfile(
            name: "Unconfirmed",
            referenceFilename: "reference.wav",
            referenceText: "안녕하세요.",
            consentConfirmed: false
        )
        try repository.saveVoiceProfiles([profile])
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(
            repository: repository,
            voiceService: FakeVoiceSynthesisService()
        )

        do {
            _ = try await store.generateNarration(
                projectID: project.id,
                expectedRevision: 0,
                voiceProfileID: profile.id,
                text: "생성하면 안 됩니다.",
                language: "korean",
                startTime: 1
            )
            XCTFail("Expected unconfirmed profile rejection")
        } catch VoiceProfileError.profileNotFound {}

        XCTAssertTrue(store.project(id: project.id)?.narrations.isEmpty == true)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repository.assetsDirectory(
                    projectID: project.id
                ).path
            )
        )
    }

    func test_generateNarration_missingWAVPreservesProject() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, profile, project) = try voiceFixture(root: root)
        let store = AppStore(
            repository: repository,
            voiceService: MissingWAVVoiceSynthesisService()
        )

        do {
            _ = try await store.generateNarration(
                projectID: project.id,
                expectedRevision: 0,
                voiceProfileID: profile.id,
                text: "파일 없는 성공 응답",
                language: "korean",
                startTime: 1
            )
            XCTFail("Expected missing WAV rejection")
        } catch {}

        XCTAssertEqual(store.project(id: project.id)?.revision, 0)
        XCTAssertTrue(store.project(id: project.id)?.narrations.isEmpty == true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: repository.assetsDirectory(projectID: project.id),
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(files.isEmpty)
    }

    func test_generateNarration_wrongDurationRemovesWAVAndPreservesProject() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, profile, project) = try voiceFixture(root: root)
        let store = AppStore(
            repository: repository,
            voiceService: WrongDurationVoiceSynthesisService()
        )

        do {
            _ = try await store.generateNarration(
                projectID: project.id,
                expectedRevision: 0,
                voiceProfileID: profile.id,
                text: "길이가 틀린 성공 응답",
                language: "korean",
                startTime: 1
            )
            XCTFail("Expected duration mismatch rejection")
        } catch VoiceSynthesisError.invalidResponse {}

        XCTAssertEqual(store.project(id: project.id)?.revision, 0)
        XCTAssertTrue(store.project(id: project.id)?.narrations.isEmpty == true)
        let files = try FileManager.default.contentsOfDirectory(
            at: repository.assetsDirectory(projectID: project.id),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(
            files.contains { $0.lastPathComponent.hasPrefix("narration-") }
        )
    }

    func test_generateNarration_cancelledTaskRemovesPartialWAV() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, profile, project) = try voiceFixture(root: root)
        let store = AppStore(
            repository: repository,
            voiceService: SlowVoiceSynthesisService()
        )
        let task = Task {
            try await store.generateNarration(
                projectID: project.id,
                expectedRevision: 0,
                voiceProfileID: profile.id,
                text: "취소할 합성",
                language: "korean",
                startTime: 1
            )
        }
        for _ in 0..<100 {
            let directory = repository.assetsDirectory(
                projectID: project.id
            )
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []
            if files.contains(where: {
                $0.lastPathComponent.hasPrefix("narration-")
            }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        XCTAssertEqual(store.project(id: project.id)?.revision, 0)
        XCTAssertTrue(store.project(id: project.id)?.narrations.isEmpty == true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: repository.assetsDirectory(projectID: project.id),
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertFalse(
            files.contains { $0.lastPathComponent.hasPrefix("narration-") }
        )
    }

    func test_externalControl_generateNarration_usesExistingProfile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let profile = VoiceProfile(
            name: "Agent voice",
            referenceFilename: "reference.wav",
            referenceText: "안녕하세요.",
            consentConfirmed: true
        )
        try repository.saveVoiceProfiles([profile])
        let reference = try repository.prepareVoiceReferenceURL(
            profileID: profile.id,
            fileExtension: "wav"
        )
        try TestVideoFactory.makeToneWAV(at: reference.url, duration: 3)
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(
            repository: repository,
            voiceService: FakeVoiceSynthesisService()
        )
        let host = StorybirdExternalControlHost(store: store)
        let arguments = try JSONSerialization.data(
            withJSONObject: [
                "project_id": project.id.uuidString,
                "expected_revision": 0,
                "voice_profile_id": profile.id.uuidString,
                "text": "에이전트가 생성한 설명입니다.",
                "language": "korean",
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
        XCTAssertEqual(store.project(id: project.id)?.revision, 1)
        XCTAssertEqual(store.project(id: project.id)?.narrations.count, 1)

        let generated = try XCTUnwrap(
            store.project(id: project.id)?.narrations.first
        )
        let updateArguments = try JSONSerialization.data(
            withJSONObject: [
                "project_id": project.id.uuidString,
                "expected_revision": 1,
                "narration_id": generated.id.uuidString,
                "text": "에이전트가 수정한 설명입니다.",
            ]
        )
        let updateResponse = await host.handle(
            StorybirdControlRequest(
                name: "storybird_update_narration",
                argumentsJSON: updateArguments
            )
        )

        XCTAssertFalse(updateResponse.isError)
        XCTAssertEqual(store.project(id: project.id)?.revision, 2)
        XCTAssertEqual(
            store.project(id: project.id)?.narrations.first?.text,
            "에이전트가 수정한 설명입니다."
        )
        XCTAssertNotEqual(
            store.project(id: project.id)?.narrations.first?.filename,
            generated.filename
        )
    }

    func test_externalControl_listVoiceProfiles_omitsSensitiveReferenceData() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let profile = VoiceProfile(
            name: "Private voice",
            referenceFilename: "reference-secret.wav",
            referenceText: "외부로 반환하면 안 되는 정확한 대본",
            consentConfirmed: true
        )
        try repository.saveVoiceProfiles([profile])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_list_voice_profiles",
                argumentsJSON: Data("{}".utf8)
            )
        )

        XCTAssertFalse(response.isError)
        XCTAssertTrue(response.text.contains(profile.id.uuidString))
        XCTAssertTrue(response.text.contains("Private voice"))
        XCTAssertFalse(response.text.contains(profile.referenceFilename))
        XCTAssertFalse(response.text.contains(profile.referenceText))
        XCTAssertFalse(response.text.contains("consentConfirmed"))
    }

    func test_deleteVoiceProfile_preservesProjectOwnedNarration() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let profile = VoiceProfile(
            name: "Disposable reference",
            referenceFilename: "reference.wav",
            referenceText: "안녕하세요.",
            consentConfirmed: true
        )
        try repository.saveVoiceProfiles([profile])
        let reference = try repository.prepareVoiceReferenceURL(
            profileID: profile.id,
            fileExtension: "wav"
        )
        try TestVideoFactory.makeToneWAV(at: reference.url, duration: 3)
        var project = validVideoProject()
        let narration = try repository.prepareNarrationURL(
            projectID: project.id
        )
        try TestVideoFactory.makeToneWAV(at: narration.url, duration: 0.5)
        project.narrations = [
            NarrationClip(
                voiceProfileID: profile.id,
                filename: narration.filename,
                text: "기존 프로젝트 음성",
                startTime: 1,
                duration: 0.5
            ),
        ]
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)

        try store.deleteVoiceProfile(id: profile.id)

        XCTAssertTrue(store.voiceProfiles.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: reference.url.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: narration.url.path)
        )
        XCTAssertEqual(store.project(id: project.id)?.narrations.count, 1)
    }

    func test_generateNarration_staleRevisionRemovesUnreferencedWAV() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let profile = VoiceProfile(
            name: "My voice",
            referenceFilename: "reference.wav",
            referenceText: "안녕하세요.",
            consentConfirmed: true
        )
        try repository.saveVoiceProfiles([profile])
        let reference = try repository.prepareVoiceReferenceURL(
            profileID: profile.id,
            fileExtension: "wav"
        )
        try TestVideoFactory.makeToneWAV(at: reference.url, duration: 3)
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(
            repository: repository,
            voiceService: FakeVoiceSynthesisService()
        )

        do {
            _ = try await store.generateNarration(
                projectID: project.id,
                expectedRevision: 99,
                voiceProfileID: profile.id,
                text: "저장되지 않을 음성",
                language: "korean",
                startTime: 1
            )
            XCTFail("Expected revision conflict")
        } catch RecordingStoreError.revisionConflict {}

        XCTAssertTrue(store.project(id: project.id)?.narrations.isEmpty == true)
        let directory = repository.assetsDirectory(projectID: project.id)
        let files = FileManager.default.fileExists(atPath: directory.path)
            ? try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            : []
        XCTAssertFalse(
            files.contains { $0.lastPathComponent.hasPrefix("narration-") }
        )
    }

    func test_updateNarration_changedTextReplacesOnlySelectedWAV() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let profile = VoiceProfile(
            name: "My voice",
            referenceFilename: "reference.wav",
            referenceText: "안녕하세요.",
            consentConfirmed: true
        )
        try repository.saveVoiceProfiles([profile])
        let reference = try repository.prepareVoiceReferenceURL(
            profileID: profile.id,
            fileExtension: "wav"
        )
        try TestVideoFactory.makeToneWAV(at: reference.url, duration: 3)
        var project = validVideoProject()
        let first = try repository.prepareNarrationURL(
            projectID: project.id
        )
        let second = try repository.prepareNarrationURL(
            projectID: project.id
        )
        try TestVideoFactory.makeToneWAV(at: first.url, duration: 0.5)
        try TestVideoFactory.makeToneWAV(at: second.url, duration: 0.5)
        let firstClip = NarrationClip(
            voiceProfileID: profile.id,
            filename: first.filename,
            text: "기존 첫 문장",
            startTime: 1,
            duration: 0.5
        )
        let secondClip = NarrationClip(
            voiceProfileID: profile.id,
            filename: second.filename,
            text: "유지할 둘째 문장",
            startTime: 3,
            duration: 0.5
        )
        project.narrations = [firstClip, secondClip]
        try repository.saveProjects([project])
        let store = AppStore(
            repository: repository,
            voiceService: FakeVoiceSynthesisService()
        )

        let saved = try await store.updateNarration(
            projectID: project.id,
            narrationID: firstClip.id,
            expectedRevision: 0,
            text: "바뀐 첫 문장"
        )

        let updated = try XCTUnwrap(
            saved.narrations.first { $0.id == firstClip.id }
        )
        let unchanged = try XCTUnwrap(
            saved.narrations.first { $0.id == secondClip.id }
        )
        XCTAssertEqual(saved.revision, 1)
        XCTAssertEqual(updated.text, "바뀐 첫 문장")
        XCTAssertNotEqual(updated.filename, first.filename)
        XCTAssertEqual(unchanged, secondClip)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repository.assetURL(
                    projectID: project.id,
                    filename: updated.filename
                ).path
            )
        )
    }

    func test_updateNarration_staleRevisionKeepsOldWAVAndRemovesReplacement() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let profile = VoiceProfile(
            name: "My voice",
            referenceFilename: "reference.wav",
            referenceText: "안녕하세요.",
            consentConfirmed: true
        )
        try repository.saveVoiceProfiles([profile])
        let reference = try repository.prepareVoiceReferenceURL(
            profileID: profile.id,
            fileExtension: "wav"
        )
        try TestVideoFactory.makeToneWAV(at: reference.url, duration: 3)
        var project = validVideoProject()
        let original = try repository.prepareNarrationURL(
            projectID: project.id
        )
        try TestVideoFactory.makeToneWAV(at: original.url, duration: 0.5)
        let clip = NarrationClip(
            voiceProfileID: profile.id,
            filename: original.filename,
            text: "원본",
            startTime: 1,
            duration: 0.5
        )
        project.narrations = [clip]
        try repository.saveProjects([project])
        let store = AppStore(
            repository: repository,
            voiceService: FakeVoiceSynthesisService()
        )

        do {
            _ = try await store.updateNarration(
                projectID: project.id,
                narrationID: clip.id,
                expectedRevision: 99,
                text: "저장되지 않을 수정"
            )
            XCTFail("Expected revision conflict")
        } catch RecordingStoreError.revisionConflict {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: original.url.path))
        XCTAssertEqual(
            store.project(id: project.id)?.narrations.first,
            clip
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: repository.assetsDirectory(projectID: project.id),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(
            files.filter {
                $0.lastPathComponent.hasPrefix("narration-")
            }.map(\.lastPathComponent),
            [original.filename]
        )
    }

    func test_deleteNarration_preservesWAVForUndo() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        var project = validVideoProject()
        let prepared = try repository.prepareNarrationURL(
            projectID: project.id
        )
        try TestVideoFactory.makeToneWAV(at: prepared.url, duration: 0.5)
        let narration = NarrationClip(
            voiceProfileID: UUID(),
            filename: prepared.filename,
            text: "삭제할 음성",
            startTime: 1,
            duration: 0.5
        )
        project.narrations = [narration]
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)

        let saved = try store.deleteNarration(
            projectID: project.id,
            narrationID: narration.id,
            expectedRevision: 0
        )

        XCTAssertTrue(saved.narrations.isEmpty)
        let restored = try store.undo(projectID: project.id)
        XCTAssertEqual(restored.narrations, [narration])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: prepared.url.path)
        )
    }
    func test_beginExport_rejectsSecondLeaseUntilMatchingRelease() throws {
        let store = AppStore(
            repository: ProjectRepository(rootURL: temporaryDirectory())
        )
        let first = try store.beginExport()

        XCTAssertThrowsError(try store.beginExport()) { error in
            XCTAssertEqual(
                error as? RecordingStoreError,
                .exportAlreadyActive
            )
        }
        XCTAssertTrue(store.isExportActive)

        store.endExport(UUID())
        XCTAssertTrue(store.isExportActive)
        store.endExport(first)
        XCTAssertFalse(store.isExportActive)
        XCTAssertNoThrow(try store.beginExport())
    }

    func test_externalExport_appWideLeaseRejectsMCPRequest() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let lease = try store.beginExport()
        defer { store.endExport(lease) }
        let arguments = try JSONSerialization.data(
            withJSONObject: [
                "project_id": project.id.uuidString,
                "parent_directory": root.path,
            ]
        )

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_start_export",
                argumentsJSON: arguments
            )
        )

        XCTAssertTrue(response.isError)
        XCTAssertTrue(response.text.contains("already active"))
        XCTAssertTrue(store.isExportActive)
    }

    func test_importVideo_copiesNarratedMOVAndPublishesEditableProject() async throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let source = sourceRoot.appendingPathComponent("Product tour.mov")
        _ = try await TestVideoFactory.makeMovie(
            at: source,
            fileType: .mov,
            includeAudio: true
        )
        let originalBytes = try Data(contentsOf: source)
        let repository = ProjectRepository(rootURL: root)
        let store = AppStore(repository: repository)

        let projectID = try await store.importVideo(from: source)
        let project = try XCTUnwrap(store.project(id: projectID))
        let recording = try XCTUnwrap(project.recording)
        let importedURL = repository.assetURL(
            projectID: projectID,
            filename: recording.filename
        )
        let importedAudioTracks = try await AVURLAsset(
            url: importedURL
        ).loadTracks(withMediaType: .audio)

        XCTAssertEqual(project.name, "Product tour")
        XCTAssertEqual(project.clips.count, 1)
        XCTAssertTrue(project.clicks.isEmpty)
        XCTAssertTrue(project.subtitles.isEmpty)
        XCTAssertTrue(project.effects.isEmpty)
        XCTAssertEqual((recording.filename as NSString).pathExtension, "mov")
        XCTAssertEqual(try Data(contentsOf: importedURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertEqual(importedAudioTracks.count, 1)

        try FileManager.default.removeItem(at: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedURL.path))
        XCTAssertEqual(try repository.loadProjects().first?.id, projectID)
    }

    func test_importVideo_audioPastVideoUsesPlayableVideoDuration() async throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let source = sourceRoot.appendingPathComponent(
            "trailing-audio.mov"
        )
        _ = try await TestVideoFactory.makeMovie(
            at: source,
            fileType: .mov,
            includeAudio: true,
            audioStart: 1.5,
            audioDuration: 0.5
        )
        let repository = ProjectRepository(rootURL: root)
        let store = AppStore(repository: repository)

        let projectID = try await store.importVideo(from: source)
        let project = try XCTUnwrap(store.project(id: projectID))
        let recording = try XCTUnwrap(project.recording)
        let importedURL = repository.assetURL(
            projectID: projectID,
            filename: recording.filename
        )
        let output = root.appendingPathComponent("canonical.mp4")
        _ = try await LayeredVideoExporter().export(
            project: project,
            sourceURL: importedURL,
            destinationURL: output
        )
        let outputAsset = AVURLAsset(url: output)
        let videoTracks = try await outputAsset.loadTracks(
            withMediaType: .video
        )
        let audioTracks = try await outputAsset.loadTracks(
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
        let clipEnd = try XCTUnwrap(project.clips.first?.sourceEnd)

        XCTAssertEqual(recording.duration, 1, accuracy: 0.05)
        XCTAssertEqual(clipEnd, 1, accuracy: 0.05)
        XCTAssertEqual(
            CMTimeGetSeconds(audioRange.end),
            CMTimeGetSeconds(videoRange.end),
            accuracy: 1.0 / 30.0
        )
    }

    func test_importVideo_invalidMoviePreservesLibraryAndRemovesPartialAssets() async throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let existing = DemoProject(name: "Existing")
        let repository = ProjectRepository(rootURL: root)
        try repository.saveProjects([existing])
        try FileManager.default.createDirectory(
            at: sourceRoot,
            withIntermediateDirectories: true
        )
        let source = sourceRoot.appendingPathComponent("broken.mp4")
        let original = Data("not a movie".utf8)
        try original.write(to: source)
        let store = AppStore(repository: repository)

        do {
            _ = try await store.importVideo(from: source)
            XCTFail("Expected invalid movie rejection")
        } catch {
            XCTAssertEqual(store.projects.map(\.id), [existing.id])
            XCTAssertEqual(try repository.loadProjects().map(\.id), [existing.id])
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func test_importVideo_unsupportedExtensionCreatesNoProjectAssets() async throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        try FileManager.default.createDirectory(
            at: sourceRoot,
            withIntermediateDirectories: true
        )
        let source = sourceRoot.appendingPathComponent("video.avi")
        try Data("unsupported".utf8).write(to: source)
        let repository = ProjectRepository(rootURL: root)
        let store = AppStore(repository: repository)

        do {
            _ = try await store.importVideo(from: source)
            XCTFail("Expected unsupported format rejection")
        } catch LocalVideoImportError.unsupportedFormat {
            XCTAssertTrue(store.projects.isEmpty)
            let children = try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent(
                    "Assets",
                    isDirectory: true
                ),
                includingPropertiesForKeys: nil
            )
            XCTAssertTrue(children.isEmpty)
        }
    }

    func test_importVideo_audioOnlyMovieCreatesNoProject() async throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let source = sourceRoot.appendingPathComponent("audio-only.mp4")
        try await TestVideoFactory.makeAudioOnlyMovie(at: source)
        let repository = ProjectRepository(rootURL: root)
        let store = AppStore(repository: repository)

        do {
            _ = try await store.importVideo(from: source)
            XCTFail("Expected missing video rejection")
        } catch LocalVideoImportError.missingVideoTrack {
            XCTAssertTrue(store.projects.isEmpty)
        }
    }

    func test_importVideo_cancelledBeforeCopyRemovesProjectAssets() async throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let source = sourceRoot.appendingPathComponent("cancel.mp4")
        _ = try await TestVideoFactory.makeMovie(
            at: source,
            includeAudio: false
        )
        let repository = ProjectRepository(rootURL: root)
        let store = AppStore(repository: repository)
        let task = Task {
            try await store.importVideo(from: source)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertTrue(store.projects.isEmpty)
            let assets = root.appendingPathComponent(
                "Assets",
                isDirectory: true
            )
            let children = try? FileManager.default.contentsOfDirectory(
                at: assets,
                includingPropertiesForKeys: nil
            )
            XCTAssertTrue(children?.isEmpty != false)
        }
    }

    func test_importVideo_librarySaveFailureRemovesCopiedAsset() async throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let source = sourceRoot.appendingPathComponent("save-failure.mp4")
        _ = try await TestVideoFactory.makeMovie(
            at: source,
            includeAudio: true
        )
        let repository = ProjectRepository(rootURL: root)
        let store = AppStore(repository: repository)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(
                "library.json",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )

        do {
            _ = try await store.importVideo(from: source)
            XCTFail("Expected library save failure")
        } catch {
            XCTAssertTrue(store.projects.isEmpty)
        }
        let assets = root.appendingPathComponent("Assets", isDirectory: true)
        let children = try? FileManager.default.contentsOfDirectory(
            at: assets,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(children?.isEmpty != false)
    }

    func test_replaceProject_identicalValueLeavesLibraryUnchanged() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = DemoProject(name: "Existing project")
        try repository.saveProjects([project])
        let libraryURL = root.appendingPathComponent("library.json")
        let before = try Data(contentsOf: libraryURL)
        let store = AppStore(repository: repository)
        let loadedProject = try XCTUnwrap(store.project(id: project.id))

        store.replaceProject(loadedProject)

        XCTAssertEqual(
            store.project(id: project.id)?.updatedAt,
            loadedProject.updatedAt
        )
        XCTAssertEqual(try Data(contentsOf: libraryURL), before)
    }

    func test_replaceProject_invalidVideoLayer_preservesStoredProject() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        var invalid = project
        invalid.clicks = [
            TimedPointerClick(time: 10, x: 0.5, y: 0.5),
        ]

        store.replaceProject(invalid)

        XCTAssertNotNil(store.errorMessage)
        let stored = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(stored.id, project.id)
        XCTAssertEqual(stored.recording, project.recording)
        XCTAssertEqual(stored.clicks, project.clicks)
        XCTAssertEqual(try repository.loadProjects().first?.clicks, project.clicks)
    }

    func test_externalControl_updateProject_usesAppStoreWriter() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = DemoProject(name: "Before")
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let arguments = try JSONSerialization.data(
            withJSONObject: [
                "project_id": project.id.uuidString,
                "expected_revision": 0,
                "name": "After",
            ]
        )

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_update_project",
                argumentsJSON: arguments
            )
        )

        XCTAssertFalse(response.isError)
        XCTAssertEqual(store.project(id: project.id)?.name, "After")
        XCTAssertEqual(
            try repository.loadProjects().first?.name,
            "After"
        )
    }

    func test_saveProject_staleRevisionPreservesLatestProject() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = DemoProject(name: "Before")
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        var first = project
        first.name = "First"
        let saved = try store.saveProject(first, expectedRevision: 0)
        var stale = project
        stale.name = "Stale"

        XCTAssertThrowsError(
            try store.saveProject(stale, expectedRevision: 0)
        )
        XCTAssertEqual(store.project(id: project.id)?.name, "First")
        XCTAssertEqual(store.project(id: project.id)?.revision, saved.revision)
    }

    func test_externalControl_replaceProject_enforcesExpectedRevision() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        var replacement = project
        replacement.summary = "Edited through MCP"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(
            decoding: try encoder.encode(replacement),
            as: UTF8.self
        )
        let arguments = try JSONSerialization.data(
            withJSONObject: [
                "project_id": project.id.uuidString,
                "expected_revision": 0,
                "project_json": json,
            ]
        )

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_replace_project",
                argumentsJSON: arguments
            )
        )
        let stale = await host.handle(
            StorybirdControlRequest(
                name: "storybird_replace_project",
                argumentsJSON: arguments
            )
        )

        XCTAssertFalse(response.isError)
        XCTAssertTrue(stale.isError)
        XCTAssertEqual(
            store.project(id: project.id)?.summary,
            "Edited through MCP"
        )
        XCTAssertEqual(store.project(id: project.id)?.revision, 1)
    }

    func test_undoRedo_restoresWholeProjectWithMonotonicRevision() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = DemoProject(name: "Before")
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        var edited = project
        edited.name = "After"
        let saved = try store.saveProject(edited, expectedRevision: 0)

        let undone = try store.undo(projectID: project.id)
        let redone = try store.redo(projectID: project.id)

        XCTAssertEqual(undone.name, "Before")
        XCTAssertEqual(redone.name, "After")
        XCTAssertGreaterThan(undone.revision, saved.revision)
        XCTAssertGreaterThan(redone.revision, undone.revision)
    }

    func test_undo_staleExpectedRevision_preservesUndoHistory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = DemoProject(name: "Before")
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        var edited = project
        edited.name = "After"
        let saved = try store.saveProject(edited, expectedRevision: 0)

        XCTAssertThrowsError(
            try store.undo(
                projectID: project.id,
                expectedRevision: 0
            )
        )
        let undone = try store.undo(
            projectID: project.id,
            expectedRevision: saved.revision
        )

        XCTAssertEqual(undone.name, "Before")
    }

    func test_saveProject_terminalSuggestionCannotReturnToPending() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        var project = validVideoProject()
        project.suggestions = ClickSuggestionGenerator.generate(for: project)
        project.suggestions[0].state = .rejected
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        var invalid = project
        invalid.suggestions[0].state = .pending

        XCTAssertThrowsError(
            try store.saveProject(invalid, expectedRevision: 0)
        )
        XCTAssertEqual(
            store.project(id: project.id)?.suggestions[0].state,
            .rejected
        )
    }

    func test_appliedSuggestionCleanup_allowsClipDeletionAndUndoRestore() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        var project = validVideoProject()
        project.suggestions = ClickSuggestionGenerator.generate(for: project)
        project = try ClickSuggestionGenerator.apply(
            try XCTUnwrap(project.suggestions.first?.id),
            to: project
        )
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let ownerID = try XCTUnwrap(
            project.clicks.first?.sourceAnchor?.clipID
        )

        let edited = try VideoTimelineEditor.delete(
            project: project,
            clipID: ownerID
        )
        let saved = try store.saveProject(
            edited,
            expectedRevision: project.revision
        )

        XCTAssertTrue(saved.clicks.isEmpty)
        XCTAssertTrue(saved.effects.isEmpty)
        XCTAssertTrue(saved.suggestions.isEmpty)

        let restored = try store.undo(projectID: project.id)
        XCTAssertFalse(restored.clicks.isEmpty)
        XCTAssertFalse(restored.effects.isEmpty)
        XCTAssertEqual(restored.suggestions.first?.state, .applied)
    }

    func test_appliedSuggestionCleanup_deletingCueKeepsAppliedEffects() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        var project = validVideoProject()
        project.suggestions = ClickSuggestionGenerator.generate(for: project)
        project = try ClickSuggestionGenerator.apply(
            try XCTUnwrap(project.suggestions.first?.id),
            to: project
        )
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        var edited = project
        edited.clicks = []
        edited = VideoTimelineEditor.remapContentLayers(edited)

        let saved = try store.saveProject(
            edited,
            expectedRevision: project.revision
        )

        XCTAssertTrue(saved.clicks.isEmpty)
        XCTAssertTrue(saved.suggestions.isEmpty)
        XCTAssertFalse(saved.effects.isEmpty)
    }

    func test_externalControl_invalidExportDoesNotCreateJob() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let arguments = try JSONSerialization.data(
            withJSONObject: [
                "project_id": project.id.uuidString,
                "parent_directory": root.path,
            ]
        )

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_start_export",
                argumentsJSON: arguments
            )
        )

        XCTAssertTrue(response.isError)
        XCTAssertTrue(response.text.contains("Click Cues"))
        XCTAssertFalse(store.isExportActive)
    }

    func test_referenceProject_95PercentOfPlayheadAndPropertyChangesReachPreviewWithin500Milliseconds() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let recording = VideoRecordingAsset(
            filename: "recording.mp4",
            duration: 120,
            width: 1_920,
            height: 1_080
        )
        let subtitles = (0..<100).map { index in
            TimedSubtitle(
                startTime: Double(index),
                endTime: Double(index) + 0.5,
                text: "Layer \(index)"
            )
        }
        let project = DemoProject(
            name: "Reference",
            recording: recording,
            subtitles: subtitles
        )
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        var withinTarget = 0

        for index in 0..<100 {
            var edited = try XCTUnwrap(store.project(id: project.id))
            edited.subtitles[index].text = "Edited layer \(index)"
            let started = ContinuousClock.now
            let saved = try store.saveProject(
                edited,
                expectedRevision: edited.revision
            )
            let visible = VideoOverlayPresentation.visibleLayerIDs(
                in: saved,
                at: Double(index) + 0.25
            )
            if visible.contains(saved.subtitles[index].id),
               started.duration(to: .now) <= .milliseconds(500) {
                withinTarget += 1
            }
        }

        XCTAssertGreaterThanOrEqual(withinTarget, 95)
    }

    func test_invalidProjectMutations_twentyOfTwentyPreserveStoredProject() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let baseline = try XCTUnwrap(store.project(id: project.id))

        for index in 0..<20 {
            var invalid = baseline
            invalid.clicks[0].x = 2 + Double(index)
            XCTAssertThrowsError(
                try store.saveProject(invalid, expectedRevision: 0)
            )
            XCTAssertEqual(store.project(id: project.id), baseline)
            XCTAssertEqual(try repository.loadProjects().first, baseline)
        }
    }

    func test_externalControl_invalidClickEdit_returnsErrorAndPreservesProject() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let arguments = try JSONSerialization.data(
            withJSONObject: [
                "project_id": project.id.uuidString,
                "expected_revision": 0,
                "click_id": project.clicks[0].id.uuidString,
                "x": 2,
            ]
        )

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_update_click",
                argumentsJSON: arguments
            )
        )

        XCTAssertTrue(response.isError)
        XCTAssertEqual(store.project(id: project.id)?.clicks, project.clicks)
        XCTAssertEqual(
            try repository.loadProjects().first?.clicks,
            project.clicks
        )
    }

    func test_externalControl_updateClick_returnsNewRevisionAndTargetID() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let arguments = try JSONSerialization.data(
            withJSONObject: [
                "project_id": project.id.uuidString,
                "expected_revision": 0,
                "click_id": project.clicks[0].id.uuidString,
                "caption": "Updated caption",
            ]
        )

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_update_click",
                argumentsJSON: arguments
            )
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(response.text.utf8)
            ) as? [String: Any]
        )
        let value = try XCTUnwrap(payload["value"] as? [String: Any])
        let description = try XCTUnwrap(
            value["description"] as? [String: Any]
        )

        XCTAssertFalse(response.isError)
        XCTAssertEqual(payload["revision"] as? Int, 1)
        XCTAssertEqual(
            payload["target_id"] as? String,
            project.clicks[0].id.uuidString
        )
        XCTAssertEqual(description["text"] as? String, "Updated caption")
    }

    func test_externalControl_upsertSubtitle_usesProjectTimelineAndReturnsRevision() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        var project = validVideoProject()
        project.clips[0].playbackRate = 0.5
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let arguments = try JSONSerialization.data(
            withJSONObject: [
                "project_id": project.id.uuidString,
                "expected_revision": 0,
                "start_time": 6.0,
                "end_time": 7.0,
                "text": "Edited timeline subtitle",
                "position": "top",
            ]
        )

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_upsert_subtitle",
                argumentsJSON: arguments
            )
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(response.text.utf8)
            ) as? [String: Any]
        )
        let stored = try XCTUnwrap(store.project(id: project.id))

        XCTAssertFalse(response.isError)
        XCTAssertEqual(payload["revision"] as? Int, 1)
        XCTAssertEqual(stored.subtitles.count, 1)
        XCTAssertEqual(stored.subtitles[0].startTime, 6)
        XCTAssertEqual(stored.subtitles[0].endTime, 7)
        XCTAssertEqual(
            payload["target_id"] as? String,
            stored.subtitles[0].id.uuidString
        )
    }

    func test_commitRecordedVideo_preservesAcceptedClickOrder() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let store = AppStore(repository: repository)
        let projectID = UUID()
        let target = try repository.prepareVideoRecordingURL(
            projectID: projectID
        )
        try Data("video".utf8).write(to: target.url)

        let first = TimedPointerClick(time: 1, x: 0.2, y: 0.3)
        let second = TimedPointerClick(time: 1, x: 0.8, y: 0.7)
        let third = TimedPointerClick(time: 2, x: 0.4, y: 0.6)
        try store.commitRecordedVideo(
            projectID: projectID,
            name: "Recorded",
            filename: target.filename,
            result: ScreenVideoRecordingResult(
                duration: 3,
                width: 640,
                height: 480
            ),
            clicks: [first, second, third]
        )

        let project = try XCTUnwrap(store.project(id: projectID))
        XCTAssertEqual(project.recording?.filename, target.filename)
        XCTAssertEqual(project.clicks.map(\.id), [
            first.id,
            second.id,
            third.id,
        ])
        XCTAssertEqual(store.selectedProjectID, projectID)
        XCTAssertEqual(try repository.loadProjects().first?.id, projectID)
    }

    func test_commitRecordedVideo_invalidTimeline_removesUnpublishedAssets() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let existing = DemoProject(name: "Existing")
        try repository.saveProjects([existing])
        let store = AppStore(repository: repository)
        let projectID = UUID()
        let target = try repository.prepareVideoRecordingURL(
            projectID: projectID
        )
        try Data("video".utf8).write(to: target.url)

        XCTAssertThrowsError(
            try store.commitRecordedVideo(
                projectID: projectID,
                name: "Invalid",
                filename: target.filename,
                result: ScreenVideoRecordingResult(
                    duration: 1,
                    width: 640,
                    height: 480
                ),
                clicks: [
                    TimedPointerClick(time: 2, x: 0.5, y: 0.5),
                ]
            )
        )

        XCTAssertEqual(store.projects.map(\.id), [existing.id])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repository.assetsDirectory(
                    projectID: projectID
                ).path
            )
        )
    }

    func test_commitRecordedVideo_librarySaveFailure_removesVideoAndKeepsLibraryEmpty() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let store = AppStore(repository: repository)
        let libraryURL = root.appendingPathComponent(
            "library.json",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: libraryURL,
            withIntermediateDirectories: true
        )
        let projectID = UUID()
        let target = try repository.prepareVideoRecordingURL(
            projectID: projectID
        )
        try Data("video".utf8).write(to: target.url)

        XCTAssertThrowsError(
            try store.commitRecordedVideo(
                projectID: projectID,
                name: "Save failure",
                filename: target.filename,
                result: ScreenVideoRecordingResult(
                    duration: 1,
                    width: 640,
                    height: 480
                ),
                clicks: []
            )
        )

        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repository.assetsDirectory(
                    projectID: projectID
                ).path
            )
        )
    }

    func test_externalControlApproval_requiresNativeResolution() async {
        let store = AppStore(
            repository: ProjectRepository(rootURL: temporaryDirectory())
        )
        let decision = Task { @MainActor in
            await store.requestExternalControlApproval(
                title: "Allow?",
                message: "Synthetic approval"
            )
        }
        await Task.yield()

        XCTAssertNotNil(store.externalControlPrompt)
        store.resolveExternalControlApproval(true)
        let allowed = await decision.value

        XCTAssertTrue(allowed)
        XCTAssertNil(store.externalControlPrompt)
    }

    func test_externalAbort_cancelsPendingNativeApproval() async {
        let store = AppStore(
            repository: ProjectRepository(rootURL: temporaryDirectory())
        )
        let host = StorybirdExternalControlHost(store: store)
        let decision = Task { @MainActor in
            await store.requestExternalControlApproval(
                title: "Allow?",
                message: "Synthetic approval"
            )
        }
        await Task.yield()

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_abort_session",
                argumentsJSON: Data("{}".utf8)
            )
        )
        let allowed = await decision.value

        XCTAssertFalse(response.isError)
        XCTAssertFalse(allowed)
        XCTAssertNil(store.externalControlPrompt)
    }

    private func validVideoProject() -> DemoProject {
        DemoProject(
            name: "Video",
            recording: VideoRecordingAsset(
                filename: "recording.mp4",
                duration: 5,
                width: 640,
                height: 480
            ),
            clicks: [
                TimedPointerClick(time: 1, x: 0.5, y: 0.5),
            ]
        )
    }

    private func voiceFixture(
        root: URL
    ) throws -> (ProjectRepository, VoiceProfile, DemoProject) {
        let repository = ProjectRepository(rootURL: root)
        let profile = VoiceProfile(
            name: "My voice",
            referenceFilename: "reference.wav",
            referenceText: "안녕하세요.",
            consentConfirmed: true
        )
        try repository.saveVoiceProfiles([profile])
        let reference = try repository.prepareVoiceReferenceURL(
            profileID: profile.id,
            fileExtension: "wav"
        )
        try TestVideoFactory.makeToneWAV(at: reference.url, duration: 3)
        let project = validVideoProject()
        try repository.saveProjects([project])
        return (repository, profile, project)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private actor FakeVoiceSynthesisService: VoiceSynthesisProviding {
    func prepared() async -> Bool { true }
    func prepare() async throws {}

    func generate(
        text: String,
        referenceAudioURL: URL,
        referenceText: String,
        language: String,
        outputURL: URL
    ) async throws -> VoiceSynthesisResult {
        try TestVideoFactory.makeToneWAV(
            at: outputURL,
            duration: 0.5
        )
        return VoiceSynthesisResult(duration: 0.5, sampleRate: 44_100)
    }
}

private actor MissingWAVVoiceSynthesisService: VoiceSynthesisProviding {
    func prepared() async -> Bool { true }
    func prepare() async throws {}

    func generate(
        text: String,
        referenceAudioURL: URL,
        referenceText: String,
        language: String,
        outputURL: URL
    ) async throws -> VoiceSynthesisResult {
        VoiceSynthesisResult(duration: 0.5, sampleRate: 44_100)
    }
}

private actor WrongDurationVoiceSynthesisService: VoiceSynthesisProviding {
    func prepared() async -> Bool { true }
    func prepare() async throws {}

    func generate(
        text: String,
        referenceAudioURL: URL,
        referenceText: String,
        language: String,
        outputURL: URL
    ) async throws -> VoiceSynthesisResult {
        try TestVideoFactory.makeToneWAV(at: outputURL, duration: 0.5)
        return VoiceSynthesisResult(duration: 2, sampleRate: 44_100)
    }
}

private actor SlowVoiceSynthesisService: VoiceSynthesisProviding {
    func prepared() async -> Bool { true }
    func prepare() async throws {}

    func generate(
        text: String,
        referenceAudioURL: URL,
        referenceText: String,
        language: String,
        outputURL: URL
    ) async throws -> VoiceSynthesisResult {
        try TestVideoFactory.makeToneWAV(at: outputURL, duration: 0.5)
        try await Task.sleep(for: .seconds(10))
        return VoiceSynthesisResult(duration: 0.5, sampleRate: 44_100)
    }
}
