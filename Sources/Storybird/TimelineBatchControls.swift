import StorybirdCore
import SwiftUI

struct CaptionStyleSession: Identifiable {
    let id = UUID()
    let projectID: UUID
    let revision: Int
    let targets: [ProjectEditReference]
    let style: TextOverlayStyle
    let mixedFields: Set<String>
}

struct TimelineBatchControls: View {
    @ObservedObject var store: AppStore
    let project: DemoProject
    let targets: [ProjectEditReference]
    let playhead: Double
    let onSelect: ([ProjectEditReference]) -> Void
    let onStyle: (CaptionStyleSession) -> Void
    let onProperties: (BatchPropertySession) -> Void
    @State private var shift: Double = 1
    @State private var insertionPosition: Int = 1

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                Text("\(targets.count) selected").font(.caption.weight(.semibold))
                Button("Properties…") {
                    do { onProperties(try BatchPropertySession.make(project: project, targets: targets)) }
                    catch { store.errorMessage = error.localizedDescription }
                }.accessibilityIdentifier("timeline-batch-properties")
                // These edits have undo; permanent project deletion has its
                // own explicit approval flow and destructive control.
                Button("Delete") { deleteSelection() }
                    .accessibilityIdentifier("timeline-batch-delete")
                Button("Duplicate") { duplicate() }
                    .disabled(targets.contains { ref in project.effects.contains { $0.id == ref.id && $0.isCTA } })
                    .accessibilityIdentifier("timeline-batch-duplicate")
                if targets.allSatisfy({ $0.target == .clip }) {
                    TextField("Position", value: $insertionPosition, format: .number).frame(width: 64)
                        .accessibilityIdentifier("timeline-batch-clip-position")
                    Button("Move clips") {
                        do { apply(try ProjectEditPlanner.moveClips(Set(targets.map(\.id)), to: insertionPosition - 1, in: project)) }
                        catch { store.errorMessage = error.localizedDescription }
                    }.accessibilityIdentifier("timeline-batch-move-clips")
                }
                if targets.allSatisfy({ $0.target != .clip }) {
                    TextField("Shift seconds", value: $shift, format: .number).frame(width: 74)
                        .accessibilityIdentifier("timeline-batch-shift")
                    Button("Move") {
                        apply(targets.map { ProjectEdit(target: $0.target, id: $0.id, action: .move, values: ["delta": .number(shift)]) })
                    }.accessibilityIdentifier("timeline-batch-move")
                }
                if targets.allSatisfy({ $0.target == .subtitle || $0.target == .click }) {
                    Button("Caption style…") {
                        let styles = targets.compactMap { ref in
                            project.subtitles.first { $0.id == ref.id }?.style
                                ?? project.clicks.first { $0.id == ref.id }?.cueSubtitle.style
                        }
                        var mixed: Set<String> = []
                        if Set(styles.map(\.foregroundHex)).count > 1 { mixed.insert("foreground_hex") }
                        if Set(styles.map(\.backgroundHex)).count > 1 { mixed.insert("background_hex") }
                        if Set(styles.map(\.backgroundOpacity)).count > 1 { mixed.insert("background_opacity") }
                        if Set(styles.map(\.fontSize)).count > 1 { mixed.insert("font_size") }
                        onStyle(CaptionStyleSession(projectID: project.id, revision: project.revision, targets: targets,
                            style: styles.first ?? .default, mixedFields: mixed))
                    }.accessibilityIdentifier("timeline-batch-caption-style")
                }
                Button("Clear") { onSelect([]) }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func deleteSelection() {
        apply(targets.map { ProjectEdit(target: $0.target, id: $0.id, action: .delete) }, clear: true)
    }

    /// Clips copy their owned layers automatically. Excluding those redundant
    /// UI selections keeps one copied scene; the MCP edit array is explicit.
    private func duplicate() {
        let selectedClips = Set(targets.filter { $0.target == .clip }.map(\.id))
        var order = project.clips.map(\.id)
        var edits: [ProjectEdit] = []
        for clip in project.clips where selectedClips.contains(clip.id) {
            guard let index = order.firstIndex(of: clip.id) else { continue }
            edits.append(ProjectEdit(target: .clip, id: clip.id, action: .duplicate,
                values: ["destination_index": .number(Double(index + 1))]))
            order.insert(UUID(), at: index + 1)
        }
        let layers = targets.filter { ref in
            ref.target != .clip && ProjectEditPlanner.sceneOwner(of: ref, in: project).map { !selectedClips.contains($0) } != false
        }
        let starts = layers.compactMap { startTime($0) }
        let delta = playhead - (starts.min() ?? playhead)
        for ref in layers {
            let start: Double
            if let card = project.effects.first(where: { $0.id == ref.id && $0.isFullScreenCard }) { start = card.endTime }
            else { start = (startTime(ref) ?? 0) + delta }
            edits.append(ProjectEdit(target: ref.target, id: ref.id, action: .duplicate, values: ["start_time": .number(start)]))
        }
        apply(edits, selectCreated: true)
    }

    private func startTime(_ ref: ProjectEditReference) -> Double? {
        switch ref.target {
        case .subtitle: project.subtitles.first { $0.id == ref.id }?.startTime
        case .click: project.clicks.first { $0.id == ref.id }?.time
        case .audio: project.narrations.first { $0.id == ref.id }?.startTime
        case .effect: project.effects.first { $0.id == ref.id }?.startTime
        case .clip, .project: nil
        }
    }

    private func apply(_ edits: [ProjectEdit], clear: Bool = false, selectCreated: Bool = false) {
        do {
            let result = try store.editProject(projectID: project.id, expectedRevision: project.revision, edits: edits)
            if clear { onSelect([]) }
            else if selectCreated {
                onSelect(result.created.flatMap { creation in
                    creation.created.filter { $0.target == edits[creation.operationIndex].target }
                })
            }
        } catch { store.errorMessage = error.localizedDescription }
    }
}

struct CaptionBulkStyleSheet: View {
    @ObservedObject var store: AppStore
    let session: CaptionStyleSession
    @Environment(\.dismiss) private var dismiss
    @State private var style: TextOverlayStyle
    @State private var error: String?
    @State private var changed: Set<String> = []

    init(store: AppStore, session: CaptionStyleSession) {
        self.store = store
        self.session = session
        _style = State(initialValue: session.style)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Style \(session.targets.count) captions").font(.headline)
            Text("Only checked properties are applied to the selected captions.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                property("Text color", key: "foreground_hex") {
                    ColorPicker("", selection: Binding(get: { Color(hex: style.foregroundHex) }, set: {
                        style.foregroundHex = $0.hexRGB; changed.insert("foreground_hex")
                    }), supportsOpacity: false).labelsHidden()
                }
                property("Background", key: "background_hex") {
                    ColorPicker("", selection: Binding(get: { Color(hex: style.backgroundHex) }, set: {
                        style.backgroundHex = $0.hexRGB; changed.insert("background_hex")
                    }), supportsOpacity: false).labelsHidden()
                }
                property("Background opacity", key: "background_opacity") {
                    Slider(value: Binding(get: { style.backgroundOpacity }, set: {
                        style.backgroundOpacity = $0; changed.insert("background_opacity")
                    }), in: 0...1).frame(width: 110)
                }
                property("Font size", key: "font_size") {
                    TextField("Size", value: Binding(get: { style.fontSize }, set: {
                        style.fontSize = $0; changed.insert("font_size")
                    }), format: .number).frame(width: 70).accessibilityIdentifier("caption-batch-font-size")
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            Spacer(minLength: 0)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply style") { apply() }.keyboardShortcut(.defaultAction)
                    .disabled(changed.isEmpty)
                    .accessibilityIdentifier("caption-batch-style-apply")
            }
        }
        .padding(20).frame(width: 380, height: 420)
    }

    private func property<Content: View>(_ title: String, key: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { changed.contains(key) }, set: {
                if $0 { changed.insert(key) } else { changed.remove(key) }
            }))
            if session.mixedFields.contains(key), !changed.contains(key) {
                Text("Mixed").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            content()
        }
    }

    /// Keep the session's original revision and entered style after a failure;
    /// reopening is an explicit choice to start from newer project state.
    private func apply() {
        let edits = session.targets.map { ref in
            let prefix = ref.target == .click ? "subtitle_" : ""
            let fields: [String: ProjectEditValue] = ["foreground_hex": .string(style.foregroundHex),
                "background_hex": .string(style.backgroundHex), "background_opacity": .number(style.backgroundOpacity),
                "font_size": .number(style.fontSize)]
            let values = Dictionary(uniqueKeysWithValues: fields.filter { changed.contains($0.key) }.map { (prefix + $0.key, $0.value) })
            return ProjectEdit(target: ref.target, id: ref.id, action: .update, values: values)
        }
        do {
            _ = try store.editProject(projectID: session.projectID, expectedRevision: session.revision, edits: edits)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
