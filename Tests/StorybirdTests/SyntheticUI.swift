import AppKit
import XCTest

/// Looks up a rendered control inside the mounted test view and returns its frame in view coordinates.
/// Only queries objects owned by the synthetic window.
@MainActor
func accessibilityFrame(
    named name: String,
    in view: NSView,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> NSRect {
    func findFrame(in element: AnyObject) -> NSRect? {
        if element.accessibilityIdentifier?() == name || element.accessibilityLabel?() == name {
            return element.accessibilityFrame?()
        }
        for child in element.accessibilityChildren?() ?? [] {
            if let frame = findFrame(in: child as AnyObject) { return frame }
        }
        return nil
    }

    view.layoutSubtreeIfNeeded()
    let window = try XCTUnwrap(view.window, file: file, line: line)
    let screenFrame = try XCTUnwrap(findFrame(in: view), "Control missing from mounted view: \(name)", file: file, line: line)
    XCTAssertFalse(screenFrame.isEmpty, file: file, line: line)
    return view.convert(window.convertFromScreen(screenFrame), from: nil)
}

/// Yields to the main actor while the synthetic window delivers events and SwiftUI updates its state.
@MainActor
func waitForUIState(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw NSError(domain: "SyntheticUI", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Timed out waiting for editor state at \(file):\(line)"
            ])
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}
