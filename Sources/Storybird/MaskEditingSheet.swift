import StorybirdCore
import SwiftUI

struct MaskEditorSession: Identifiable {
    let id = UUID()
    let projectID: UUID
    let revision: Int
    var mask: MaskEffect?
    var playhead: Double = 0
}

struct MaskEditingSheet: View {
    @ObservedObject var store: AppStore
    let session: MaskEditorSession
    let onSaved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var start: Double
    @State private var end: Double
    @State private var x: Double
    @State private var y: Double
    @State private var width: Double
    @State private var height: Double
    @State private var timing: LayerTimingMode?
    @State private var coordinates: MaskEffect.CoordinateSpace?
    @State private var colorHex: String
    @State private var order: Int
    @State private var error: String?

    init(store: AppStore, session: MaskEditorSession, onSaved: @escaping (UUID) -> Void = { _ in }) {
        self.store = store; self.session = session; self.onSaved = onSaved
        let duration = store.project(id: session.projectID)?.timelineDuration ?? 0
        _start = State(initialValue: session.mask?.startTime ?? session.playhead)
        _end = State(initialValue: session.mask?.endTime ?? min(session.playhead + 1, duration))
        _x = State(initialValue: session.mask?.x ?? 0.25); _y = State(initialValue: session.mask?.y ?? 0.25)
        _width = State(initialValue: session.mask?.width ?? 0.5); _height = State(initialValue: session.mask?.height ?? 0.5)
        _timing = State(initialValue: session.mask?.timingMode)
        _coordinates = State(initialValue: session.mask?.coordinateSpace)
        _colorHex = State(initialValue: session.mask?.colorHex ?? "#000000")
        _order = State(initialValue: store.project(id: session.projectID)?.effects.filter(\.isMask).firstIndex { $0.id == session.mask?.id } ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.mask == nil ? "Add opaque mask" : "Edit opaque mask").font(.headline)
            HStack {
                number("Start (s)", value: $start); number("End (s)", value: $end)
            }
            Picker("Time", selection: $timing) {
                Text("Choose time mode").tag(Optional<LayerTimingMode>.none)
                Text("Fixed project time").tag(Optional(LayerTimingMode.project))
                Text("Follow scene start").tag(Optional(LayerTimingMode.scene))
            }
            Picker("Coordinates", selection: $coordinates) {
                Text("Choose coordinate space").tag(Optional<MaskEffect.CoordinateSpace>.none)
                Text("Content · follows picture and zoom").tag(Optional(MaskEffect.CoordinateSpace.content))
                Text("Canvas · fixed screen area").tag(Optional(MaskEffect.CoordinateSpace.canvas))
            }
            HStack { number("X", value: $x); number("Y", value: $y) }
            HStack { number("Width", value: $width); number("Height", value: $height) }
            Text("Coordinates use 0…1 within the chosen space. The entire rectangle must fit.")
                .font(.caption).foregroundStyle(.secondary)
            ColorPicker("Opaque color", selection: Binding(get: { Color(hex: colorHex) }, set: { colorHex = $0.hexRGB }), supportsOpacity: false)
            if session.mask != nil {
                LabeledContent("Mask order (0 is back)") {
                    TextField("Order", value: $order, format: .number).frame(width: 70)
                }
            }
            Text("Always 100% opaque above captions and effects. No automatic tracking; the original media is preserved.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Spacer(minLength: 0)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(session.mask == nil ? "Add mask" : "Apply mask") { apply() }
                    .keyboardShortcut(.defaultAction).disabled(timing == nil || coordinates == nil)
                    .accessibilityIdentifier("mask-editor-apply")
            }
        }.padding(22).frame(width: 500, height: 510)
    }

    private func number(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(minWidth: 52, alignment: .leading)
            TextField(title, value: value, format: .number).accessibilityLabel(title)
        }
    }

    private func apply() {
        guard let timing, let coordinates else { return }
        do {
            let id: UUID
            if let mask = session.mask {
                _ = try store.editProject(projectID: session.projectID, expectedRevision: session.revision,
                    edits: [ProjectEdit(target: .effect, id: mask.id, action: .update, values: [
                        "start_time": .number(start), "end_time": .number(end), "x": .number(x), "y": .number(y),
                        "width": .number(width), "height": .number(height), "color_hex": .string(colorHex),
                        "timing_mode": .string(timing.rawValue), "coordinate_space": .string(coordinates.rawValue),
                        "order_index": .number(Double(order))])])
                id = mask.id
            } else {
                guard let current = store.project(id: session.projectID) else { throw RecordingStoreError.projectNotFound }
                guard current.revision == session.revision else { throw RecordingStoreError.revisionConflict(current.revision) }
                let edited = try MaskEditor.create(in: current, startTime: start, endTime: end,
                    x: x, y: y, width: width, height: height, timingMode: timing, coordinateSpace: coordinates, colorHex: colorHex)
                let saved = try store.saveProject(edited, expectedRevision: session.revision)
                id = saved.effects.last!.id
            }
            onSaved(id)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct MaskLayerInspector: View {
    @ObservedObject var store: AppStore
    let project: DemoProject
    let mask: MaskEffect
    let onEdit: () -> Void
    let onDelete: () -> Void
    private var masks: [DemoEffect] { project.effects.filter(\.isMask) }
    private var position: Int { masks.firstIndex { $0.id == mask.id } ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Opaque mask", systemImage: "rectangle.fill").font(.headline)
            Text(String(format: "%.3f–%.3fs", mask.startTime, mask.endTime)).monospacedDigit()
            Text(mask.timingMode == .scene ? "Follows scene start" : "Fixed project time")
            Text(mask.coordinateSpace == .content ? "Follows picture and zoom" : "Fixed canvas area")
            Text(String(format: "x %.3f · y %.3f · %.3f × %.3f", mask.x, mask.y, mask.width, mask.height)).font(.caption.monospacedDigit())
            HStack { Rectangle().fill(Color(hex: mask.colorHex)).frame(width: 28, height: 20); Text(mask.colorHex + " · 100%") }
            Button("Edit mask…", action: onEdit)
            Text("Drag the center or corners in the preview to move or resize.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Mask \(position + 1) of \(masks.count) · later masks cover earlier masks").font(.caption)
            HStack {
                Button("Send backward") { reorder(position - 1) }.disabled(position == 0)
                Button("Bring forward") { reorder(position + 1) }.disabled(position + 1 >= masks.count)
            }.controlSize(.small)
            Button("Delete mask", action: onDelete)
            Spacer()
        }.padding(20)
    }

    private func reorder(_ index: Int) {
        do { _ = try store.editProject(projectID: project.id, expectedRevision: project.revision,
            edits: [ProjectEdit(target: .effect, id: mask.id, action: .update, values: ["order_index": .number(Double(index))])]) }
        catch { store.errorMessage = error.localizedDescription }
    }
}
