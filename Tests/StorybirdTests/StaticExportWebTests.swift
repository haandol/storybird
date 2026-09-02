import AppKit
import StorybirdCore
import WebKit
import XCTest

@MainActor
final class StaticExportWebTests: XCTestCase, WKNavigationDelegate {
    private var navigationExpectation: XCTestExpectation?

    func test_staticExport_rendersBoundedOverlaysAndCompletesFinalHotspot() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )
        try writePNG(to: source.appendingPathComponent("first.png"))
        try writePNG(to: source.appendingPathComponent("second.png"))

        var second = DemoStep(
            title: "Second",
            caption: "Bottom subtitle",
            subtitlePosition: .bottom,
            subtitleStyle: TextOverlayStyle(
                backgroundHex: "#00FF00",
                backgroundOpacity: 1
            ),
            assetFilename: "second.png"
        )
        second.hotspots = [
            Hotspot(
                x: 0.96,
                y: 0.96,
                title: "Finish",
                caption: ""
            ),
        ]
        let injection = "<img id='injected'>"
        let longCaption = String(
            repeating: "A very long caption \(injection) ",
            count: 40
        )
        var first = DemoStep(
            title: "First",
            caption: "Top subtitle",
            subtitlePosition: .top,
            subtitleStyle: TextOverlayStyle(
                backgroundHex: "#123456",
                backgroundOpacity: 0
            ),
            assetFilename: "first.png"
        )
        first.hotspots = [
            Hotspot(
                x: 0.5,
                y: 0.02,
                title: "Continue",
                caption: longCaption,
                captionStyle: TextOverlayStyle(
                    backgroundHex: "#FF0000",
                    backgroundOpacity: 0
                ),
                targetStepID: second.id
            ),
        ]
        let project = DemoProject(
            name: "Web overlay test",
            steps: [first, second],
            theme: DemoTheme(
                accentHex: "#5B5CE2",
                backgroundHex: "#11131A",
                showsBranding: false
            )
        )
        let destination = try StaticDemoExporter().export(
            project: project,
            sourceAssetsDirectory: source,
            into: output
        )
        let indexURL = destination.appendingPathComponent("index.html")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 224, height: 640),
            configuration: configuration
        )
        navigationExpectation = expectation(description: "Static export loaded")
        webView.navigationDelegate = self
        webView.loadFileURL(indexURL, allowingReadAccessTo: destination)
        waitForExpectations(timeout: 10)
        try waitUntil(
            "document.querySelectorAll('.hotspot').length === 1",
            in: webView
        )

        let firstState = try XCTUnwrap(
            evaluate(
                """
                (() => {
                  const stage = document.getElementById("stage").getBoundingClientRect();
                  const caption = document.querySelector(".hotspot-caption");
                  const rect = caption.getBoundingClientRect();
                  return {
                    inside:
                      rect.left >= stage.left + 7 &&
                      rect.right <= stage.right - 7 &&
                      rect.top >= stage.top + 7 &&
                      rect.bottom <= stage.bottom - 7,
                    hasInjectedImage: caption.querySelector("#injected") !== null,
                    subtitleTop: document.querySelector(".subtitle.top") !== null,
                    background: getComputedStyle(caption).backgroundColor,
                    brandingCount: document.querySelectorAll(".brand").length
                  };
                })()
                """,
                in: webView
            ) as? [String: Any]
        )
        XCTAssertEqual(firstState["inside"] as? Bool, true)
        XCTAssertEqual(firstState["hasInjectedImage"] as? Bool, false)
        XCTAssertEqual(firstState["subtitleTop"] as? Bool, true)
        XCTAssertEqual(firstState["background"] as? String, "rgba(255, 0, 0, 0)")
        XCTAssertEqual(firstState["brandingCount"] as? Int, 0)

        webView.setFrameSize(NSSize(width: 1000, height: 640))
        try waitUntil(
            """
            document.querySelectorAll('.hotspot').length === 1 &&
            parseFloat(
              document.querySelector('.hotspot-caption').style.maxWidth
            ) >= 189.5
            """,
            in: webView
        )
        let wideState = try XCTUnwrap(
            evaluate(
                """
                (() => {
                  const caption = document.querySelector(".hotspot-caption")
                    .getBoundingClientRect();
                  const hotspot = document.querySelector(".hotspot")
                    .getBoundingClientRect();
                  return {
                    width: caption.width,
                    remainsRight: caption.left >= hotspot.right
                  };
                })()
                """,
                in: webView
            ) as? [String: Any]
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(wideState["width"] as? Double),
            190.5
        )
        XCTAssertEqual(wideState["remainsRight"] as? Bool, true)

        _ = try evaluate(
            "document.querySelector('.hotspot').click()",
            in: webView
        )
        try waitUntil(
            "document.querySelector('.subtitle.bottom') !== null",
            in: webView
        )
        let secondState = try XCTUnwrap(
            evaluate(
                """
                (() => ({
                  bottomSubtitle: document.querySelector(".subtitle.bottom") !== null,
                  captionCount: document.querySelectorAll(".hotspot-caption").length,
                  subtitleBackground: getComputedStyle(
                    document.querySelector(".subtitle.bottom")
                  ).backgroundColor
                }))()
                """,
                in: webView
            ) as? [String: Any]
        )
        XCTAssertEqual(secondState["bottomSubtitle"] as? Bool, true)
        XCTAssertEqual(secondState["captionCount"] as? Int, 0)
        XCTAssertEqual(
            secondState["subtitleBackground"] as? String,
            "rgb(0, 255, 0)"
        )

        _ = try evaluate(
            "document.querySelector('.hotspot').click()",
            in: webView
        )
        let completed = try XCTUnwrap(
            evaluate(
                """
                document.getElementById("progress").textContent === "Complete" &&
                document.getElementById("next").disabled === true
                """,
                in: webView
            ) as? Bool
        )
        XCTAssertTrue(completed)
    }

    func test_staticExport_hidesEmptySubtitleAndShowsBranding() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )
        try writePNG(to: source.appendingPathComponent("screen.png"))
        let project = DemoProject(
            name: "Empty overlay test",
            steps: [
                DemoStep(
                    title: "Only screen",
                    caption: "   ",
                    assetFilename: "screen.png"
                ),
            ],
            theme: DemoTheme(
                accentHex: "#5B5CE2",
                backgroundHex: "#11131A",
                showsBranding: true
            )
        )
        let destination = try StaticDemoExporter().export(
            project: project,
            sourceAssetsDirectory: source,
            into: output
        )
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 640),
            configuration: configuration
        )
        navigationExpectation = expectation(description: "Empty export loaded")
        webView.navigationDelegate = self
        webView.loadFileURL(
            destination.appendingPathComponent("index.html"),
            allowingReadAccessTo: destination
        )
        waitForExpectations(timeout: 10)
        try waitUntil(
            "document.querySelector('#stage img')?.complete === true",
            in: webView
        )

        let state = try XCTUnwrap(
            evaluate(
                """
                (() => ({
                  subtitleCount: document.querySelectorAll(".subtitle").length,
                  branding: document.querySelector(".brand")?.textContent
                }))()
                """,
                in: webView
            ) as? [String: Any]
        )
        XCTAssertEqual(state["subtitleCount"] as? Int, 0)
        XCTAssertEqual(state["branding"] as? String, "Made with Storybird")
    }

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        navigationExpectation?.fulfill()
        navigationExpectation = nil
    }

    private func evaluate(_ script: String, in webView: WKWebView) throws -> Any? {
        var result: Any?
        var evaluationError: Error?
        let expectation = expectation(description: "JavaScript evaluated")
        webView.evaluateJavaScript(script) { value, error in
            result = value
            evaluationError = error
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        if let evaluationError {
            throw evaluationError
        }
        return result
    }

    private func waitUntil(
        _ condition: String,
        in webView: WKWebView
    ) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try evaluate(condition, in: webView) as? Bool == true {
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("Timed out waiting for JavaScript condition: \(condition)")
    }

    private func writePNG(to url: URL) throws {
        let image = NSImage(size: NSSize(width: 1600, height: 900))
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: 1600, height: 900).fill()
        image.unlockFocus()
        let representation = try XCTUnwrap(
            NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))
        )
        let data = try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )
        try data.write(to: url, options: .atomic)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
