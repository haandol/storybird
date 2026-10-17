import AppKit
import StorybirdCore
import SwiftUI
import UniformTypeIdentifiers

struct CaptionEditorSession: Identifiable {
    enum Mode { case edit, split, merge }
    let id = UUID()
    let projectID: UUID
    let revision: Int
    let entry: CaptionListEntry
    let mode: Mode
    var relatedIDs: [UUID] = []
    var combinedText: String?
}

struct TimelineCaptionPanel: View {
    @ObservedObject var store: AppStore
    let projectID: UUID
    @Binding var selection: Set<ProjectEditReference>
    let onSeek: (Double) -> Void
    let onAdd: () -> Void
    let onStyle: (CaptionStyleSession) -> Void
    var chooseImportURL: (() -> URL?)?
    var chooseExportDirectory: (() -> URL?)?
    @State private var editor: CaptionEditorSession?
    @State private var busy = false
    @State private var importGeneration = UUID()
    @State private var message: String?
    @State private var output: URL?

    private var project: DemoProject? { store.project(id: projectID) }
    private var entries: [CaptionListEntry] { project.map(CaptionListEntry.entries) ?? [] }
    private var chosen: [CaptionListEntry] { entries.filter { selection.contains($0.target) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Label("Captions", systemImage: "captions.bubble").font(.headline); Spacer(); Text("\(entries.count)").foregroundStyle(.secondary) }
            HStack {
                Button("Add", action: onAdd).disabled((project?.timelineDuration ?? 0) <= 0)
                Button("Import SRT…") { importFile() }.accessibilityIdentifier("caption-import-srt")
                Menu("Export SRT") {
                    ForEach(SRTCaptionScope.allCases, id: \.self) { scope in
                        Button(scope.rawValue.capitalized) { export(scope) }
                    }
                }
            }.controlSize(.small).disabled(busy)
            HStack {
                Button("Edit…") { open(.edit) }.disabled(chosen.count != 1)
                Button("Split…") { open(.split) }
                    .disabled(chosen.count != 1 || chosen.first?.kind != .independent || (chosen.first?.text.count ?? 0) < 2)
                Button("Merge…") { open(.merge) }.disabled(chosen.count < 2 || chosen.contains { $0.kind != .independent })
                Button("Style…") { style() }.disabled(chosen.isEmpty)
            }.controlSize(.small)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let output { Button("Show SRT in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }.controlSize(.small) }
            List(selection: Binding(get: { Set(chosen.map(\.id)) }, set: { ids in
                selection = Set(entries.filter { ids.contains($0.id) }.map(\.target))
            })) {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(entry.kind == .cue ? "Cue" : "Independent").font(.caption.weight(.semibold))
                            Spacer()
                            if !entry.complete { Label("Incomplete", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                        }
                        Button(String(format: "%.3f–%.3fs", entry.startTime, entry.endTime)) { onSeek(entry.startTime) }
                            .buttonStyle(.plain).font(.caption.monospacedDigit()).foregroundStyle(Color.accentColor)
                        Text(entry.text.isEmpty ? "Empty caption" : entry.text)
                            .foregroundStyle(entry.text.isEmpty ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if let description = entry.description {
                            Text(description.isEmpty ? "Cue description is empty" : "Description: " + description)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 6).tag(entry.id)
                    .contextMenu {
                        Button("Edit caption…") {
                            selection = [entry.target]
                            open(.edit)
                        }
                        Button(entry.kind == .cue ? "Delete entire Cue" : "Delete caption") { delete([entry]) }
                    }
                }
            }
            .listStyle(.inset).accessibilityIdentifier("caption-list")
            if !chosen.isEmpty {
                Button(chosen.contains { $0.kind == .cue } ? "Delete selected captions / Cues" : "Delete selected captions") { delete(chosen) }
                    .controlSize(.small).help("Deleting a Cue removes its indicator, description and caption together.")
            }
        }
        .padding(14)
        .sheet(item: $editor) { CaptionEditorSheet(store: store, session: $0) }
        .onDisappear { importGeneration = UUID(); busy = false }
        .onChange(of: projectID) { _, _ in
            importGeneration = UUID(); busy = false; message = nil; output = nil
        }
    }

    private func open(_ mode: CaptionEditorSession.Mode) {
        guard let project, let first = chosen.first else { return }
        editor = CaptionEditorSession(projectID: projectID, revision: project.revision, entry: first, mode: mode,
            relatedIDs: mode == .merge ? Array(chosen.dropFirst().map(\.id)) : [],
            combinedText: mode == .merge ? chosen.map(\.text).joined(separator: " ") : nil)
    }

    private func style() {
        guard let project else { return }
        onStyle(.make(project: project, targets: chosen.map(\.target)))
    }

    private func delete(_ entries: [CaptionListEntry]) {
        guard let project else { return }
        do {
            _ = try store.editProject(projectID: projectID, expectedRevision: project.revision,
                edits: entries.map { ProjectEdit(target: $0.target.target, id: $0.id, action: .delete) })
            selection.subtract(entries.map(\.target))
        } catch { message = error.localizedDescription }
    }

    private func importFile() {
        guard let project else { return }
        let revision = project.revision
        let url: URL?
        if let chooseImportURL { url = chooseImportURL() }
        else {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText, .plainText]
            panel.allowsMultipleSelection = false
            url = panel.runModal() == .OK ? panel.url : nil
        }
        guard let url else { return }
        let generation = UUID()
        importGeneration = generation
        busy = true
        Task { @MainActor in
            defer { if importGeneration == generation { busy = false } }
            do {
                let result = try await store.importSubtitles(projectID: projectID, expectedRevision: revision, sourceURL: url)
                // The import still belongs to its original project after a pane
                // switch; its completion must not select targets in another view.
                guard importGeneration == generation else { return }
                selection = Set(result.added_ids.map { ProjectEditReference(target: .subtitle, id: $0) })
                message = "Added \(result.added_ids.count) captions."
            } catch { if importGeneration == generation { message = error.localizedDescription } }
        }
    }

    private func export(_ scope: SRTCaptionScope) {
        let directory: URL?
        if let chooseExportDirectory { directory = chooseExportDirectory() }
        else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export SRT here"
            directory = panel.runModal() == .OK ? panel.url : nil
        }
        guard let directory else { return }
        do {
            let result = try store.exportSubtitles(projectID: projectID, scope: scope, parentDirectory: directory)
            output = URL(fileURLWithPath: result.path)
            message = "Exported \(result.caption_count) captions."
        } catch { message = error.localizedDescription }
    }
}

struct CaptionEditorSheet: View {
    @ObservedObject var store: AppStore
    let session: CaptionEditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var description: String
    @State private var start: Double
    @State private var end: Double
    @State private var offset: Int
    @State private var error: String?

    init(store: AppStore, session: CaptionEditorSession) {
        self.store = store; self.session = session
        _text = State(initialValue: session.combinedText ?? session.entry.text)
        _description = State(initialValue: session.entry.description ?? "")
        _start = State(initialValue: session.mode == .split ? (session.entry.startTime + session.entry.endTime) / 2 : session.entry.startTime)
        _end = State(initialValue: session.entry.endTime)
        _offset = State(initialValue: max(1, session.entry.text.count / 2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.mode == .split ? "Split caption" : session.mode == .merge ? "Merge captions" : "Edit caption").font(.headline)
            if session.mode == .split {
                ScrollView { Text(session.entry.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                LabeledContent("Split time (seconds)") {
                    TextField("Split time", value: $start, format: .number).frame(width: 120)
                }
                HStack {
                    Text("Characters before split")
                    TextField("Characters before split", value: $offset, format: .number)
                        .accessibilityIdentifier("caption-split-text-offset")
                    Stepper("", value: $offset, in: 1...max(1, session.entry.text.count - 1)).labelsHidden()
                }
                Text("Counts whole Unicode characters, including combined characters and emoji.").font(.caption).foregroundStyle(.secondary)
            } else {
                TextEditor(text: $text).frame(minHeight: 120).accessibilityIdentifier("caption-editor-text")
                if session.mode == .edit {
                    HStack {
                        Text("Start (s)"); TextField("Start", value: $start, format: .number)
                        Text("End (s)"); TextField("End", value: $end, format: .number)
                    }
                    if session.entry.kind == .cue {
                        Text("Cue description").font(.caption)
                        TextEditor(text: $description).frame(height: 80)
                    }
                } else {
                    Text("The first caption keeps its style and start timing; the merged interval ends with the last selected caption.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("caption-editor-apply")
            }
        }.padding(20).frame(width: 500, height: 420)
    }

    private func apply() {
        let edit: ProjectEdit
        switch session.mode {
        case .split:
            edit = ProjectEdit(target: .subtitle, id: session.entry.id, action: .split,
                values: ["time": .number(start), "text_offset": .number(Double(offset))])
        case .merge:
            edit = ProjectEdit(target: .subtitle, id: session.entry.id, action: .merge,
                values: ["text": .string(text)], relatedIDs: session.relatedIDs)
        case .edit:
            edit = ProjectEdit(target: session.entry.target.target, id: session.entry.id, action: .update,
                values: session.entry.kind == .cue
                    ? ["subtitle": .string(text), "subtitle_start_time": .number(start), "subtitle_end_time": .number(end), "description": .string(description)]
                    : ["text": .string(text), "start_time": .number(start), "end_time": .number(end)])
        }
        do { _ = try store.editProject(projectID: session.projectID, expectedRevision: session.revision, edits: [edit]); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
