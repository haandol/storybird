import Foundation
import XCTest

final class BundleMetadataTests: XCTestCase {
    func test_infoPlist_usesStorybirdIdentity() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repositoryRoot.appendingPathComponent(
            "Resources/Info.plist"
        )
        let data = try Data(contentsOf: plistURL)
        let value = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )

        XCTAssertEqual(value["CFBundleName"] as? String, "Storybird")
        XCTAssertEqual(
            value["CFBundleIdentifier"] as? String,
            "com.storybird.app"
        )
        XCTAssertEqual(value["CFBundleExecutable"] as? String, "Storybird")
        XCTAssertNil(value["CFBundleDocumentTypes"])
        XCTAssertNil(value["UTExportedTypeDeclarations"])
        XCTAssertTrue(
            (value["NSScreenCaptureUsageDescription"] as? String)?
                .contains("video") == true
        )
        XCTAssertTrue(
            (value["NSInputMonitoringUsageDescription"] as? String)?
                .contains("Keyboard input is never recorded") == true
        )
        XCTAssertTrue(
            (value["NSMicrophoneUsageDescription"] as? String)?
                .contains("voice profile") == true
        )
    }

    func test_entitlements_allowExplicitVoiceProfileRecording() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entitlementsURL = repositoryRoot.appendingPathComponent(
            "Resources/Storybird.entitlements"
        )
        let data = try Data(contentsOf: entitlementsURL)
        let value = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )

        XCTAssertEqual(
            value["com.apple.security.device.audio-input"] as? Bool,
            true
        )
    }
}
