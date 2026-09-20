import Foundation
@testable import StorybirdCore
import XCTest

final class CustomVoiceMetadataTests: XCTestCase {
    private let options = CustomVoiceOptions(speaker: .sohee, instruct: "차분하게 읽어 주세요.")

    func test_speakerCatalog_preservesWireIDsAndDisplayNames() throws {
        XCTAssertEqual(CustomVoiceSpeaker.allCases.map(\.rawValue), [
            "vivian", "serena", "uncle_fu", "dylan", "eric", "ryan", "aiden", "ono_anna", "sohee",
        ])
        XCTAssertEqual(CustomVoiceSpeaker.allCases.map(\.displayName), [
            "Vivian", "Serena", "Uncle_Fu", "Dylan", "Eric", "Ryan", "Aiden", "Ono_Anna", "Sohee",
        ])
        for speaker in CustomVoiceSpeaker.allCases {
            let value = CustomVoiceOptions(speaker: speaker)
            XCTAssertEqual(value.instruct, "")
            XCTAssertEqual(try roundTrip(value), value)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(
            CustomVoiceOptions.self, from: Data(#"{"speaker":"unknown","instruct":""}"#.utf8)
        ))
    }

    func test_modelCatalog_keepsLegacyDecodableAndManageableOnly() throws {
        XCTAssertEqual(VoiceModel.allCases, [.base1_7B, .customVoice1_7B])
        XCTAssertEqual(VoiceModel.manageableModels, [.base1_7B, .customVoice1_7B, .base0_6B])
        XCTAssertTrue(VoiceModel.allCases.allSatisfy(\.isSupported))
        XCTAssertFalse(VoiceModel.base0_6B.isSupported)
        XCTAssertEqual(try roundTrip(VoiceModel.base0_6B), .base0_6B)
        XCTAssertEqual(VoiceModel.customVoice1_7B.rawValue, "qwen3-tts-1.7b-customvoice-8bit")
        XCTAssertEqual(
            VoiceModel.customVoice1_7B.repositoryID,
            "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
        )
        XCTAssertEqual(VoiceModel.customVoice1_7B.runtimeDirectoryName, "VoiceRuntime-CustomVoice-1.7B-8bit")
        XCTAssertEqual(Set(VoiceModel.manageableModels.map(\.runtimeDirectoryName)).count, 3)
    }

    func test_projectRoundTrip_preservesDraftAssetAndLayerGenerationMetadata() throws {
        let asset = makeAsset()
        var project = makeProject()
        project.audioAssets = [asset]
        project.narrationDrafts = [makeDraft()]
        project = try AudioLayerEditor.place(assetID: asset.id, in: project, startTime: 1)

        let decoded = try roundTrip(project)

        XCTAssertEqual(decoded, project)
        XCTAssertEqual(decoded.narrationDrafts.first?.customVoice, options)
        XCTAssertEqual(decoded.audioAssets.first?.customVoice, options)
        XCTAssertEqual(decoded.narrations.first?.customVoice, options)
        XCTAssertNil(decoded.narrations.first?.voiceProfileID)
        XCTAssertNoThrow(try VideoProjectValidator.validate(decoded))
    }

    func test_legacyCloneJSON_decodesWithoutCustomVoiceAndPreservesProfile() throws {
        let profileID = UUID()
        let id = UUID()
        let draftJSON = """
        {"id":"\(id)","voiceProfileID":"\(profileID)","text":"Legacy speech","language":"english",
         "filename":"legacy.wav","state":"ready","duration":2}
        """
        let clipJSON = """
        {"id":"\(id)","voiceProfileID":"\(profileID)","text":"Legacy speech",
         "filename":"legacy.wav","startTime":0,"duration":2}
        """
        let assetJSON = """
        {"id":"\(id)","voiceProfileID":"\(profileID)","text":"Legacy speech","language":"english",
         "filename":"legacy.wav","name":"Legacy","origin":"generated","duration":2}
        """
        let decoder = JSONDecoder()
        let draft = try decoder.decode(NarrationDraft.self, from: Data(draftJSON.utf8))
        let clip = try decoder.decode(NarrationClip.self, from: Data(clipJSON.utf8))
        let asset = try decoder.decode(ProjectAudioAsset.self, from: Data(assetJSON.utf8))

        XCTAssertEqual(draft.voiceProfileID, profileID)
        XCTAssertEqual(clip.voiceProfileID, profileID)
        XCTAssertEqual(asset.voiceProfileID, profileID)
        XCTAssertNil(draft.customVoice)
        XCTAssertNil(clip.customVoice)
        XCTAssertNil(asset.customVoice)
        XCTAssertEqual(clip.language, "korean")
        XCTAssertEqual(clip.assetID, clip.id)
        XCTAssertEqual(try roundTrip(draft), draft)
        XCTAssertEqual(try roundTrip(clip), clip)
        XCTAssertEqual(try roundTrip(asset), asset)
        XCTAssertNoThrow(try NarrationDraft.validate([draft]))
        var project = makeProject()
        project.narrations = [clip]
        project.audioAssets = [asset]
        XCTAssertNoThrow(try VideoProjectValidator.validate(project))
    }

    func test_importedAudioWithoutVoiceMetadata_remainsValidAndReusable() throws {
        let id = UUID()
        let json = """
        {"id":"\(id)","text":"","language":"korean","filename":"imported.wav",
         "name":"Imported","origin":"imported","duration":2}
        """
        let asset = try JSONDecoder().decode(ProjectAudioAsset.self, from: Data(json.utf8))
        var project = makeProject()
        project.audioAssets = [asset]
        project = try AudioLayerEditor.place(assetID: asset.id, in: project, startTime: 0)
        let decoded = try roundTrip(project)

        XCTAssertNil(decoded.audioAssets[0].voiceProfileID)
        XCTAssertNil(decoded.audioAssets[0].customVoice)
        XCTAssertNil(decoded.narrations[0].voiceProfileID)
        XCTAssertNil(decoded.narrations[0].customVoice)
        XCTAssertEqual(decoded.narrations[0].text, "")
        XCTAssertNoThrow(try VideoProjectValidator.validate(decoded))
    }

    func test_draftValidation_requiresExactlyOneGenerationSourceInEveryState() throws {
        for state in [
            NarrationDraftState.generating, .ready, .failed, .cancelled, .placed,
        ] {
            var draft = makeDraft()
            draft.state = state
            XCTAssertNoThrow(try NarrationDraft.validate([draft]))
            draft.voiceProfileID = UUID()
            XCTAssertThrowsError(try NarrationDraft.validate([draft]))
            draft.customVoice = nil
            XCTAssertNoThrow(try NarrationDraft.validate([draft]))
            draft.voiceProfileID = nil
            XCTAssertThrowsError(try NarrationDraft.validate([draft]))
        }
        let missingSource = NarrationDraft(text: "Speech", language: "english", filename: "draft.wav")
        XCTAssertNil(missingSource.voiceProfileID)
        XCTAssertNil(missingSource.customVoice)
        XCTAssertThrowsError(try NarrationDraft.validate([missingSource]))
    }

    func test_customVoiceValidation_rejectsBlankTextAcrossDraftAssetAndLayer() throws {
        for blank in ["", " \n\t "] {
            var draft = makeDraft()
            draft.text = blank
            XCTAssertThrowsError(try NarrationDraft.validate([draft]))
            var project = makeProject()
            var asset = makeAsset()
            asset.text = blank
            project.audioAssets = [asset]
            XCTAssertThrowsError(try VideoProjectValidator.validate(project))
            project.audioAssets = []
            project.narrations = [NarrationClip(
                filename: "speech.wav", text: blank,
                startTime: 0, duration: 2, name: "Speech", customVoice: options
            )]
            XCTAssertThrowsError(try VideoProjectValidator.validate(project))
        }
    }

    func test_customVoiceValidation_rejectsProfileMixingInAssetsAndLayers() throws {
        var project = makeProject()
        var asset = makeAsset()
        asset.voiceProfileID = UUID()
        project.audioAssets = [asset]
        XCTAssertThrowsError(try VideoProjectValidator.validate(project))

        // Keep the registered asset valid to exercise the layer's own guard.
        asset.voiceProfileID = nil
        project.audioAssets = [asset]
        project = try AudioLayerEditor.place(assetID: asset.id, in: project, startTime: 0)
        project.narrations[0].voiceProfileID = UUID()
        XCTAssertThrowsError(try VideoProjectValidator.validate(project))
    }

    func test_assetReuseDuplicateAndSplit_preserveVoiceMetadataAndSourceIdentity() throws {
        let asset = makeAsset()
        var project = makeProject()
        project.audioAssets = [asset]
        project = try AudioLayerEditor.place(assetID: asset.id, in: project, startTime: 1)
        let layerID = project.narrations[0].id
        project = try AudioLayerEditor.duplicate(layerID: layerID, in: project, startTime: 5)
        project = try AudioLayerEditor.split(layerID: layerID, in: project, at: 2)
        project = try AudioLayerEditor.place(
            assetID: asset.id, in: project, startTime: 8, sourceStart: 1, duration: 1
        )
        let decoded = try roundTrip(project)

        XCTAssertEqual(decoded.narrations.count, 4)
        XCTAssertEqual(Set(decoded.narrations.map(\.id)).count, 4)
        XCTAssertEqual(decoded.audioAssets, [asset])
        XCTAssertEqual(decoded.availableAudioAssets, [asset])
        XCTAssertEqual(decoded.narrations.map(\.sourceStart), [0, 1, 0, 1])
        XCTAssertEqual(decoded.narrations.map(\.duration), [1, 1, 2, 1])
        for layer in decoded.narrations {
            XCTAssertEqual(layer.customVoice, options)
            XCTAssertNil(layer.voiceProfileID)
            XCTAssertEqual(layer.assetID, asset.id)
            XCTAssertEqual(layer.filename, asset.filename)
            XCTAssertEqual(layer.text, asset.text)
            XCTAssertEqual(layer.language, asset.language)
        }
        XCTAssertNoThrow(try VideoProjectValidator.validate(decoded))
    }

    func test_assetDerivation_recognizesCustomSpeechAndPreservesGenerationOptions() throws {
        var project = makeProject()
        project.narrations = [NarrationClip(
            filename: "speech.wav", text: "안녕하세요", language: "korean",
            startTime: 0, duration: 2, customVoice: options
        )]
        let original = project.narrations[0]
        project = try AudioLayerEditor.duplicate(layerID: original.id, in: project, startTime: 3)
        let asset = try XCTUnwrap(project.availableAudioAssets.first)

        XCTAssertEqual(project.availableAudioAssets.count, 1)
        XCTAssertEqual(asset.origin, .generated)
        XCTAssertEqual(asset.customVoice, options)
        XCTAssertNil(asset.voiceProfileID)
        XCTAssertEqual(asset.id, original.assetID)
        XCTAssertEqual(asset.text, original.text)
        XCTAssertEqual(asset.language, original.language)
        project = try AudioLayerEditor.place(assetID: asset.id, in: project, startTime: 6)
        XCTAssertEqual(project.narrations.last?.customVoice, options)
        XCTAssertEqual(try roundTrip(project).availableAudioAssets, [asset])
    }

    private func makeDraft() -> NarrationDraft {
        NarrationDraft(
            text: "안녕하세요", language: "korean",
            filename: "draft.wav", state: .ready, duration: 2, customVoice: options
        )
    }

    private func makeAsset() -> ProjectAudioAsset {
        ProjectAudioAsset(
            filename: "speech.wav", name: "Speech", duration: 2,
            origin: .generated, text: "안녕하세요", language: "korean", customVoice: options
        )
    }

    private func makeProject() -> DemoProject {
        DemoProject(
            name: "CustomVoice",
            recording: VideoRecordingAsset(filename: "source.mp4", duration: 12, width: 1280, height: 720)
        )
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
}
