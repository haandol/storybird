import StorybirdCore
import SwiftUI

struct TimelineAudioActions: View {
    let layer: NarrationClip
    let playhead: Double
    let action: (TimelineAudioModel.Action) -> Void

    var body: some View {
        Button { action(.split) } label: { Label("Split", systemImage: "scissors") }
            .disabled(playhead <= layer.startTime || playhead >= layer.endTime)
            .accessibilityIdentifier("audio-split")
        Button { action(.duplicate) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            .accessibilityIdentifier("audio-duplicate")
        Button { action(.mute) } label: {
            Label(layer.isMuted ? "Unmute" : "Mute", systemImage: layer.isMuted ? "speaker.slash" : "speaker.wave.2")
        }
        .accessibilityIdentifier("audio-mute")
        Button(role: .destructive) { action(.delete) } label: { Label("Delete", systemImage: "trash") }
            .accessibilityIdentifier("audio-delete")
    }
}

struct TimelineAudioToolbar: View {
    @ObservedObject var model: TimelineAudioModel
    let store: AppStore
    let project: DemoProject
    let layer: NarrationClip
    let playhead: Double
    let onEditText: () -> Void
    let onInspector: () -> Void

    private var volume: Double {
        model.previewLayer?.id == layer.id ? model.previewLayer!.volume : layer.volume
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                Text(layer.name).font(.caption.weight(.semibold)).lineLimit(1).frame(maxWidth: 120)
                TimelineAudioActions(layer: layer, playhead: playhead) {
                    model.perform($0, layerID: layer.id, at: playhead, project: project, store: store)
                }
                Divider().frame(height: 18)
                Image(systemName: "speaker.wave.2")
                Slider(value: Binding(get: { volume }, set: {
                    model.update(layerID: layer.id, adjustment: .volume, value: $0, project: project)
                }), in: 0...max(2, layer.volume), onEditingChanged: { editing in
                    if !editing { model.finish(in: store) }
                })
                .frame(width: 100)
                .accessibilityLabel("Audio volume")
                .accessibilityIdentifier("audio-volume")
                Text(volume, format: .percent.precision(.fractionLength(0))).monospacedDigit().font(.caption)
                if layer.voiceProfileID != nil {
                    Button("Edit speech", action: onEditText)
                }
                Button(action: onInspector) { Label("Details", systemImage: "slider.horizontal.3") }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("timeline-audio-toolbar")
        .onDisappear { model.cancelAdjustment() }
    }
}

struct TimelineAudioBlock: View {
    @ObservedObject var store: AppStore
    @ObservedObject var model: TimelineAudioModel
    @ObservedObject var move: TimelineLayerDragModel
    let project: DemoProject
    let layer: NarrationClip
    let canvasWidth: Double
    let selected: Bool
    let playhead: Double
    let onSelect: () -> Void
    let onEditText: () -> Void
    let onBegin: () -> Void
    let onEnd: () -> Void
    @GestureState private var dragging = false

    private var scale: Double { canvasWidth / max(project.timelineDuration, 0.001) }
    private var displayed: NarrationClip {
        var result = model.previewLayer?.id == layer.id ? model.previewLayer! : layer
        if move.target == .narration(layer.id) { result.startTime += move.delta }
        return result
    }
    private var blockWidth: Double { max(18, displayed.duration * scale) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            blockBody
            if selected {
                trimHandle(.trimStart).offset(x: 0)
                trimHandle(.trimEnd).offset(x: blockWidth - 8)
                fadeHandle(.fadeIn)
                    .offset(x: max(8, min(blockWidth - 18, displayed.fadeIn * scale)), y: 0)
                fadeHandle(.fadeOut)
                    .offset(x: max(8, min(blockWidth - 18, blockWidth - displayed.fadeOut * scale - 10)), y: 23)
            }
        }
        .frame(width: blockWidth, height: 38)
        .offset(x: displayed.startTime * scale)
        .zIndex(dragging ? 2 : selected ? 1 : 0)
        .contextMenu {
            TimelineAudioActions(layer: layer, playhead: playhead) {
                model.perform($0, layerID: layer.id, at: playhead, project: project, store: store)
            }
            if layer.voiceProfileID != nil { Button("Edit speech", action: onEditText) }
        }
        .accessibilityIdentifier("timeline-layer-\(layer.id.uuidString)")
        .help("\(layer.name) · Drag to move · Drag edges to trim · Double-click to edit")
        .onChange(of: dragging) { _, active in
            if !active {
                // Let onEnded publish first; an interrupted gesture only cancels.
                Task { @MainActor in
                    guard !dragging else { return }
                    model.cancelAdjustment()
                    move.cancel()
                    onEnd()
                }
            }
        }
    }

    private var blockBody: some View {
        Button(action: onSelect) {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if layer.isMuted { Image(systemName: "speaker.slash").font(.caption2) }
                Text(layer.name).font(.caption2.weight(.medium)).lineLimit(1)
            }
            AudioWaveformView(
                url: store.repository.assetURL(projectID: project.id, filename: layer.filename),
                sourceStart: max(0, displayed.sourceStart), duration: max(0.001, displayed.duration),
                sourceDuration: layer.sourceDuration
            )
            .frame(height: 15)
            .overlay {
                GeometryReader { geometry in
                    Path { path in
                        let envelope = displayed.effectiveFadeEnvelope
                        for (index, time) in envelope.breakpoints(length: max(0.001, displayed.duration)).enumerated() {
                            let point = CGPoint(x: time / max(0.001, displayed.duration) * geometry.size.width,
                                y: (1 - envelope.gain(at: time)) * geometry.size.height)
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }
                    .stroke(Color.primary.opacity(0.55), lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
        }
        .padding(.horizontal, selected ? 12 : 6)
        .frame(width: blockWidth, height: 38)
        .background(layer.isMuted ? Color.gray.opacity(0.2) : Color.cyan.opacity(0.22),
            in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .cyan.opacity(0.5),
            lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { onSelect(); onEditText() })
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline-layer-canvas"))
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { value in
                    if move.target == nil { onSelect(); onBegin() }
                    move.update(target: .narration(layer.id), translation: value.translation.width,
                        canvasWidth: canvasWidth, project: project)
                }
                .onEnded { value in
                    move.update(target: .narration(layer.id), translation: value.translation.width,
                        canvasWidth: canvasWidth, project: project)
                    move.finish(in: store)
                    onEnd()
                }
        )
    }

    /// Edge handles own their gesture, so trimming cannot also move the block.
    private func trimHandle(_ operation: TimelineAudioModel.Adjustment) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
            .frame(width: 8, height: 38)
            .contentShape(Rectangle())
            .overlay(adjustmentHandle(operation))
            .accessibilityLabel(operation == .trimStart ? "Trim audio start" : "Trim audio end")
            .accessibilityIdentifier(operation == .trimStart ? "audio-trim-start" : "audio-trim-end")
            .help(operation == .trimStart ? "Drag to trim the start" : "Drag to trim the end")
    }

    /// Separate top/bottom handles stay reachable when both fades are zero.
    private func fadeHandle(_ operation: TimelineAudioModel.Adjustment) -> some View {
        Circle().fill(Color.accentColor)
            .overlay(Circle().stroke(Color.primary.opacity(0.6), lineWidth: 1))
            .frame(width: 12, height: 12)
            .contentShape(Rectangle())
            .overlay(adjustmentHandle(operation))
            .accessibilityLabel(operation == .fadeIn ? "Fade in" : "Fade out")
            .accessibilityIdentifier(operation == .fadeIn ? "audio-fade-in" : "audio-fade-out")
            .help(operation == .fadeIn ? "Drag right for fade in" : "Drag left for fade out")
    }

    /// Uses a stable canvas coordinate space because the left trim handle
    /// itself moves while dragging. Only release publishes the proposed range.
    private func adjustmentHandle(_ operation: TimelineAudioModel.Adjustment) -> some View {
        TimelineAudioDragHandle(
            onChange: { translation in
                if model.previewLayer == nil { onBegin() }
                model.update(layerID: layer.id, adjustment: operation, value: translation / scale, project: project)
            },
            onEnd: {
                model.finish(in: store)
                onEnd()
            },
            onCancel: {
                model.cancelAdjustment()
                onEnd()
            }
        )
    }
}

private struct TimelineAudioDragHandle: NSViewRepresentable {
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    let onCancel: () -> Void

    /// Gives small handles a native pointer target while SwiftUI draws them.
    func makeNSView(context: Context) -> HandleView { HandleView() }

    /// Refreshes callbacks without replacing the native drag's window origin.
    func updateNSView(_ view: HandleView, context: Context) {
        view.onChange = onChange; view.onEnd = onEnd; view.onCancel = onCancel
    }

    final class HandleView: NSView {
        var onChange: (Double) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onCancel: () -> Void = {}
        private var origin: CGFloat?
        override var acceptsFirstResponder: Bool { true }

        /// Handles work on the first click without activating other controls.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// Shows direct horizontal manipulation on hover.
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        /// Captures a stable window coordinate before the handle itself moves.
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            origin = event.locationInWindow.x
            onChange(0)
        }
        /// Changes only the transient edit while the pointer is held.
        override func mouseDragged(with event: NSEvent) {
            guard let origin else { return }
            onChange(event.locationInWindow.x - origin)
        }
        /// Publishes exactly once, including release outside the small handle.
        override func mouseUp(with event: NSEvent) {
            guard let origin else { return }
            onChange(event.locationInWindow.x - origin)
            self.origin = nil
            onEnd()
        }
        /// Escape discards the preview without changing the stored project.
        override func cancelOperation(_ sender: Any?) {
            origin = nil
            onCancel()
        }
    }
}

struct TimelineNarrationEditor: View {
    @ObservedObject var store: AppStore
    let projectID: UUID
    let layer: NarrationClip
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var language: String
    @State private var isWorking = false
    @State private var errorMessage: String?

    /// Holds editing input independently so regeneration failure cannot erase it.
    init(store: AppStore, projectID: UUID, layer: NarrationClip) {
        self.store = store; self.projectID = projectID; self.layer = layer
        _text = State(initialValue: layer.text)
        _language = State(initialValue: layer.language)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Narration", text: $text, axis: .vertical).lineLimit(4...8)
                Picker("Language", selection: $language) {
                    ForEach(VoiceLanguage.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
                    if VoiceLanguage(rawValue: language) == nil { Text(language).tag(language) }
                }
                Text("Only this audio layer is replaced after successful generation.")
                    .font(.caption).foregroundStyle(.secondary)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                if isWorking { ProgressView("Generating speech…") }
            }
            .formStyle(.grouped)
            .disabled(isWorking)
            .navigationTitle("Edit speech")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isWorking) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Regenerate") { regenerate() }
                        .disabled(isWorking || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(width: 440, height: 360)
        .interactiveDismissDisabled(isWorking)
    }

    /// Captures the current revision before generation; failures keep both the
    /// old project audio and the user's replacement text available for retry.
    private func regenerate() {
        guard let current = store.project(id: projectID) else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await store.updateNarration(projectID: projectID, narrationID: layer.id,
                    expectedRevision: current.revision, text: text, language: language)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
