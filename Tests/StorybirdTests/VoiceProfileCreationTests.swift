import Foundation
import StorybirdCore
import XCTest
@testable import Storybird

@MainActor
final class VoiceProfileCreationTests: XCTestCase {
    func test_importSelection_waitsForExplicitSaveThenClosesWithOneOwnedProfile() async throws {
        let (store, root) = try fixture()
        let source = root.appendingPathComponent("external/sample.wav")
        try TestVideoFactory.makeToneWAV(at: source, duration: 1)
        let model = VoiceProfileCreationModel(store: store, recorder: VoiceSampleRecorder())
        model.inputMethod = .importFile
        model.profileName = "  Demo narrator  "
        model.referenceLanguage = .english
        model.transcript = "This is my reference."
        model.consentConfirmed = true
        model.selectFile(source)

        XCTAssertTrue(store.voiceProfiles.isEmpty)
        XCTAssertFalse(model.isClosed)
        await model.save(recordedURL: nil)

        XCTAssertTrue(model.isClosed)
        XCTAssertNil(model.errorMessage)
        let profile = try XCTUnwrap(store.voiceProfiles.first)
        XCTAssertEqual(store.voiceProfiles.count, 1)
        XCTAssertEqual(profile.name, "Demo narrator")
        XCTAssertEqual(profile.language, "english")
        XCTAssertEqual(profile.referenceText, "This is my reference.")
        let owned = store.repository.voiceReferenceURL(
            profileID: profile.id, filename: profile.referenceFilename
        )
        XCTAssertEqual(try Data(contentsOf: owned), try Data(contentsOf: source))
        await model.save(recordedURL: nil)
        XCTAssertEqual(store.voiceProfiles.count, 1)
    }

    func test_microphoneSave_enforcesTenSecondsAndUsesSelectedPrompt() async throws {
        let (store, root) = try fixture()
        let short = root.appendingPathComponent("short.wav")
        let complete = root.appendingPathComponent("complete.wav")
        try TestVideoFactory.makeToneWAV(at: short, duration: 9.9)
        try TestVideoFactory.makeToneWAV(at: complete, duration: 10.1)
        let model = VoiceProfileCreationModel(store: store, recorder: VoiceSampleRecorder())
        model.profileName = "English narrator"
        model.referenceLanguage = .english
        model.transcript = "Unused imported transcript"
        model.consentConfirmed = true

        await model.save(recordedURL: short)
        XCTAssertFalse(model.isClosed)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(store.voiceProfiles.isEmpty)
        await model.save(recordedURL: complete)
        XCTAssertTrue(model.isClosed)
        XCTAssertEqual(store.voiceProfiles.first?.referenceText, VoiceLanguage.english.referencePrompt)
        XCTAssertEqual(store.voiceProfiles.first?.language, "english")
    }

    func test_saveFailure_keepsInputsAndSampleForSuccessfulRetry() async throws {
        let (store, root) = try fixture()
        let source = root.appendingPathComponent("missing.wav")
        let model = VoiceProfileCreationModel(store: store, recorder: VoiceSampleRecorder())
        model.inputMethod = .importFile
        model.profileName = "Retry narrator"
        model.referenceLanguage = .english
        model.transcript = "Keep this sentence."
        model.consentConfirmed = true
        model.selectFile(source)

        await model.save(recordedURL: nil)

        XCTAssertFalse(model.isClosed)
        XCTAssertFalse(model.isSaving)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.profileName, "Retry narrator")
        XCTAssertEqual(model.referenceLanguage, .english)
        XCTAssertEqual(model.transcript, "Keep this sentence.")
        XCTAssertEqual(model.selectedFileURL, source)
        XCTAssertTrue(model.consentConfirmed)
        XCTAssertTrue(store.voiceProfiles.isEmpty)

        try TestVideoFactory.makeToneWAV(at: source, duration: 1)
        await model.save(recordedURL: nil)
        XCTAssertTrue(model.isClosed)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(store.voiceProfiles.count, 1)
    }

    func test_suspendedSave_rejectsDuplicateAndCancelUntilPersistenceFinishes() async {
        let entered = expectation(description: "Persistence started")
        var resume: CheckedContinuation<Void, Never>?
        var writes = 0
        var cleanups = 0
        let model = VoiceProfileCreationModel(
            persist: { _ in
                writes += 1
                await withCheckedContinuation {
                    resume = $0
                    entered.fulfill()
                }
            },
            discardSample: { cleanups += 1 }
        )
        model.profileName = "One profile"
        model.consentConfirmed = true
        let sample = URL(fileURLWithPath: "/synthetic/recording.wav")
        let save = Task { await model.save(recordedURL: sample) }
        await fulfillment(of: [entered], timeout: 2)

        XCTAssertTrue(model.isSaving)
        model.cancel()
        await model.save(recordedURL: sample)
        XCTAssertFalse(model.isClosed)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(cleanups, 0)
        resume?.resume()
        await save.value
        XCTAssertTrue(model.isClosed)
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(cleanups, 1)
    }

    func test_cancel_discardsTemporarySampleOnceAndPreventsLaterSave() async throws {
        let (_, root) = try fixture()
        let sample = root.appendingPathComponent("temporary.wav")
        try Data("synthetic sample".utf8).write(to: sample)
        var writes = 0
        var cleanups = 0
        let model = VoiceProfileCreationModel(
            persist: { _ in writes += 1 },
            discardSample: {
                cleanups += 1
                try? FileManager.default.removeItem(at: sample)
            }
        )
        model.profileName = "Cancelled"
        model.consentConfirmed = true
        model.cancel()
        model.cancel()
        await model.save(recordedURL: sample)

        XCTAssertTrue(model.isClosed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sample.path))
        XCTAssertEqual(cleanups, 1)
        XCTAssertEqual(writes, 0)
    }

    func test_missingNameConsentOrTranscript_preventsProfileWrite() async {
        var writes = 0
        let model = VoiceProfileCreationModel(persist: { _ in writes += 1 }, discardSample: {})
        let sample = URL(fileURLWithPath: "/synthetic/reference.wav")
        model.inputMethod = .importFile
        model.selectFile(sample)
        XCTAssertNil(model.selectedFileURL)
        model.consentConfirmed = true
        model.selectFile(sample)
        model.profileName = "   "
        model.transcript = "Transcript"
        await model.save(recordedURL: nil)
        model.profileName = "Name"
        model.transcript = " \n "
        await model.save(recordedURL: nil)
        model.transcript = "Transcript"
        model.consentConfirmed = false
        await model.save(recordedURL: nil)
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(model.isClosed)
    }

    /// Uses an isolated library and generated tones so the creation flow never
    /// reads user profiles or requests microphone/network access.
    private func fixture() throws -> (AppStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storybird-profile-creation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (AppStore(repository: ProjectRepository(rootURL: root.appendingPathComponent("library"))), root)
    }
}
