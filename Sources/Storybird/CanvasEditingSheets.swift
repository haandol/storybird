import StorybirdCore
import SwiftUI

struct CanvasEditorSession: Identifiable {
    let id = UUID()
    let projectID: UUID
    let revision: Int
    let canvas: ProjectCanvas
}

struct ClipPlacementSession: Identifiable {
    let id = UUID()
    let projectID: UUID
    let revision: Int
    let clipID: UUID
    let placement: MediaPlacement
}

struct CanvasEditorSheet: View {
    @ObservedObject var store: AppStore
    let session: CanvasEditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var canvas: ProjectCanvas
    @State private var error: String?

    init(store: AppStore, session: CanvasEditorSession) {
        self.store = store; self.session = session
        _canvas = State(initialValue: session.canvas)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Canvas").font(.headline)
            Picker("Size", selection: $canvas.preset) {
                ForEach(ProjectCanvas.Preset.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.radioGroup)
            ColorPicker("Background", selection: Binding(get: { Color(hex: canvas.backgroundHex) },
                set: { canvas.backgroundHex = $0.hexRGB }), supportsOpacity: false)
            Text("Clips keep their own Fit/Fill and anchor settings.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply canvas") {
                    do {
                        _ = try store.editProject(projectID: session.projectID, expectedRevision: session.revision,
                            edits: [ProjectEdit(target: .project, id: session.projectID, action: .update,
                                values: ["canvas_preset": .string(canvas.preset.rawValue), "canvas_background_hex": .string(canvas.backgroundHex)])])
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("canvas-apply")
            }
        }.padding(22).frame(width: 420)
    }
}

struct ClipPlacementSheet: View {
    @ObservedObject var store: AppStore
    let session: ClipPlacementSession
    @Environment(\.dismiss) private var dismiss
    @State private var placement: MediaPlacement
    @State private var error: String?

    init(store: AppStore, session: ClipPlacementSession) {
        self.store = store; self.session = session
        _placement = State(initialValue: session.placement)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Clip placement").font(.headline)
            Picker("Mode", selection: $placement.mode) {
                Text("Fit entire source").tag(MediaPlacement.Mode.fit)
                Text("Fill canvas").tag(MediaPlacement.Mode.fill)
            }.pickerStyle(.segmented)
            HStack {
                Text("Horizontal anchor")
                Slider(value: $placement.anchorX, in: 0...1)
                TextField("X", value: $placement.anchorX, format: .number).frame(width: 54)
            }
            HStack {
                Text("Vertical anchor")
                Slider(value: $placement.anchorY, in: 0...1)
                TextField("Y", value: $placement.anchorY, format: .number).frame(width: 54)
            }
            Text("0 anchors to the left/top, 1 to the right/bottom. 0.5 centers the source.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply placement") {
                    do {
                        _ = try store.editProject(projectID: session.projectID, expectedRevision: session.revision,
                            edits: [ProjectEdit(target: .clip, id: session.clipID, action: .update,
                                values: ["fit_mode": .string(placement.mode.rawValue), "anchor_x": .number(placement.anchorX), "anchor_y": .number(placement.anchorY)])])
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("clip-placement-apply")
            }
        }.padding(22).frame(width: 480)
    }
}
