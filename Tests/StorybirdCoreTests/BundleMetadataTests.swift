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
        let documentTypes = try XCTUnwrap(
            value["CFBundleDocumentTypes"] as? [[String: Any]]
        )
        let contentTypes = documentTypes
            .flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        XCTAssertTrue(contentTypes.contains("com.storybird.recording"))

        let exportedTypes = try XCTUnwrap(
            value["UTExportedTypeDeclarations"] as? [[String: Any]]
        )
        let recordingType = try XCTUnwrap(
            exportedTypes.first {
                $0["UTTypeIdentifier"] as? String == "com.storybird.recording"
            }
        )
        let tags = try XCTUnwrap(
            recordingType["UTTypeTagSpecification"] as? [String: Any]
        )
        XCTAssertEqual(
            tags["public.filename-extension"] as? [String],
            ["storybirdrecording"]
        )
    }
}
