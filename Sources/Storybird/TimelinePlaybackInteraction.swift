import AppKit
import Combine
import SwiftUI

/// Connects explicit video/ruler interactions to an editor-local key responder.
@MainActor
final class TimelinePlaybackInteraction: ObservableObject {
    weak var keyView: TimelinePlaybackKeyView?

    /// A click on the video or ruler ends text focus before enabling playback keys.
    func activate(takeFocus: Bool = true) {
        keyView?.activate(takeFocus: takeFocus)
    }

    /// Project changes must not inherit keyboard ownership from the previous view.
    func deactivate() {
        keyView?.isInteractionActive = false
    }
}

/// A transparent marker supplies the actual editor bounds to a local event monitor.
struct TimelinePlaybackKeyScope: NSViewRepresentable {
    let interaction: TimelinePlaybackInteraction
    let isEnabled: Bool
    let togglePlayback: @MainActor () -> Void

    /// Installs no global keyboard observation or input permission.
    func makeNSView(context: Context) -> TimelinePlaybackKeyView {
        TimelinePlaybackKeyView()
    }

    /// Keeps callbacks and availability aligned with the current project editor.
    func updateNSView(_ view: TimelinePlaybackKeyView, context: Context) {
        interaction.keyView = view
        view.isPlaybackEnabled = isEnabled
        view.togglePlayback = togglePlayback
    }

    /// Removes the local monitor when this editor leaves the SwiftUI hierarchy.
    static func dismantleNSView(_ view: TimelinePlaybackKeyView, coordinator: ()) {
        view.stopMonitoring()
    }
}

@MainActor
final class TimelinePlaybackKeyView: NSView {
    var togglePlayback: (@MainActor () -> Void)?
    var isPlaybackEnabled = true
    var isInteractionActive = false
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }

    /// Focus is explicit on editing surfaces; the marker never intercepts clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A newly attached editor owns one monitor scoped to its actual window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return process(
                event, applicationIsActive: NSApp.isActive,
                windowIsKey: window?.isKeyWindow == true,
                hasModalWindow: NSApp.modalWindow != nil
            )
        }
    }

    /// Detaching or replacing a scope must not leave a callback for another project.
    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isInteractionActive = false
    }

    /// Claims playback focus only after a user acts on a non-text editing surface.
    func activate(takeFocus: Bool) {
        isInteractionActive = true
        if takeFocus { window?.makeFirstResponder(self) }
    }

    /// Filters native events before a previously focused button can consume Space.
    /// Activity/key-window inputs are explicit so tests need not activate an app.
    func process(
        _ event: NSEvent, applicationIsActive: Bool,
        windowIsKey: Bool, hasModalWindow: Bool
    ) -> NSEvent? {
        guard let window else { return event }
        if event.type == .leftMouseDown {
            isInteractionActive = event.window === window
                && !isHiddenOrHasHiddenAncestor
                && bounds.contains(convert(event.locationInWindow, from: nil))
            return event
        }
        // Tab returns control to normal keyboard navigation until the next
        // video/timeline interaction, including buttons outside the editor.
        if event.type == .keyDown, event.keyCode == 48 {
            isInteractionActive = false
            return event
        }
        let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        guard event.type == .keyDown, event.keyCode == 49,
              event.modifierFlags.intersection(modifiers).isEmpty,
              event.window === window, applicationIsActive, windowIsKey,
              isInteractionActive, isPlaybackEnabled, !isHiddenOrHasHiddenAncestor,
              window.attachedSheet == nil, !hasModalWindow,
              !Self.isTextInput(window.firstResponder) else {
            return event
        }
        if !event.isARepeat { togglePlayback?() }
        return nil
    }

    /// Native field editors and editable text controls retain ordinary space input.
    private static func isTextInput(_ responder: NSResponder?) -> Bool {
        if let text = responder as? NSTextView { return text.isEditable }
        if let field = responder as? NSTextField { return field.isEditable }
        return false
    }
}

/// Transient navigation feedback is independent of project data and undo.
@MainActor
final class TimelineScrubFeedback: ObservableObject {
    enum Origin { case slider, ruler }
    @Published private(set) var time: Double?
    private(set) var origin: Origin = .ruler
    private let dismissalDelay: Duration
    private var dismissal: Task<Void, Never>?

    /// The short dismissal delay is a presentation choice, injectable for tests.
    init(dismissalDelay: Duration = .seconds(1)) {
        self.dismissalDelay = dismissalDelay
    }

    /// A fresh drag cancels the old dismissal and displays the latest bounded time.
    func show(_ time: Double, origin: Origin) {
        dismissal?.cancel()
        dismissal = nil
        self.origin = origin
        self.time = max(0, time)
    }

    /// Keeps the final time briefly visible after the pointer is released.
    func finish() {
        dismissal?.cancel()
        let delay = dismissalDelay
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.time = nil
        }
    }

    /// Hiding or replacing the editor discards pending feedback without an edit.
    func cancel() {
        dismissal?.cancel()
        dismissal = nil
        time = nil
    }
}

struct TimelineScrubReadout: View {
    let time: Double

    var body: some View {
        Text(String(format: "%.2f s", max(0, time)))
            .font(.callout.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.accentColor, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityIdentifier("timeline-scrub-time")
    }
}

/// Native ruler tracking shares the same explicit pointer path as the split and trim handles.
struct TimelineRulerInput: NSViewRepresentable {
    let seek: @MainActor (Double) -> Void
    let finish: @MainActor () -> Void

    /// Creates a transparent input surface over the visible ruler.
    func makeNSView(context: Context) -> TimelineRulerInputView {
        TimelineRulerInputView()
    }

    /// Supplies the current duration conversion without retaining old project callbacks.
    func updateNSView(_ view: TimelineRulerInputView, context: Context) {
        view.seek = seek
        view.finish = finish
    }
}

@MainActor
final class TimelineRulerInputView: NSView {
    var seek: (@MainActor (Double) -> Void)?
    var finish: (@MainActor () -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }

    /// A direct ruler click works even before another control has keyboard focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Clicking the ruler ends text entry and begins a bounded time selection.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        updatePosition(event)
    }

    /// Dragging keeps using this ruler even across embedded native player views.
    override func mouseDragged(with event: NSEvent) {
        updatePosition(event)
    }

    /// The final pointer position is shown briefly after tracking ends.
    override func mouseUp(with event: NSEvent) {
        updatePosition(event)
        finish?()
    }

    /// Converts native window coordinates into a clamped fraction of the timeline.
    private func updatePosition(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        seek?(Double(min(max(x / max(bounds.width, 1), 0), 1)))
    }
}
