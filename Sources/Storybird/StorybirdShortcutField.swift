import AppKit
import SwiftUI

struct StorybirdShortcutField: View {
    @ObservedObject var settings: StorybirdShortcutSettings
    let action: StorybirdCommandAction

    var body: some View {
        HStack(spacing: 5) {
            Button(
                settings.recordingAction == action
                    ? "Press a key"
                    : settings.shortcut(for: action).displayName
            ) {
                settings.recordingAction =
                    settings.recordingAction == action ? nil : action
            }
            .buttonStyle(.bordered)
            .monospaced()
            .background {
                if settings.recordingAction == action {
                    StorybirdShortcutRecorder { shortcut in
                        settings.update(action, to: shortcut)
                        settings.recordingAction = nil
                    }
                }
            }
        }
    }
}

private struct StorybirdShortcutRecorder: NSViewRepresentable {
    let onCapture: (StorybirdShortcut) -> Void

    /// Creates an AppKit first responder because SwiftUI does not expose raw
    /// physical key codes for shortcut capture.
    func makeNSView(context: Context) -> NSView {
        let view = KeyCaptureView()
        view.onCapture = onCapture
        return view
    }

    /// Keeps the callback current while preserving the first-responder view
    /// across SwiftUI updates.
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? KeyCaptureView)?.onCapture = onCapture
    }

    private final class KeyCaptureView: NSView {
        var onCapture: ((StorybirdShortcut) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        /// Converts one raw key event into a normalized local shortcut and lets
        /// Settings validate it before replacing a working value.
        override func keyDown(with event: NSEvent) {
            onCapture?(
                StorybirdShortcut(
                    keyCode: event.keyCode,
                    modifiers: event.modifierFlags
                )
            )
        }
    }
}
