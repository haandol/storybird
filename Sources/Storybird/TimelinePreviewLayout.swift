import SwiftUI

/// Presentation state stays outside the project so resizing never creates an edit.
struct TimelinePreviewLayout: Equatable {
    enum Visibility {
        case empty, visible, hidden
    }

    var visibility: Visibility = .empty
    var previewFraction: CGFloat = 0.45
    static let dividerHeight: CGFloat = 10

    /// Both the empty placeholder and a rendered preview can yield their space.
    mutating func toggleVisibility() {
        visibility = visibility == .hidden ? .visible : .hidden
    }

    /// Keeps the timeline tools reachable even when the window shrinks mid-drag.
    func previewHeight(totalHeight: CGFloat, minimumTimelineHeight: CGFloat) -> CGFloat {
        guard visibility != .hidden else { return 0 }
        let available = max(0, totalHeight - Self.dividerHeight)
        return boundedHeight(available * previewFraction, available: available, minimumTimelineHeight: minimumTimelineHeight)
    }

    /// Uses the drag's starting height rather than accumulating its translation.
    mutating func resize(
        from startHeight: CGFloat, translation: CGFloat,
        totalHeight: CGFloat, minimumTimelineHeight: CGFloat
    ) {
        guard visibility != .hidden else { return }
        let available = max(0, totalHeight - Self.dividerHeight)
        guard available > 0 else { return }
        let height = boundedHeight(startHeight + translation, available: available, minimumTimelineHeight: minimumTimelineHeight)
        previewFraction = height / available
    }

    /// Window resizing and pointer resizing share one bound; neither path may
    /// reserve space needed by the timeline's controls and scroll viewport.
    private func boundedHeight(_ requested: CGFloat, available: CGFloat, minimumTimelineHeight: CGFloat) -> CGFloat {
        let upperBound = max(0, available - minimumTimelineHeight)
        return min(upperBound, max(min(100, upperBound), requested))
    }
}

/// One split layout serves both window widths and removes all preview space when hidden.
struct TimelinePreviewSplitView<Preview: View, Timeline: View>: View {
    @Binding var layout: TimelinePreviewLayout
    let minimumTimelineHeight: CGFloat
    @ViewBuilder var preview: () -> Preview
    @ViewBuilder var timeline: () -> Timeline

    var body: some View {
        GeometryReader { proxy in
            let height = layout.previewHeight(
                totalHeight: proxy.size.height, minimumTimelineHeight: minimumTimelineHeight
            )
            VStack(spacing: 0) {
                if layout.visibility != .hidden {
                    Group {
                        if layout.visibility == .empty {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10).fill(.black)
                                Button {
                                    layout.visibility = .visible
                                } label: {
                                    Label("Show Preview", systemImage: "video")
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(.indigo, in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("timeline-preview-load")
                            }
                            .padding(12)
                        } else {
                            preview()
                        }
                    }
                    .frame(height: height)

                    divider(height: height, totalHeight: proxy.size.height)
                }
                timeline()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// A visible handle uses a fixed coordinate space so moving it cannot amplify a drag.
    private func divider(height: CGFloat, totalHeight: CGFloat) -> some View {
        TimelinePreviewDivider { translation in
            layout.resize(
                from: height, translation: translation,
                totalHeight: totalHeight, minimumTimelineHeight: minimumTimelineHeight
            )
        }
        .frame(height: TimelinePreviewLayout.dividerHeight)
    }
}

/// Native pointer tracking keeps the narrow splitter hittable across embedded video views.
private struct TimelinePreviewDivider: NSViewRepresentable {
    let resize: (CGFloat) -> Void

    /// Creates a splitter with a native resize cursor and accessibility actions.
    func makeNSView(context: Context) -> TimelinePreviewDividerView {
        TimelinePreviewDividerView()
    }

    /// Supplies the latest layout while an active drag retains its starting callback.
    func updateNSView(_ view: TimelinePreviewDividerView, context: Context) {
        view.resize = resize
    }
}

final class TimelinePreviewDividerView: NSView {
    var resize: ((CGFloat) -> Void)?
    private var dragOrigin: CGFloat?
    private var dragResize: ((CGFloat) -> Void)?

    /// Gives both pointer and assistive input the same local resize operation.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Preview and timeline height")
        setAccessibilityIdentifier("timeline-preview-divider")
        toolTip = "Drag up or down to resize the preview and timeline"
    }

    /// The divider is constructed programmatically with the current layout callback.
    required init?(coder: NSCoder) { return nil }

    /// Makes the resizing affordance visible without changing the layer row geometry.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.25).setFill()
        bounds.fill()
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 18, y: bounds.midY - 1.5, width: 36, height: 3),
            xRadius: 1.5, yRadius: 1.5).fill()
    }

    /// Shows a resize cursor over the entire divider, including its edges.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    /// Resizing is safe as the first interaction with an inactive editor window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Freezes the starting height callback so repeated events cannot compound movement.
    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow.y
        dragResize = resize
    }

    /// Converts AppKit's upward-positive coordinates to downward-positive preview height.
    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        dragResize?(dragOrigin - event.locationInWindow.y)
    }

    /// Ends tracking without writing a project edit or replaying the last movement.
    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        dragResize = nil
    }

    /// Lets assistive input enlarge the preview through the same bounded resize path.
    override func accessibilityPerformIncrement() -> Bool {
        resize?(30)
        return resize != nil
    }

    /// Lets assistive input enlarge the timeline through the same bounded resize path.
    override func accessibilityPerformDecrement() -> Bool {
        resize?(-30)
        return resize != nil
    }
}
