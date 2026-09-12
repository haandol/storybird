import AppKit
import Combine
import SwiftUI

/// Horizontal presentation geometry; none of these values belongs to a project.
struct TimelineZoom: Equatable {
    var pointsPerSecond: CGFloat = 48

    /// Fills the viewport for short videos and scales longer timelines in seconds.
    func canvasWidth(duration: Double, viewportWidth: CGFloat) -> CGFloat {
        max(viewportWidth, CGFloat(max(0, duration)) * pointsPerSecond, 1)
    }

    /// The lower bound is whole-video fit; the upper bound permits subsecond work.
    func range(duration: Double, viewportWidth: CGFloat) -> ClosedRange<CGFloat> {
        let fit = max(viewportWidth, 1) / CGFloat(max(duration, 0.001))
        return fit...max(768, fit * 8)
    }

    /// Clamps requested magnification to the current window's usable range.
    mutating func set(_ value: CGFloat, duration: Double, viewportWidth: CGFloat) {
        let limits = range(duration: duration, viewportWidth: viewportWidth)
        pointsPerSecond = min(max(value, limits.lowerBound), limits.upperBound)
    }

    /// Keeps one project time at its previous viewport position during zoom.
    static func anchoredOffset(
        time: Double, viewportX: CGFloat, duration: Double,
        canvasWidth: CGFloat, viewportWidth: CGFloat
    ) -> CGFloat {
        let x = CGFloat(min(max(time / max(duration, 0.001), 0), 1)) * canvasWidth
        return min(max(x - viewportX, 0), max(0, canvasWidth - viewportWidth))
    }

    /// Uses readable major ticks without producing thousands of offscreen labels.
    static func tickInterval(duration: Double, canvasWidth: CGFloat) -> Double {
        let target = 64 * max(duration, 0.001) / Double(max(canvasWidth, 1))
        let base = pow(10, floor(log10(target)))
        return [1.0, 2, 5, 10].map { $0 * base }.first { $0 >= target } ?? base * 10
    }

    /// Includes boundary neighbors so horizontal scrolling does not pop labels late.
    static func ticks(
        duration: Double, canvasWidth: CGFloat, offset: CGFloat, viewportWidth: CGFloat
    ) -> [Double] {
        let step = tickInterval(duration: duration, canvasWidth: canvasWidth)
        let start = max(0, Double(offset) / Double(max(canvasWidth, 1)) * duration)
        let end = min(duration, Double(offset + viewportWidth) / Double(max(canvasWidth, 1)) * duration)
        guard let first = Int(exactly: floor(start / step)),
              let last = Int(exactly: ceil(end / step)), last >= first else { return [] }
        return (max(0, first - 1)...min(first + 200, last + 1)).map { Double($0) * step }
            .filter { $0 <= duration + 0.000001 }
    }

    /// Fractional tick labels retain their precision instead of rounding to seconds.
    static func label(_ seconds: Double, interval: Double) -> String {
        let decimals = interval < 1 ? min(3, max(1, Int(ceil(-log10(interval))))) : 0
        let minutes = Int(max(seconds, 0)) / 60
        let remainder = max(seconds, 0) - Double(minutes * 60)
        let width = decimals == 0 ? 2 : 3 + decimals
        return String(format: "%d:%0*.*f", minutes, width, decimals, remainder)
    }
}

/// Observes the existing SwiftUI scroll view without replacing its native scrolling.
@MainActor
final class TimelineScrollController: ObservableObject {
    @Published private(set) var viewportWidth: CGFloat = 720
    @Published private(set) var offset: CGFloat = 0
    private(set) var pendingOffset: CGFloat?

    /// Records visible bounds only when they changed, avoiding layout feedback loops.
    func update(width: CGFloat, offset: CGFloat) {
        if abs(viewportWidth - width) > 0.5 { viewportWidth = max(width, 1) }
        if abs(self.offset - offset) > 0.5 { self.offset = max(offset, 0) }
    }

    /// Defers scrolling until the newly scaled content has completed layout.
    func requestOffset(_ offset: CGFloat) {
        pendingOffset = max(offset, 0)
    }

    /// A completed native scroll consumes only the request it actually applied.
    func didApply(_ offset: CGFloat) {
        if pendingOffset == offset { pendingOffset = nil }
    }
}

struct TimelineScrollBridge: NSViewRepresentable {
    let controller: TimelineScrollController
    let zoomAtPointer: @MainActor (Double, CGFloat, Double) -> Void

    /// Creates a transparent canvas observer; ordinary wheel events are untouched.
    func makeNSView(context: Context) -> TimelineScrollBridgeView {
        TimelineScrollBridgeView()
    }

    /// Resolves the enclosing scroll view after SwiftUI applies the latest canvas size.
    func updateNSView(_ view: TimelineScrollBridgeView, context: Context) {
        view.controller = controller
        view.zoomAtPointer = zoomAtPointer
        view.scheduleUpdate()
    }

    /// Removes observers belonging only to this timeline.
    static func dismantleNSView(_ view: TimelineScrollBridgeView, coordinator: ()) {
        view.stop()
    }
}

@MainActor
final class TimelineScrollBridgeView: NSView {
    weak var controller: TimelineScrollController?
    var zoomAtPointer: (@MainActor (Double, CGFloat, Double) -> Void)?
    private weak var observedScrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    private var navigationMonitor: Any?

    /// The overlay observes native scrolling but never becomes a pointer target.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Installation follows this canvas into or out of its owning window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { scheduleUpdate() }
    }

    /// Native layout and scroll changes are published on the following main turn.
    func scheduleUpdate() {
        DispatchQueue.main.async { [weak self] in self?.updateScrollView() }
    }

    /// Binds to the existing scroll view, preserving default and Shift scrolling.
    private func updateScrollView() {
        guard let scroll = enclosingScrollView, window != nil else { return }
        if observedScrollView !== scroll {
            stop()
            observedScrollView = scroll
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleUpdate() }
                })
            }
            navigationMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self else { return event }
                if event.type == .magnify {
                    return processMagnify(event, applicationIsActive: NSApp.isActive)
                }
                return processWheel(event, applicationIsActive: NSApp.isActive)
            }
        }
        if let requested = controller?.pendingOffset {
            scroll.layoutSubtreeIfNeeded()
            let clip = scroll.contentView
            let maximum = max(0, (scroll.documentView?.frame.width ?? 0) - clip.bounds.width)
            clip.scroll(to: NSPoint(x: min(requested, maximum), y: clip.bounds.origin.y))
            scroll.reflectScrolledClipView(clip)
            controller?.didApply(requested)
        }
        controller?.update(width: scroll.contentView.bounds.width, offset: scroll.contentView.bounds.minX)
    }

    /// Option-wheel zooms only inside this canvas and keeps other event paths intact.
    func processWheel(_ event: NSEvent, applicationIsActive: Bool) -> NSEvent? {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        guard applicationIsActive, event.type == .scrollWheel,
              event.window === window, window != nil, !isHiddenOrHasHiddenAncestor,
              event.modifierFlags.intersection(relevant) == .option else { return event }
        let point = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(point) else { return event }
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        if delta != 0, event.momentumPhase.isEmpty {
            let exponent = Double(delta) / (event.hasPreciseScrollingDeltas ? 160 : 8)
            zoom(at: point, multiplier: pow(2, min(max(exponent, -1), 1)))
        }
        return nil
    }

    /// A trackpad pinch uses the event's incremental scale without an Option key.
    /// Consuming it here prevents native scroll-view magnification of both axes.
    func processMagnify(_ event: NSEvent, applicationIsActive: Bool) -> NSEvent? {
        guard applicationIsActive, event.type == .magnify,
              event.window === window, window != nil, !isHiddenOrHasHiddenAncestor else { return event }
        let point = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(point) else { return event }
        let change = Double(event.magnification)
        let multiplier = 1 + change
        if !event.phase.contains(.cancelled), change != 0, multiplier.isFinite, multiplier > 0 {
            zoom(at: point, multiplier: multiplier)
        }
        return nil
    }

    /// Fast wheel or pinch events must use displayed geometry, not a pending zoom.
    private func zoom(at point: NSPoint, multiplier: Double) {
        let fraction = Double(point.x / max(bounds.width, 1))
        let offset = enclosingScrollView?.contentView.bounds.minX ?? 0
        zoomAtPointer?(fraction, point.x - offset, multiplier)
    }

    /// Disposes local hooks without changing the scroll view or project.
    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let navigationMonitor { NSEvent.removeMonitor(navigationMonitor) }
        navigationMonitor = nil
        observedScrollView = nil
    }
}
