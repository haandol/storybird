import StorybirdCore
import SwiftUI

@MainActor
final class PreviewEffectEditModel: ObservableObject {
    enum Operation { case moveRectangle, topLeft, topRight, bottomLeft, bottomRight, zoomStart, zoomEnd, startScale, endScale }
    @Published private(set) var draft: DemoEffect?
    private var baseline: DemoProject?
    private var original: DemoEffect?
    private var operation: Operation = .moveRectangle
    private var contentFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var camera = VideoCameraPresentation.identity
    private var imageSize = CGSize(width: 1, height: 1)

    func begin(project: DemoProject, effectID: UUID, operation: Operation, time: Double, imageSize: CGSize) {
        guard baseline == nil, let effect = project.effects.first(where: { $0.id == effectID }) else { return }
        baseline = project; original = effect; draft = effect
        self.operation = operation; self.imageSize = imageSize
        contentFrame = ProjectContentGeometry.frame(in: project, at: time)
        camera = VideoOverlayPresentation.camera(in: project, at: time)
        if case let .mask(value) = effect, value.coordinateSpace == .canvas {
            contentFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
            camera = .identity
        }
    }

    /// Only view-local effect geometry changes during a drag. Its original
    /// transform and revision remain fixed until the final mouse-up save.
    func update(translation: CGSize) {
        guard let original, imageSize.width > 0, imageSize.height > 0 else { return }
        let dx = translation.width / imageSize.width / max(contentFrame.width * camera.scale, 0.000001)
        let dy = translation.height / imageSize.height / max(contentFrame.height * camera.scale, 0.000001)
        switch original {
        case var .spotlight(value):
            let rect = rectangle(x: value.x, y: value.y, width: value.width, height: value.height, dx: dx, dy: dy)
            value.x = rect.minX; value.y = rect.minY; value.width = rect.width; value.height = rect.height
            draft = .spotlight(value)
        case var .mask(value):
            let rect = rectangle(x: value.x, y: value.y, width: value.width, height: value.height, dx: dx, dy: dy)
            value.x = rect.minX; value.y = rect.minY; value.width = rect.width; value.height = rect.height
            draft = .mask(value)
        case var .panZoom(value):
            if operation == .zoomStart {
                value.startX = min(max(value.startX + dx, 0), 1)
                value.startY = min(max(value.startY + dy, 0), 1)
            } else if operation == .zoomEnd {
                value.endX = min(max(value.endX + dx, 0), 1)
                value.endY = min(max(value.endY + dy, 0), 1)
            }
            draft = .panZoom(value)
        default: break
        }
    }

    private func rectangle(x: Double, y: Double, width: Double, height: Double, dx: Double, dy: Double) -> CGRect {
        var value = CGRect(x: x, y: y, width: width, height: height)
        let right = x + width, bottom = y + height
        let minimum = min(0.001, width / 2, height / 2)
        switch operation {
        case .moveRectangle:
            value.origin.x = min(max(x + dx, 0), 1 - width)
            value.origin.y = min(max(y + dy, 0), 1 - height)
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            if operation == .topLeft || operation == .bottomLeft {
                value.origin.x = min(max(x + dx, 0), right - minimum)
                value.size.width = right - value.minX
            } else { value.size.width = min(max(width + dx, minimum), 1 - x) }
            if operation == .topLeft || operation == .topRight {
                value.origin.y = min(max(y + dy, 0), bottom - minimum)
                value.size.height = bottom - value.minY
            } else { value.size.height = min(max(height + dy, minimum), 1 - y) }
        default: break
        }
        return value
    }

    func setScale(_ value: Double) {
        guard case var .panZoom(effect) = draft else { return }
        if operation == .startScale { effect.startScale = value } else { effect.endScale = value }
        draft = .panZoom(effect)
    }

    func displayedProject(_ project: DemoProject) -> DemoProject {
        guard let draft, operation != .zoomStart, operation != .zoomEnd,
              let index = project.effects.firstIndex(where: { $0.id == draft.id }) else { return project }
        var result = project
        result.effects[index] = draft
        return result
    }

    func finish(in store: AppStore) {
        defer { cancel() }
        guard let baseline, let draft else { return }
        let values: [String: ProjectEditValue]
        switch draft {
        case let .spotlight(effect): values = ["x": .number(effect.x), "y": .number(effect.y), "width": .number(effect.width), "height": .number(effect.height)]
        case let .mask(effect): values = ["x": .number(effect.x), "y": .number(effect.y), "width": .number(effect.width), "height": .number(effect.height)]
        case let .panZoom(effect): values = ["start_x": .number(effect.startX), "start_y": .number(effect.startY), "start_scale": .number(effect.startScale),
            "end_x": .number(effect.endX), "end_y": .number(effect.endY), "end_scale": .number(effect.endScale)]
        default: return
        }
        do { _ = try store.editProject(projectID: baseline.id, expectedRevision: baseline.revision,
            edits: [ProjectEdit(target: .effect, id: draft.id, action: .update, values: values)]) }
        catch { store.errorMessage = error.localizedDescription }
    }

    func cancel() { baseline = nil; original = nil; draft = nil }
}

struct PreviewEffectControls: View {
    @ObservedObject var store: AppStore
    @ObservedObject var model: PreviewEffectEditModel
    let project: DemoProject
    let effect: DemoEffect
    let time: Double
    let imageFrame: CGRect
    let onBegin: () -> Void
    @GestureState private var dragging = false
    @State private var adjustingScale = false
    // Escape clears the draft, but the current pointer gesture must stay
    // consumed until release so later movement cannot restart that edit.
    @State private var activeHandle: PreviewEffectEditModel.Operation?

    private var displayed: DemoEffect { model.draft?.id == effect.id ? model.draft! : effect }
    private var camera: VideoCameraPresentation { VideoOverlayPresentation.camera(in: project, at: time) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch displayed {
            case let .spotlight(value):
                let value = ProjectContentGeometry.spotlight(value, in: project, at: time)
                let rect = CGRect(x: imageFrame.minX + value.x * imageFrame.width, y: imageFrame.minY + value.y * imageFrame.height,
                    width: value.width * imageFrame.width, height: value.height * imageFrame.height)
                Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5])).frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
                handle(.moveRectangle, at: CGPoint(x: rect.midX, y: rect.midY), label: "Move spotlight")
                handle(.topLeft, at: CGPoint(x: rect.minX, y: rect.minY), label: "Resize top left")
                handle(.topRight, at: CGPoint(x: rect.maxX, y: rect.minY), label: "Resize top right")
                handle(.bottomLeft, at: CGPoint(x: rect.minX, y: rect.maxY), label: "Resize bottom left")
                handle(.bottomRight, at: CGPoint(x: rect.maxX, y: rect.maxY), label: "Resize bottom right")
            case let .mask(value):
                let normalized = MaskGeometry.normalizedRect(for: value, in: project, at: time)
                let rect = CGRect(x: imageFrame.minX + normalized.minX * imageFrame.width,
                    y: imageFrame.minY + normalized.minY * imageFrame.height,
                    width: normalized.width * imageFrame.width, height: normalized.height * imageFrame.height)
                Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5]))
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
                handle(.moveRectangle, at: CGPoint(x: rect.midX, y: rect.midY), label: "Move mask")
                handle(.topLeft, at: CGPoint(x: rect.minX, y: rect.minY), label: "Resize mask top left")
                handle(.topRight, at: CGPoint(x: rect.maxX, y: rect.minY), label: "Resize mask top right")
                handle(.bottomLeft, at: CGPoint(x: rect.minX, y: rect.maxY), label: "Resize mask bottom left")
                handle(.bottomRight, at: CGPoint(x: rect.maxX, y: rect.maxY), label: "Resize mask bottom right")
            case let .panZoom(value):
                let start = point(value.startX, value.startY), end = point(value.endX, value.endY)
                Path { $0.move(to: start); $0.addLine(to: end) }.stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .allowsHitTesting(false)
                handle(.zoomStart, at: start, label: "Start center")
                handle(.zoomEnd, at: end, label: "End center")
                VStack(spacing: 6) {
                    zoomSlider("Start zoom", operation: .startScale, value: value.startScale)
                    zoomSlider("End zoom", operation: .endScale, value: value.endScale)
                }.padding(10).frame(width: 260).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .position(x: imageFrame.midX, y: imageFrame.maxY - 42)
            default: EmptyView()
            }
        }
        .coordinateSpace(name: "effect-preview-edit")
        .onChange(of: dragging) { _, active in
            if !active { Task { @MainActor in if !dragging && !adjustingScale { model.cancel(); activeHandle = nil } } }
        }
        .onDisappear { model.cancel() }
    }

    private func point(_ x: Double, _ y: Double) -> CGPoint {
        let source = ProjectContentGeometry.point(x: x, y: y, in: project, at: time)
        let transformed = camera.transform(x: source.x, y: source.y)
        return CGPoint(x: imageFrame.minX + transformed.x * imageFrame.width, y: imageFrame.minY + transformed.y * imageFrame.height)
    }

    private func handle(_ operation: PreviewEffectEditModel.Operation, at position: CGPoint, label: String) -> some View {
        Button {} label: {
            Circle().fill(Color.accentColor).overlay(Circle().stroke(.white, lineWidth: 2)).frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).position(position).help(label).accessibilityLabel(label)
            .simultaneousGesture(TimelinePointerGestures.drag(coordinateSpace: "effect-preview-edit", updating: $dragging, onChanged: { value, _ in
                onBegin()
                if activeHandle == nil {
                    activeHandle = operation
                    model.begin(project: project, effectID: effect.id, operation: operation, time: time, imageSize: imageFrame.size)
                }
                model.update(translation: value.translation)
            }, onEnded: { value, _ in
                model.update(translation: value.translation)
                model.finish(in: store)
                activeHandle = nil
            }))
    }

    private func zoomSlider(_ title: String, operation: PreviewEffectEditModel.Operation, value: Double) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 65, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { new in
                onBegin()
                if !adjustingScale {
                    model.begin(project: project, effectID: effect.id, operation: operation, time: time, imageSize: imageFrame.size)
                }
                model.setScale(new)
                if !adjustingScale { model.finish(in: store) }
            }), in: 1...3, onEditingChanged: { active in
                adjustingScale = active
                if active {
                    onBegin()
                    model.begin(project: project, effectID: effect.id, operation: operation, time: time, imageSize: imageFrame.size)
                } else { model.finish(in: store) }
            })
            Text(String(format: "%.2f×", value)).font(.caption.monospacedDigit()).frame(width: 45)
        }
    }
}
