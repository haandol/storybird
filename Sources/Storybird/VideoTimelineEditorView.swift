import AVFoundation
import AVKit
import StorybirdCore
import SwiftUI

private enum TimelineLayerSelection: Equatable {
    case clip(UUID)
    case click(UUID)
    case subtitle(UUID)
    case narration(UUID)
    case effect(UUID)
    case suggestion(UUID)
}

private struct PlaybackCompositionState: Equatable {
    struct Card: Equatable {
        let id: UUID
        let start: Double
        let end: Double
    }
    let clips: [VideoClip]
    let narrations: [NarrationClip]
    let sourceAudioVolume: Double
    let sourceAudioMuted: Bool
    let cards: [Card]

    /// Reloads media only for changes affecting the picture clock or sound;
    /// subtitle and visual style edits remain lightweight SwiftUI overlays.
    init(project: DemoProject) {
        clips = project.clips
        narrations = project.narrations
        sourceAudioVolume = project.sourceAudioVolume
        sourceAudioMuted = project.sourceAudioMuted
        cards = project.effects.filter(\.isFullScreenCard).map {
            Card(id: $0.id, start: $0.startTime, end: $0.endTime)
        }
    }
}

struct VideoTimelineEditorView: View {
    @ObservedObject var store: AppStore
    @Binding var project: DemoProject

    @StateObject private var playbackOwner: VideoPlaybackOwner
    private var playback: VideoPlaybackModel { playbackOwner.playback }
    @State private var playbackError: String?
    @State private var trackCache = TimelineTrackCache()
    private let videoURL: URL
    @State private var selection: TimelineLayerSelection?
    @State private var isInspectorPresented = false
    @State private var isPlacingClick = false
    @State private var previewLayout = TimelinePreviewLayout()
    @State private var showAudioComposer = false
    @StateObject private var audioModel = TimelineAudioModel()
    @State private var editingNarration: NarrationClip?
    @StateObject private var layerDrag = TimelineLayerDragModel()
    @GestureState private var isDraggingLayer = false
    @State private var expandedTrackKinds: Set<TimelineTrack.Kind> = []
    @State private var dragRows: [TimelineTrack]?

    private static let timelineLabelWidth: CGFloat = 136
    private static let timelineRulerHeight: CGFloat = 26
    private static let timelineTrackHeight: CGFloat = 38
    private static let timelineTrackSpacing: CGFloat = 6
    private static let timelinePointsPerSecond: CGFloat = 48

    private var selectedClickID: UUID? {
        guard case let .click(id) = selection else { return nil }
        return id
    }

    private var selectedSubtitleID: UUID? {
        guard case let .subtitle(id) = selection else { return nil }
        return id
    }

    private var selectedNarrationID: UUID? {
        guard case let .narration(id) = selection else { return nil }
        return id
    }

    private var selectedClipID: UUID? {
        guard case let .clip(id) = selection else { return nil }
        return id
    }

    private var selectedEffectID: UUID? {
        guard case let .effect(id) = selection else { return nil }
        return id
    }

    private var selectedSuggestionID: UUID? {
        guard case let .suggestion(id) = selection else { return nil }
        return id
    }

    private var selectedClip: VideoClip? {
        project.clips.first { $0.id == selectedClipID }
    }

    /// Binds one immutable raw video to the project's independently editable timeline layers.
    init(
        store: AppStore,
        project: Binding<DemoProject>,
        videoURL: URL,
        duration: Double
    ) {
        self.store = store
        self.videoURL = videoURL
        _project = project
        _playbackOwner = StateObject(
            wrappedValue: VideoPlaybackOwner(
                url: videoURL,
                project: project.wrappedValue
            )
        )
    }

    var body: some View {
        Group {
            if let message = playbackError {
                ContentUnavailableView(
                    "Preview unavailable", systemImage: "video.slash",
                    description: Text(message)
                )
            } else {
                GeometryReader { proxy in
                    if proxy.size.width < 820 {
                        compactLayout
                    } else {
                        regularLayout(height: proxy.size.height)
                    }
                }
            }
        }
        .sheet(item: $editingNarration) { layer in
            TimelineNarrationEditor(store: store, projectID: project.id, layer: layer)
        }
        .sheet(isPresented: $isInspectorPresented) {
            PlaybackDrivenView(playback: playback) { _ in inspector }
                .frame(width: 360, height: 520)
        }
        .onReceive(playback.$errorMessage.removeDuplicates()) { playbackError = $0 }
        .onDisappear {
            playback.player.pause()
            layerDrag.cancel()
            audioModel.cancel()
            dragRows = nil
        }
        .onChange(of: project.id) { _, _ in
            layerDrag.cancel()
            audioModel.cancel()
            dragRows = nil
            expandedTrackKinds = []
            previewLayout = TimelinePreviewLayout()
            isPlacingClick = false
        }
        .onChange(of: isDraggingLayer) { _, active in
            if !active {
                layerDrag.cancel()
                dragRows = nil
            }
        }
        .onChange(of: PlaybackCompositionState(project: project)) {
            playback.rebuild(url: videoURL, project: project)
        }
        .onChange(of: audioModel.selectedLayerID) { _, id in
            selection = id.map(TimelineLayerSelection.narration)
        }
        .onReceive(NotificationCenter.default.publisher(for: .storybirdOpenProjectAudio)) { notification in
            if notification.object as? UUID == project.id { showAudioComposer = true }
        }
        .onChange(of: selection) { _, _ in
            audioModel.cancelAdjustment()
        }
    }

    /// Gives AppKit's horizontal split an explicit height instead of its content's ideal size.
    private func regularLayout(height: CGFloat) -> some View {
        HSplitView {
            editingWorkspace(compact: false)
                .frame(minWidth: 460)
                .frame(height: height)

            Group {
                if showAudioComposer { audioPanel }
                else { PlaybackDrivenView(playback: playback) { _ in inspector } }
            }
            .frame(minWidth: 250, idealWidth: 280, maxWidth: 340)
            .frame(height: height)
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    isInspectorPresented = true
                } label: {
                    Label("Inspector", systemImage: "slider.horizontal.3")
                }
                .disabled(selection == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            editingWorkspace(compact: true)
        }
    }

    private var audioPanel: some View {
        PlaybackDrivenView(playback: playback) { playback in
            TimelineAudioPanel(store: store, model: audioModel, projectID: project.id, playhead: playback.currentTime)
        }
    }

    /// Budgets the compact audio panel before the split, preserving playback and layer access.
    private func editingWorkspace(compact: Bool) -> some View {
        GeometryReader { proxy in
            let audioHeight: CGFloat = compact && showAudioComposer
                ? min(190, max(80, proxy.size.height * 0.24)) : 0
            let toolsHeight: CGFloat = selectedNarrationID == nil ? 160 : 204
            TimelinePreviewSplitView(
                layout: $previewLayout,
                minimumTimelineHeight: toolsHeight + 48 + audioHeight
            ) {
                PlaybackDrivenView(playback: playback) { _ in playerStage }
            } timeline: {
                VStack(spacing: 0) {
                    PlaybackDrivenView(playback: playback) { _ in playbackControls }.frame(height: 48)
                    if compact && showAudioComposer {
                        audioPanel.frame(height: audioHeight)
                        Divider()
                    }
                    timeline
                }
            }
        }
    }

    private var playerStage: some View {
        GeometryReader { proxy in
            let camera = activeCamera
            let frame = AspectFit.frame(
                contentSize: CGSize(
                    width: project.recording?.width ?? 1,
                    height: project.recording?.height ?? 1
                ),
                in: CGRect(origin: .zero, size: proxy.size)
            )
            ZStack(alignment: .topLeading) {
                Color(nsColor: .controlBackgroundColor)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.black)
                        .frame(
                            width: frame.width,
                            height: frame.height
                        )
                        .position(x: frame.midX, y: frame.midY)
                    VideoPlayerSurface(player: playback.player)
                        .frame(
                            width: frame.width,
                            height: frame.height
                        )
                        .position(x: frame.midX, y: frame.midY)
                        .clipShape(
                            RoundedRectangle(cornerRadius: 10)
                        )
                    if isPlacingClick {
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .frame(
                                width: frame.width,
                                height: frame.height
                            )
                            .position(x: frame.midX, y: frame.midY)
                            .gesture(
                                SpatialTapGesture()
                                    .onEnded { value in
                                        addClickCue(
                                            at: value.location,
                                            in: frame.size
                                        )
                                    }
                            )
                    }
                }
                .scaleEffect(
                    CGFloat(camera.scale),
                    anchor: UnitPoint(
                        x: (frame.minX + CGFloat(camera.x) * frame.width) / max(proxy.size.width, 1),
                        y: (frame.minY + CGFloat(camera.y) * frame.height) / max(proxy.size.height, 1)
                    )
                )
                VideoOverlayCanvas(
                    project: project, time: playback.currentTime,
                    imageFrame: frame, camera: camera
                )
                VideoScreenOverlayCanvas(
                    project: project,
                    time: playback.currentTime,
                    imageFrame: frame
                )
                if isPlacingClick {
                    Text("Click a point in the video")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .position(
                            x: proxy.size.width / 2,
                            y: 34
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button {
                previewLayout.toggleVisibility()
                if previewLayout.visibility == .hidden { isPlacingClick = false }
            } label: {
                Label(
                    previewLayout.visibility == .hidden ? "Show Preview" : "Hide Preview",
                    systemImage: previewLayout.visibility == .hidden ? "video" : "video.slash"
                )
            }
            .accessibilityIdentifier("timeline-preview-toggle")
            Button {
                playback.togglePlayback()
            } label: {
                Image(
                    systemName: playback.isPlaying
                        ? "pause.fill"
                        : "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("timeline-playback-toggle")

            Slider(
                value: Binding(
                    get: { playback.currentTime },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(playback.duration, 0.001)
            )
            .accessibilityLabel("Playhead")

            Text(
                "\(Self.time(playback.currentTime)) / \(Self.time(playback.duration))"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 104, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var activeCamera: VideoCameraPresentation {
        VideoOverlayPresentation.camera(
            in: project,
            at: playback.currentTime
        )
    }

    /// Budgets toolbar, padding, and the scroll viewport together so the final
    /// row stays reachable even below the compact layout's inspector control.
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlaybackDrivenView(playback: playback) { _ in timelineToolbar }
                .fixedSize(horizontal: false, vertical: true)
            if let layer = project.narrations.first(where: { $0.id == selectedNarrationID }) {
                PlaybackDrivenView(playback: playback) { playback in
                    TimelineAudioToolbar(
                        model: audioModel, store: store, project: project, layer: layer, playhead: playback.currentTime,
                        onEditText: { editingNarration = layer },
                        onInspector: { isInspectorPresented = true }
                    )
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView(.vertical) { timelineTrackEditor }
                .frame(maxHeight: .infinity)
                .scrollIndicators(.visible)

            if project.clips.isEmpty
                && project.clicks.isEmpty
                && project.subtitles.isEmpty
                && project.narrations.isEmpty
                && project.effects.isEmpty
                && project.suggestions.isEmpty {
                Text("Recorded clips and layers will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.bar.opacity(0.65))
    }

    private var timelineToolbar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Text("Timeline layers")
                    .font(.headline)
                ClickCueReviewMenu(clicks: project.clicks) { id in
                    selection = .click(id)
                    isInspectorPresented = true
                }
                Button {
                    showAudioComposer.toggle()
                } label: {
                    Label(showAudioComposer ? "Close Audio" : "Add Audio", systemImage: "waveform.badge.plus")
                }
                .accessibilityIdentifier("timeline-audio-toggle")
                Menu("Source Audio") {
                    Toggle("Mute original audio", isOn: $project.sourceAudioMuted)
                    Button("Original volume") { project.sourceAudioVolume = 1 }
                    Button("Half volume") { project.sourceAudioVolume = 0.5 }
                    TextField("Volume", value: $project.sourceAudioVolume, format: .number)
                }

                if selectedClip != nil {
                    Divider()
                        .frame(height: 20)
                    Button {
                        splitSelectedClip()
                    } label: {
                        Label("Split", systemImage: "scissors")
                    }
                    .disabled(!canSplitSelectedClip)

                    Menu {
                        Button("Remove before playhead") {
                            trimSelectedClip(beforePlayhead: true)
                        }
                        .disabled(!canTrimSelectedClipBeforePlayhead)
                        Button("Remove after playhead") {
                            trimSelectedClip(beforePlayhead: false)
                        }
                        .disabled(!canTrimSelectedClipAfterPlayhead)
                    } label: {
                        Label("Trim", systemImage: "crop")
                    }
                    .disabled(selectedClip?.kind != .video)

                    Menu {
                        Button("1× Normal") { setSelectedClipSpeed(1) }
                        Button("2× Faster") { setSelectedClipSpeed(2) }
                        Button("4× Faster") { setSelectedClipSpeed(4) }
                    } label: {
                        Label(
                            selectedClip.map {
                                Self.speed($0.playbackRate)
                            } ?? "Speed",
                            systemImage: "gauge.with.dots.needle.67percent"
                        )
                    }
                    .disabled(selectedClip?.kind != .video)

                    Button(role: .destructive) {
                        deleteSelectedClip()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }

                Spacer(minLength: 12)

                Button {
                    do {
                        project = try store.undo(projectID: project.id)
                    } catch {
                        store.errorMessage = error.localizedDescription
                    }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                Button {
                    do {
                        project = try store.redo(projectID: project.id)
                    } catch {
                        store.errorMessage = error.localizedDescription
                    }
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                Menu("Add") {
                    Button("Split selected clip") {
                        splitSelectedClip()
                    }
                    .disabled(!canSplitSelectedClip)
                    Button("Freeze current frame") {
                        addFreeze()
                    }
                    .disabled(selectedClipSourceTimeAtPlayhead == nil)
                    Divider()
                    Button("Spotlight") { addEffect(.spotlight) }
                    Button("Pan & Zoom") { addEffect(.panZoom) }
                    Button("Title Card") { addEffect(.title) }
                    Button("CTA Card") { addEffect(.cta) }
                }
                Button {
                    addSubtitle()
                } label: {
                    Label("Add Subtitle", systemImage: "captions.bubble")
                }
                Button {
                    isPlacingClick.toggle()
                    if isPlacingClick {
                        previewLayout.visibility = .visible
                        playback.player.pause()
                    }
                } label: {
                    Label(
                        isPlacingClick ? "Cancel Click" : "Add Click",
                        systemImage: isPlacingClick
                            ? "xmark.circle"
                            : "cursorarrow.click.badge.clock"
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var timelineTrackEditor: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: Self.timelineTrackSpacing) {
                Color.clear
                    .frame(height: Self.timelineRulerHeight)
                ForEach(timelineRows) { row in
                    timelineTrackLabel(row)
                }
            }
            .frame(width: Self.timelineLabelWidth)
            .padding(.trailing, 8)

            Divider()

            ScrollView(.horizontal) {
                timelineCanvas(width: timelineCanvasWidth)
            }
            .scrollIndicators(.visible)
        }
        .frame(height: timelineCanvasHeight)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.45),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// The first row of each layer kind doubles as its disclosure control.
    /// Toggling local view state never enters project persistence or undo.
    private func timelineTrackLabel(_ row: TimelineTrack) -> some View {
        Group {
            if row.isGroupHeader {
                let expanded = expandedTrackKinds.contains(row.kind)
                Button {
                    if expanded { expandedTrackKinds.remove(row.kind) }
                    else { expandedTrackKinds.insert(row.kind) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .frame(width: 12)
                        Text(row.title).fontWeight(.semibold).lineLimit(1)
                        Spacer(minLength: 2)
                        Text("\(row.groupCount)").font(.caption2.monospacedDigit())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(row.groupCount == 0 || layerDrag.target != nil)
                .accessibilityIdentifier("timeline-toggle-\(row.kind.rawValue)")
                .accessibilityLabel("\(expanded ? "Compact" : "Expand") \(row.title)")
                .accessibilityValue(expanded ? "Individual rows" : "Automatic rows")
                .help(expanded ? "Group non-overlapping layers into shared rows" : "Show each layer on its own row")
            } else {
                HStack(spacing: 6) {
                    Image(systemName: row.symbol).frame(width: 16)
                    Text(row.title).lineLimit(1)
                    Spacer(minLength: 2)
                    Text("\(row.spans.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .frame(height: Self.timelineTrackHeight)
        .padding(.leading, 8)
    }

    /// Renders labels and blocks from the same row inventory so overlapping
    /// layers remain independently reachable while both scroll axes stay aligned.
    private func timelineCanvas(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: Self.timelineTrackSpacing) {
                timelineRuler(width: width)
                ForEach(timelineRows) { row in
                    timelineTrackRow {
                        ForEach(row.spans) { span in
                            layerBlock(row: row, span: span, width: width)
                        }
                        if row.kind == .narration, row.isGroupHeader,
                           let reference = audioModel.dragging, let time = audioModel.dropTime,
                           let duration = audioModel.duration(of: reference, in: project) {
                            let valid = time + duration <= timelineSnapshot.duration
                            RoundedRectangle(cornerRadius: 6)
                                .fill(valid ? Color.cyan.opacity(0.3) : Color.red.opacity(0.3))
                                .overlay(Text("\(time, format: .number.precision(.fractionLength(2)))s")
                                    .font(.caption).lineLimit(1))
                                .frame(width: max(18, duration / max(timelineSnapshot.duration, 0.001) * width), height: 38)
                                .offset(x: time / max(timelineSnapshot.duration, 0.001) * width)
                                .allowsHitTesting(false)
                        }
                    }
                    .onDrop(of: row.kind == .narration ? [TimelineAudioReference.contentType] : [],
                        delegate: TimelineAudioDropDelegate(model: audioModel, store: store, project: project, width: width))
                }
            }
            PlaybackDrivenView(playback: playback) { playback in
                let playheadX = timelineX(for: playback.currentTime, width: width)
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: timelineCanvasHeight)
                    .offset(x: playheadX)
                    .allowsHitTesting(false)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .offset(x: playheadX - 3, y: 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: timelineCanvasHeight)
        .coordinateSpace(name: "timeline-layer-canvas")
    }

    /// Shares block selection and timing movement across editable layer kinds.
    /// Video clips and suggestions retain their existing selection-only behavior.
    @ViewBuilder
    private func layerBlock(row: TimelineTrack, span: TimelineTrackSpan, width: CGFloat) -> some View {
        if row.kind == .narration, let layer = timelineSnapshot.narrations[span.id] {
            PlaybackDrivenView(playback: playback) { playback in
                TimelineAudioBlock(
                    store: store, model: audioModel, move: layerDrag, project: project, layer: layer,
                    canvasWidth: width, selected: selectedNarrationID == layer.id, playhead: playback.currentTime,
                    onSelect: { audioModel.selectedLayerID = layer.id; selection = .narration(layer.id) },
                    onEditText: {
                        if layer.voiceProfileID != nil { editingNarration = layer }
                        else { isInspectorPresented = true }
                    },
                    onBegin: { dragRows = timelineRows; playback.player.pause() },
                    onEnd: { dragRows = nil }
                )
            }
        } else {
            let selected = layerSelection(kind: row.kind, id: span.id)
            let target = movableLayer(kind: row.kind, id: span.id)
            let delta = target != nil && layerDrag.target == target ? layerDrag.delta : 0
            let displayed = TimelineTrackSpan(id: span.id, start: span.start + delta, end: span.end + delta)
            timelineBlock(
                title: layerTitle(row: row, id: span.id), systemImage: row.symbol,
                span: displayed, canvasWidth: width, color: layerColor(row.kind),
                isSelected: selection == selected,
                dragTarget: target,
                usesSharedRows: row.kind.supportsExpansion && !expandedTrackKinds.contains(row.kind)
            ) {
                selection = selected
                playback.seek(to: row.kind == .click
                    ? timelineSnapshot.clicks[span.id]?.time ?? span.start
                    : span.start)
            }
            .zIndex(target != nil && layerDrag.target == target ? 1 : 0)
        }
    }

    /// Maps a visible row to the existing inspector selection, preserving every
    /// layer's editing controls in compact and wide layouts.
    private func layerSelection(kind: TimelineTrack.Kind, id: UUID) -> TimelineLayerSelection {
        switch kind {
        case .video: .clip(id)
        case .click: .click(id)
        case .subtitle: .subtitle(id)
        case .narration: .narration(id)
        case .effect: .effect(id)
        case .suggestion: .suggestion(id)
        }
    }

    /// Limits free horizontal timing moves to layers; video sequencing and
    /// suggestion application remain separate editing actions.
    private func movableLayer(kind: TimelineTrack.Kind, id: UUID) -> TimelineLayerTarget? {
        switch kind {
        case .video, .suggestion: nil
        case .click: .click(id)
        case .subtitle: .subtitle(id)
        case .narration: .narration(id)
        case .effect: .effect(id)
        }
    }

    /// Keeps each block identifiable by its content rather than only its kind.
    private func layerTitle(row: TimelineTrack, id: UUID) -> String {
        let snapshot = timelineSnapshot
        switch row.kind {
        case .video:
            guard let clip = snapshot.clips[id] else { return row.title }
            return clip.kind == .freeze ? "Freeze" : "Clip · \(Self.speed(clip.playbackRate))"
        case .click:
            guard let click = snapshot.clicks[id] else { return row.title }
            let name = click.button == .right ? "Right click" : "Click"
            return click.isComplete ? name : "\(name) · Incomplete"
        case .subtitle:
            let text = snapshot.subtitles[id]?.text ?? ""
            return text.isEmpty ? row.title : text
        case .narration:
            return snapshot.narrations[id]?.name ?? row.title
        case .effect:
            return snapshot.effects[id]?.displayName ?? row.title
        case .suggestion:
            return snapshot.suggestions[id]?.state.rawValue.capitalized ?? row.title
        }
    }

    /// Retains the existing color cues as layers gain independent rows.
    private func layerColor(_ kind: TimelineTrack.Kind) -> Color {
        switch kind {
        case .video: .blue
        case .click: .orange
        case .subtitle: .green
        case .narration: .cyan
        case .effect: .purple
        case .suggestion: .pink
        }
    }

    private func timelineRuler(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(timelineTickValues, id: \.self) { second in
                let x = timelineX(for: Double(second), width: width)
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 1, height: 7)
                    .offset(x: x)
                Text(Self.shortTime(Double(second)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .offset(x: x + 4, y: 7)
            }
        }
        .frame(width: width, height: Self.timelineRulerHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged {
                    playback.seek(
                        to: timelineTime(for: $0.location.x, width: width)
                    )
                }
        )
    }

    private func timelineTrackRow<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.055))
            content()
        }
        .frame(height: Self.timelineTrackHeight)
    }

    /// Previews a length-preserving translation and commits once on release.
    /// Canvas coordinates prevent the moving block from changing gesture distance.
    private func timelineBlock(
        title: String,
        systemImage: String,
        span: TimelineTrackSpan,
        canvasWidth: CGFloat,
        color: Color,
        isSelected: Bool,
        dragTarget: TimelineLayerTarget? = nil,
        usesSharedRows: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let scale = canvasWidth / max(timelineSnapshot.duration, 0.001)
        let x = CGFloat(span.start) * scale
        let width = max(CGFloat(span.end - span.start) * scale, usesSharedRows ? 1 : 30)

        return Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
                    .lineLimit(1)
            }
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .frame(width: width, height: Self.timelineTrackHeight - 8)
            .contentShape(Rectangle())
            .clipped()
            .background(
                color.opacity(isSelected ? 0.34 : 0.18),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected ? Color.accentColor : color.opacity(0.55),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .offset(x: x)
        .accessibilityIdentifier("timeline-layer-\(span.id.uuidString)")
        .simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("timeline-layer-canvas"))
                .updating($isDraggingLayer) { _, active, _ in
                    if dragTarget != nil { active = true }
                }
                .onChanged { value in
                    guard let dragTarget else { return }
                    if layerDrag.target == nil {
                        dragRows = timelineRows
                        action()
                        playback.player.pause()
                    }
                    layerDrag.update(
                        target: dragTarget, translation: value.translation.width,
                        canvasWidth: canvasWidth, project: project
                    )
                }
                .onEnded { value in
                    guard let dragTarget else { return }
                    layerDrag.update(
                        target: dragTarget, translation: value.translation.width,
                        canvasWidth: canvasWidth, project: project
                    )
                    layerDrag.finish(in: store)
                    dragRows = nil
                },
            including: dragTarget == nil ? .none : .all
        )
        .help(
            "\(title) · \(Self.time(span.start))–\(Self.time(span.end))"
                + (dragTarget == nil ? "" : " · Drag to move")
        )
    }

    private var timelineCanvasWidth: CGFloat {
        max(
            720,
            CGFloat(max(timelineSnapshot.duration, 1))
                * Self.timelinePointsPerSecond
        )
    }

    private var timelineCanvasHeight: CGFloat {
        let count = CGFloat(timelineRows.count)
        return Self.timelineRulerHeight
            + Self.timelineTrackHeight * count
            + Self.timelineTrackSpacing * count
    }

    private var timelineRows: [TimelineTrack] {
        dragRows ?? timelineSnapshot.rows
    }

    private var timelineSnapshot: TimelineTrackSnapshot {
        trackCache.snapshot(project: project, expandedKinds: expandedTrackKinds)
    }

    private var timelineTickValues: [Int] {
        let duration = max(timelineSnapshot.duration, 0)
        let interval: Int
        if duration <= 30 {
            interval = 1
        } else if duration <= 120 {
            interval = 5
        } else {
            interval = 10
        }
        return Array(
            stride(
                from: 0,
                through: Int(ceil(duration)),
                by: interval
            )
        )
    }

    private func timelineX(for time: Double, width: CGFloat) -> CGFloat {
        CGFloat(
            min(
                max(time / max(timelineSnapshot.duration, 0.001), 0),
                1
            )
        ) * width
    }

    private func timelineTime(for x: CGFloat, width: CGFloat) -> Double {
        Double(min(max(x / max(width, 1), 0), 1))
            * timelineSnapshot.duration
    }

    private var inspector: some View {
        Group {
            if let index = project.clips.firstIndex(where: {
                $0.id == selectedClipID
            }) {
                ClipLayerInspector(
                    clip: $project.clips[index],
                    canMoveLeft: index > 0,
                    canMoveRight: index + 1 < project.clips.count,
                    onMoveLeft: {
                        moveClip(at: index, to: index - 1)
                    },
                    onMoveRight: {
                        moveClip(at: index, to: index + 1)
                    },
                    onDelete: {
                        deleteSelectedClip()
                    }
                )
            } else if let index = project.clicks.firstIndex(where: {
                $0.id == selectedClickID
            }) {
                ClickLayerInspector(
                    click: $project.clicks[index],
                    duration: playback.duration,
                    onDelete: {
                        project.clicks.remove(at: index)
                        selection = nil
                    }
                )
            } else if let index = project.subtitles.firstIndex(where: {
                $0.id == selectedSubtitleID
            }) {
                LayerTimingPicker(
                    anchor: $project.subtitles[index].sceneAnchor,
                    time: project.subtitles[index].startTime,
                    project: project,
                    onError: { store.errorMessage = $0.localizedDescription }
                )
                SubtitleLayerInspector(
                    subtitle: $project.subtitles[index],
                    duration: playback.duration,
                    onDelete: {
                        project.subtitles.remove(at: index)
                        selection = nil
                    }
                )
            } else if let index = project.narrations.firstIndex(where: {
                $0.id == selectedNarrationID
            }) {
                LayerTimingPicker(
                    anchor: $project.narrations[index].sceneAnchor,
                    time: project.narrations[index].startTime,
                    project: project,
                    onError: { store.errorMessage = $0.localizedDescription }
                )
                NarrationLayerInspector(
                    narration: $project.narrations[index],
                    onSplit: {
                        do { project = try AudioLayerEditor.split(layerID: project.narrations[index].id, in: project, at: playback.currentTime) }
                        catch { store.errorMessage = error.localizedDescription }
                    },
                    onDuplicate: {
                        do { project = try AudioLayerEditor.duplicate(layerID: project.narrations[index].id, in: project) }
                        catch { store.errorMessage = error.localizedDescription }
                    },
                    onRegenerate: { replacementText, replacementLanguage in
                        let narrationID = project.narrations[index].id
                        let expectedRevision = project.revision
                        do {
                            project = try await store.updateNarration(
                                projectID: project.id,
                                narrationID: narrationID,
                                expectedRevision: expectedRevision,
                                text: replacementText,
                                language: replacementLanguage
                            )
                        } catch {
                            store.errorMessage = error.localizedDescription
                        }
                    },
                    onDelete: {
                        do {
                            project = try store.deleteNarration(
                                projectID: project.id,
                                narrationID: project.narrations[index].id,
                                expectedRevision: project.revision
                            )
                            selection = nil
                        } catch {
                            store.errorMessage = error.localizedDescription
                        }
                    }
                )
            } else if let index = project.effects.firstIndex(where: {
                $0.id == selectedEffectID
            }) {
                EffectLayerInspector(
                    effect: $project.effects[index],
                    onDelete: {
                        do {
                            project = try DemoEffectEditor.delete(
                                project.effects[index].id,
                                from: project
                            )
                            selection = nil
                        } catch {
                            store.errorMessage = error.localizedDescription
                        }
                    }
                )
            } else if let index = project.suggestions.firstIndex(where: {
                $0.id == selectedSuggestionID
            }) {
                SuggestionInspector(
                    suggestion: $project.suggestions[index],
                    onApply: {
                        do {
                            project = try ClickSuggestionGenerator.apply(
                                project.suggestions[index].id,
                                to: project
                            )
                            selection = nil
                        } catch {
                            store.errorMessage = error.localizedDescription
                        }
                    },
                    onReject: {
                        do {
                            project = try ClickSuggestionGenerator.reject(
                                project.suggestions[index].id,
                                in: project
                            )
                            selection = nil
                        } catch {
                            store.errorMessage = error.localizedDescription
                        }
                    }
                )
            } else {
                ContentUnavailableView(
                    "Select a layer",
                    systemImage: "timeline.selection",
                    description: Text(
                        "Choose a clip, Click Cue, subtitle, or effect."
                    )
                )
            }
        }
        .background(.bar.opacity(0.5))
    }

    private func moveClip(at index: Int, to destination: Int) {
        guard project.clips.indices.contains(index) else { return }
        do {
            project = try VideoTimelineEditor.move(
                project: project,
                clipID: project.clips[index].id,
                destination: destination
            )
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private var selectedClipSourceTimeAtPlayhead: Double? {
        guard let selectedClipID else { return nil }
        for item in VideoTimelineSchedule(project: project).items {
            guard case let .clip(value) = item,
                  value.clip.id == selectedClipID,
                  playback.currentTime >= value.projectStart,
                  playback.currentTime <= value.projectEnd,
                  value.clip.kind == .video
            else {
                continue
            }
            return value.clip.sourceStart
                + (playback.currentTime - value.projectStart)
                    * value.clip.playbackRate
        }
        return nil
    }

    private var canSplitSelectedClip: Bool {
        guard let clip = selectedClip,
              let sourceTime = selectedClipSourceTimeAtPlayhead
        else {
            return false
        }
        return sourceTime > clip.sourceStart + 0.001
            && sourceTime < clip.sourceEnd - 0.001
    }

    private var canTrimSelectedClipBeforePlayhead: Bool {
        canSplitSelectedClip
    }

    private var canTrimSelectedClipAfterPlayhead: Bool {
        canSplitSelectedClip
    }

    private func trimSelectedClip(beforePlayhead: Bool) {
        guard let clip = selectedClip,
              let sourceTime = selectedClipSourceTimeAtPlayhead
        else {
            return
        }
        do {
            project = try VideoTimelineEditor.trim(
                project: project,
                clipID: clip.id,
                sourceStart: beforePlayhead ? sourceTime : clip.sourceStart,
                sourceEnd: beforePlayhead ? clip.sourceEnd : sourceTime
            )
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func setSelectedClipSpeed(_ rate: Double) {
        guard let selectedClipID else { return }
        do {
            project = try VideoTimelineEditor.setSpeed(
                project: project,
                clipID: selectedClipID,
                rate: rate
            )
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func deleteSelectedClip() {
        guard let selectedClipID else { return }
        do {
            project = try VideoTimelineEditor.delete(
                project: project,
                clipID: selectedClipID
            )
            selection = nil
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    /// Adds one bounded subtitle at the playhead so invalid time ranges never reach persistence.
    private func addSubtitle() {
        let duration = playback.duration
        guard duration > 0 else { return }
        let start = min(playback.currentTime, max(duration - 0.1, 0))
        let end = min(max(start + 2, start + 0.1), duration)
        let subtitle = TimedSubtitle(
            startTime: start,
            endTime: end,
            text: "New subtitle",
            sceneAnchor: try? SceneTiming.anchor(at: start, in: project)
        )
        project.subtitles.append(subtitle)
        selection = .subtitle(subtitle.id)
    }

    /// Places one incomplete Click Cue at the selected visible frame coordinate,
    /// preserving its source-time identity for later non-destructive edits.
    private func addClickCue(
        at location: CGPoint,
        in videoSize: CGSize
    ) {
        guard videoSize.width > 0, videoSize.height > 0 else { return }
        let existingIDs = Set(project.clicks.map(\.id))
        do {
            project = try VideoTimelineEditor.addClickCue(
                to: project,
                at: playback.currentTime,
                x: min(max(location.x / videoSize.width, 0), 1),
                y: min(max(location.y / videoSize.height, 0), 1)
            )
            selection = project.clicks.first {
                !existingIDs.contains($0.id)
            }.map { .click($0.id) }
            isPlacingClick = false
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private enum NewEffectKind {
        case spotlight
        case panZoom
        case title
        case cta
    }

    /// Splits the selected source clip at the frame represented by the project playhead.
    private func splitSelectedClip() {
        guard let selectedClipID,
              let sourceTime = selectedClipSourceTimeAtPlayhead
        else { return }
        do {
            let edited = try VideoTimelineEditor.split(
                project: project,
                clipID: selectedClipID,
                sourceTime: sourceTime
            )
            project = edited
            selection = edited.clips.first {
                $0.kind == .video
                    && abs($0.sourceStart - sourceTime) <= 0.001
            }.map { .clip($0.id) }
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    /// Inserts one editable one-second freeze segment after the selected clip.
    private func addFreeze() {
        guard let selectedClipID,
              let sourceTime = selectedClipSourceTimeAtPlayhead
        else { return }
        do {
            let existingIDs = Set(project.clips.map(\.id))
            let edited = try VideoTimelineEditor.insertFreeze(
                project: project,
                after: selectedClipID,
                sourceTime: sourceTime,
                duration: 1
            )
            project = edited
            selection = edited.clips.first {
                !existingIDs.contains($0.id)
            }.map { .clip($0.id) }
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    /// Adds one contract-valid effect draft at the playhead for immediate inspector editing.
    private func addEffect(_ kind: NewEffectKind) {
        let start = min(playback.currentTime, max(timelineSnapshot.duration - 0.1, 0))
        let end = min(max(start + 1, start + 0.1), timelineSnapshot.duration)
        let effect: DemoEffect
        switch kind {
        case .spotlight:
            effect = .spotlight(
                SpotlightEffect(
                    startTime: start,
                    endTime: end,
                    x: 0.35,
                    y: 0.35,
                    width: 0.3,
                    height: 0.3
                )
            )
        case .panZoom:
            effect = .panZoom(
                PanZoomEffect(
                    startTime: start,
                    endTime: end,
                    endX: 0.5,
                    endY: 0.5,
                    endScale: 1.5
                )
            )
        case .title:
            do {
                project = try DemoEffectEditor.insertTitle(
                    in: project,
                    after: selectedClipID
                )
                selection = project.effects.last.map {
                    .effect($0.id)
                }
            } catch {
                store.errorMessage = error.localizedDescription
            }
            return
        case .cta:
            do {
                project = try DemoEffectEditor.insertCTA(in: project)
                selection = project.effects.last.map {
                    .effect($0.id)
                }
            } catch {
                store.errorMessage = error.localizedDescription
            }
            return
        }
        let anchored = VideoTimelineEditor.anchorContentEffect(
            effect,
            in: project,
            at: playback.currentTime
        )
        project.effects.append(anchored)
        selection = .effect(anchored.id)
    }

    /// Formats a project-time value without depending on locale-specific media controls.
    private static func time(_ seconds: Double) -> String {
        let bounded = max(seconds, 0)
        let minutes = Int(bounded) / 60
        let remainder = bounded - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, remainder)
    }

    private static func shortTime(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func speed(_ rate: Double) -> String {
        if abs(rate.rounded() - rate) <= 0.001 {
            return "\(Int(rate.rounded()))×"
        }
        return String(format: "%.2g×", rate)
    }
}

struct VideoOverlayCanvas: View {
    let project: DemoProject
    let time: Double
    let imageFrame: CGRect
    var camera: VideoCameraPresentation = .identity

    var body: some View {
        let metrics = VideoOverlayMetrics(frameSize: imageFrame.size)
        ZStack(alignment: .topLeading) {
            ForEach(project.clicks.filter {
                $0.indicator.startTime <= time
                    && time <= $0.indicator.endTime
            }) { click in
                let presentation = VideoOverlayPresentation.clickRing(
                    for: click,
                    at: time,
                    camera: camera
                )
                let point = VideoOverlayLayout.clickPoint(
                    x: presentation.point.x,
                    y: presentation.point.y,
                    in: imageFrame,
                    axis: .topDown
                )
                Circle()
                    .fill(Color(hex: click.indicator.colorHex).opacity(0.18))
                    .overlay(
                        Circle()
                            .stroke(
                                Color(hex: click.indicator.colorHex),
                                lineWidth: 3 * camera.scale
                            )
                    )
                    .frame(
                        width: metrics.clickRingDiameter * click.indicator.size
                            * CGFloat(presentation.diameterScale * camera.scale),
                        height: metrics.clickRingDiameter * click.indicator.size
                            * CGFloat(presentation.diameterScale * camera.scale)
                    )
                    .opacity(
                        click.indicator.opacity
                            * presentation.opacityScale
                    )
                    .position(point)
            }

            ForEach(project.clicks.filter {
                !$0.caption.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                    && $0.description.startTime <= time
                    && time <= $0.description.endTime
            }) { click in
                VideoClickCaptionOverlay(
                    click: click,
                    imageFrame: imageFrame,
                    metrics: metrics,
                    camera: camera
                )
            }
        }
        .allowsHitTesting(false)
    }
}

struct VideoScreenOverlayCanvas: View {
    let project: DemoProject
    let time: Double
    let imageFrame: CGRect

    var body: some View {
        let metrics = VideoOverlayMetrics(frameSize: imageFrame.size)
        ZStack {
            ForEach(project.subtitles.filter {
                $0.startTime <= time && time <= $0.endTime
            }) { subtitle in
                VideoSubtitleOverlay(
                    subtitle: subtitle,
                    imageFrame: imageFrame,
                    metrics: metrics
                )
            }
            ForEach(project.clicks.filter {
                $0.cueSubtitle.startTime <= time
                    && time <= $0.cueSubtitle.endTime
                    && !$0.cueSubtitle.text.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
            }) { click in
                VideoSubtitleOverlay(
                    subtitle: TimedSubtitle(
                        id: click.id,
                        startTime: click.cueSubtitle.startTime,
                        endTime: click.cueSubtitle.endTime,
                        text: click.cueSubtitle.text,
                        position: click.cueSubtitle.position,
                        style: click.cueSubtitle.style
                    ),
                    imageFrame: imageFrame,
                    metrics: metrics
                )
            }
            ForEach(activeEffects) { effect in
                switch effect {
                case let .spotlight(value):
                    SpotlightShape(value: value, frame: imageFrame)
                        .fill(
                            Color.black.opacity(value.dimOpacity),
                            style: FillStyle(eoFill: true)
                        )
                case let .title(value):
                    card(
                        title: value.title,
                        secondary: value.subtitle,
                        style: value.style,
                        metrics: metrics
                    )
                case let .cta(value):
                    card(
                        title: value.title,
                        secondary: value.buttonLabel,
                        style: value.style,
                        metrics: metrics
                    )
                case .panZoom:
                    EmptyView()
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var activeEffects: [DemoEffect] {
        project.effects.filter {
            $0.startTime <= time && time <= $0.endTime
        }
    }

    private func card(
        title: String,
        secondary: String,
        style: TextOverlayStyle,
        metrics: VideoOverlayMetrics
    ) -> some View {
        ZStack {
            Color(hex: style.backgroundHex)
                .opacity(style.backgroundOpacity)
            VStack(spacing: 12) {
                Text(title)
                    .font(
                        .system(
                            size: VideoOverlayPresentation
                                .cardTitleFontSize(
                                    style: style,
                                    metrics: metrics
                                ),
                            weight: .bold
                        )
                    )
                if !secondary.isEmpty {
                    Text(secondary)
                        .font(
                            .system(
                                size: VideoOverlayPresentation
                                    .cardSecondaryFontSize(
                                        style: style,
                                        metrics: metrics
                                    ),
                                weight: .semibold
                            )
                        )
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(
                            Color(hex: style.foregroundHex)
                                .opacity(0.15),
                            in: Capsule()
                        )
                }
            }
            .foregroundStyle(Color(hex: style.foregroundHex))
        }
        .frame(width: imageFrame.width, height: imageFrame.height)
        .position(x: imageFrame.midX, y: imageFrame.midY)
    }
}

private struct SpotlightShape: Shape {
    let value: SpotlightEffect
    let frame: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(frame)
        path.addRoundedRect(
            in: CGRect(
                x: frame.minX + CGFloat(value.x) * frame.width,
                y: frame.minY + CGFloat(value.y) * frame.height,
                width: CGFloat(value.width) * frame.width,
                height: CGFloat(value.height) * frame.height
            ),
            cornerSize: CGSize(width: 10, height: 10)
        )
        return path
    }
}

private struct VideoSubtitleOverlay: View {
    let subtitle: TimedSubtitle
    let imageFrame: CGRect
    let metrics: VideoOverlayMetrics

    var body: some View {
        VStack {
            if subtitle.position == .bottom {
                Spacer(minLength: 0)
            }
            VideoOverlayLabel(
                text: subtitle.text,
                style: subtitle.style,
                fontSize: VideoOverlayPresentation.fontSize(
                    style: subtitle.style,
                    metrics: metrics
                ),
                metrics: metrics
            )
            .frame(
                maxWidth: min(
                    metrics.subtitleMaximumWidth,
                    imageFrame.width - metrics.subtitleInset * 2
                )
            )
            if subtitle.position == .top {
                Spacer(minLength: 0)
            }
        }
        .frame(
            width: max(
                imageFrame.width - metrics.subtitleInset * 2,
                0
            ),
            height: max(
                imageFrame.height - metrics.subtitleInset * 2,
                0
            )
        )
        .position(x: imageFrame.midX, y: imageFrame.midY)
    }
}

private struct VideoClickCaptionOverlay: View {
    let click: TimedPointerClick
    let imageFrame: CGRect
    let metrics: VideoOverlayMetrics
    let camera: VideoCameraPresentation
    @State private var labelSize = CGSize(
        width: 1,
        height: 1
    )

    var body: some View {
        let width = min(
            max(metrics.captionMinimumWidth, imageFrame.width * 0.36),
            min(
                metrics.captionMaximumWidth,
                max(imageFrame.width - metrics.edgeInset * 2, 0)
            )
        )

        VideoOverlayLabel(
            text: click.caption,
            style: click.captionStyle,
            fontSize: VideoOverlayPresentation.fontSize(
                style: click.captionStyle,
                metrics: metrics,
                contentScale: camera.scale
            ),
            metrics: metrics
        )
        .frame(width: width)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: VideoCaptionSizeKey.self,
                        value: proxy.size
                    )
            }
        }
        .onPreferenceChange(VideoCaptionSizeKey.self) {
            labelSize = $0
        }
        .scaleEffect(captionScale)
        .position(
            x: captionOrigin.x + fittedLabelSize.width / 2,
            y: captionOrigin.y + fittedLabelSize.height / 2
        )
    }

    private var captionScale: CGFloat {
        VideoOverlayLayout.captionFitScale(labelSize: labelSize, in: imageFrame, metrics: metrics)
    }

    private var fittedLabelSize: CGSize {
        CGSize(width: labelSize.width * captionScale, height: labelSize.height * captionScale)
    }

    private var captionOrigin: CGPoint {
        let point = VideoOverlayPresentation.descriptionPoint(for: click, camera: camera)
        return VideoOverlayLayout.captionOrigin(
            labelSize: fittedLabelSize,
            x: point.x,
            y: point.y,
            in: imageFrame,
            axis: .topDown,
            metrics: metrics
        )
    }
}

private struct VideoCaptionSizeKey: PreferenceKey {
    static let defaultValue = CGSize(width: 1, height: 1)

    static func reduce(
        value: inout CGSize,
        nextValue: () -> CGSize
    ) {
        value = nextValue()
    }
}

private struct VideoOverlayLabel: View {
    let text: String
    let style: TextOverlayStyle
    let fontSize: CGFloat
    let metrics: VideoOverlayMetrics

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(Color(hex: style.foregroundHex))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, metrics.verticalPadding)
            .background(
                Color(hex: style.backgroundHex)
                    .opacity(style.backgroundOpacity),
                in: RoundedRectangle(
                    cornerRadius: metrics.cornerRadius
                )
            )
            .shadow(color: .black.opacity(0.36), radius: 4, y: 2)
    }
}

private struct ClickLayerInspector: View {
    @Binding var click: TimedPointerClick
    let duration: Double
    let onDelete: () -> Void

    var body: some View {
        Form {
            Section("Click") {
                Label(
                    click.isComplete ? "Complete" : ClickCueReviewMenu.missingText(click),
                    systemImage: click.isComplete ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .foregroundStyle(click.isComplete ? Color.secondary : .orange)
                TextField("Time", value: $click.time, format: .number)
                Picker("Button", selection: $click.button) {
                    ForEach(PointerButton.allCases) { button in
                        Text(button.rawValue.capitalized).tag(button)
                    }
                }
                TextField(
                    "Description",
                    text: $click.description.text,
                    axis: .vertical
                )
                    .lineLimit(3)
                TextField(
                    "Subtitle",
                    text: $click.cueSubtitle.text,
                    axis: .vertical
                )
                    .lineLimit(3)
                Slider(value: $click.x, in: 0...1) {
                    Text("Horizontal position")
                }
                Slider(value: $click.y, in: 0...1) {
                    Text("Vertical position")
                }
                TextField(
                    "Indicator start",
                    value: $click.indicator.startTime,
                    format: .number
                )
                TextField(
                    "Indicator end",
                    value: $click.indicator.endTime,
                    format: .number
                )
                ColorPicker(
                    "Indicator",
                    selection: Binding(
                        get: { Color(hex: click.indicator.colorHex) },
                        set: { click.indicator.colorHex = $0.hexRGB }
                    ),
                    supportsOpacity: false
                )
                Slider(value: $click.indicator.size, in: 0.25...3) {
                    Text("Indicator size")
                }
                Slider(value: $click.indicator.opacity, in: 0...1) {
                    Text("Indicator opacity")
                }
            }
            Section("Description timing & position") {
                TextField(
                    "Start",
                    value: $click.description.startTime,
                    format: .number
                )
                TextField(
                    "End",
                    value: $click.description.endTime,
                    format: .number
                )
                Picker("Position", selection: $click.description.position) {
                    ForEach(ClickDescriptionPosition.allCases) { position in
                        Text(position.rawValue.capitalized).tag(position)
                    }
                }
                if click.description.position == .custom {
                    Slider(value: $click.description.x, in: 0...1) {
                        Text("Description X")
                    }
                    Slider(value: $click.description.y, in: 0...1) {
                        Text("Description Y")
                    }
                }
            }
            OverlayStyleEditor(style: $click.description.style)
            Section("Cue subtitle") {
                TextField(
                    "Start",
                    value: $click.cueSubtitle.startTime,
                    format: .number
                )
                TextField(
                    "End",
                    value: $click.cueSubtitle.endTime,
                    format: .number
                )
                Picker("Position", selection: $click.cueSubtitle.position) {
                    ForEach(SubtitlePosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                OverlayStyleEditor(style: $click.cueSubtitle.style)
            }
            Section {
                Button("Delete Click Layer", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ClipLayerInspector: View {
    @Binding var clip: VideoClip
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Form {
            Section("Clip") {
                Picker("Kind", selection: $clip.kind) {
                    Text("Video").tag(VideoClipKind.video)
                    Text("Freeze").tag(VideoClipKind.freeze)
                }
                TextField("Source start", value: $clip.sourceStart, format: .number)
                TextField("Source end", value: $clip.sourceEnd, format: .number)
                if clip.kind == .video {
                    HStack {
                        Button("1×") { clip.playbackRate = 1 }
                        Button("2×") { clip.playbackRate = 2 }
                        Button("4×") { clip.playbackRate = 4 }
                        Spacer()
                        Text(String(format: "%.2g×", clip.playbackRate))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $clip.playbackRate, in: 0.25...4) {
                        Text("Speed")
                    }
                } else {
                    TextField(
                        "Freeze duration",
                        value: $clip.freezeDuration,
                        format: .number
                    )
                }
            }
            Section("Order") {
                Button("Move Earlier", action: onMoveLeft)
                    .disabled(!canMoveLeft)
                Button("Move Later", action: onMoveRight)
                    .disabled(!canMoveRight)
            }
            Section {
                Button("Delete Clip", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
    }
}

private struct EffectLayerInspector: View {
    @Binding var effect: DemoEffect
    let onDelete: () -> Void

    var body: some View {
        Form {
            switch effect {
            case let .spotlight(value):
                SpotlightEditor(
                    value: Binding(
                        get: { value },
                        set: { effect = .spotlight($0) }
                    )
                )
            case let .panZoom(value):
                PanZoomEditor(
                    value: Binding(
                        get: { value },
                        set: { effect = .panZoom($0) }
                    )
                )
            case let .title(value):
                CardEditor(
                    title: "Title card",
                    value: Binding(
                        get: {
                            (value.startTime, value.endTime, value.title, value.subtitle)
                        },
                        set: {
                            effect = .title(
                                TitleCardEffect(
                                    id: value.id,
                                    startTime: $0.0,
                                    endTime: $0.1,
                                    title: $0.2,
                                    subtitle: $0.3,
                                    style: value.style
                                )
                            )
                        }
                    )
                )
                OverlayStyleEditor(
                    style: Binding(
                        get: { value.style },
                        set: {
                            effect = .title(
                                TitleCardEffect(
                                    id: value.id,
                                    startTime: value.startTime,
                                    endTime: value.endTime,
                                    title: value.title,
                                    subtitle: value.subtitle,
                                    style: $0
                                )
                            )
                        }
                    )
                )
            case let .cta(value):
                CardEditor(
                    title: "CTA card",
                    value: Binding(
                        get: {
                            (value.startTime, value.endTime, value.title, value.buttonLabel)
                        },
                        set: {
                            effect = .cta(
                                CTACardEffect(
                                    id: value.id,
                                    startTime: $0.0,
                                    endTime: $0.1,
                                    title: $0.2,
                                    buttonLabel: $0.3,
                                    style: value.style
                                )
                            )
                        }
                    )
                )
                OverlayStyleEditor(
                    style: Binding(
                        get: { value.style },
                        set: {
                            effect = .cta(
                                CTACardEffect(
                                    id: value.id,
                                    startTime: value.startTime,
                                    endTime: value.endTime,
                                    title: value.title,
                                    buttonLabel: value.buttonLabel,
                                    style: $0
                                )
                            )
                        }
                    )
                )
            }
            Section {
                Button("Delete Effect", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SuggestionInspector: View {
    @Binding var suggestion: ClickEditSuggestion
    let onApply: () -> Void
    let onReject: () -> Void

    var body: some View {
        Form {
            Section("Edit suggestion") {
                LabeledContent("State", value: suggestion.state.rawValue)
                TextField(
                    "Split",
                    value: $suggestion.splitTime,
                    format: .number
                )
                Text("Includes a click marker, split, spotlight, and pan & zoom draft.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if suggestion.state == .pending {
                SpotlightEditor(value: $suggestion.spotlight)
                PanZoomEditor(value: $suggestion.panZoom)
                Section {
                    Button("Apply Suggestion", action: onApply)
                    Button(
                        "Reject Suggestion",
                        role: .destructive,
                        action: onReject
                    )
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SpotlightEditor: View {
    @Binding var value: SpotlightEffect

    var body: some View {
        Section("Spotlight") {
            TextField("Start", value: $value.startTime, format: .number)
            TextField("End", value: $value.endTime, format: .number)
            Slider(value: $value.x, in: 0...1) { Text("X") }
            Slider(value: $value.y, in: 0...1) { Text("Y") }
            Slider(value: $value.width, in: 0.01...1) { Text("Width") }
            Slider(value: $value.height, in: 0.01...1) { Text("Height") }
            Slider(value: $value.dimOpacity, in: 0...1) { Text("Dim") }
        }
    }
}

private struct PanZoomEditor: View {
    @Binding var value: PanZoomEffect

    var body: some View {
        Section("Pan & Zoom") {
            TextField("Start", value: $value.startTime, format: .number)
            TextField("End", value: $value.endTime, format: .number)
            Slider(value: $value.startX, in: 0...1) { Text("Start X") }
            Slider(value: $value.startY, in: 0...1) { Text("Start Y") }
            Slider(value: $value.startScale, in: 1...3) {
                Text("Start scale")
            }
            Slider(value: $value.endX, in: 0...1) { Text("End X") }
            Slider(value: $value.endY, in: 0...1) { Text("End Y") }
            Slider(value: $value.endScale, in: 1...3) { Text("End scale") }
        }
    }
}

private struct CardEditor: View {
    let title: String
    @Binding var value: (Double, Double, String, String)

    var body: some View {
        Section(title) {
            TextField("Start", value: $value.0, format: .number)
            TextField("End", value: $value.1, format: .number)
            TextField("Title", text: $value.2)
            TextField("Subtitle / Label", text: $value.3)
        }
    }
}

private struct SubtitleLayerInspector: View {
    @Binding var subtitle: TimedSubtitle
    let duration: Double
    let onDelete: () -> Void

    var body: some View {
        Form {
            Section("Subtitle") {
                TextField("Text", text: $subtitle.text, axis: .vertical)
                    .lineLimit(4)
                TextField(
                    "Start",
                    value: $subtitle.startTime,
                    format: .number.precision(.fractionLength(2))
                )
                TextField(
                    "End",
                    value: $subtitle.endTime,
                    format: .number.precision(.fractionLength(2))
                )
                Picker("Position", selection: $subtitle.position) {
                    ForEach(SubtitlePosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
            }
            OverlayStyleEditor(style: $subtitle.style)
            Section {
                Button("Delete Subtitle", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
    }
}

private struct NarrationLayerInspector: View {
    @Binding var narration: NarrationClip
    let onSplit: () -> Void
    let onDuplicate: () -> Void
    let onRegenerate: (String, String) async -> Void
    let onDelete: () -> Void
    @State private var replacementText: String
    @State private var replacementLanguage: String
    @State private var isRegenerating = false
    @State private var trimStart: Double
    @State private var trimDuration: Double

    init(
        narration: Binding<NarrationClip>,
        onSplit: @escaping () -> Void, onDuplicate: @escaping () -> Void,
        onRegenerate: @escaping (String, String) async -> Void,
        onDelete: @escaping () -> Void
    ) {
        _narration = narration
        self.onSplit = onSplit
        self.onDuplicate = onDuplicate
        _trimStart = State(initialValue: narration.wrappedValue.sourceStart)
        _trimDuration = State(initialValue: narration.wrappedValue.duration)
        self.onRegenerate = onRegenerate
        self.onDelete = onDelete
        _replacementLanguage = State(initialValue: narration.wrappedValue.language)
        _replacementText = State(
            initialValue: narration.wrappedValue.text
        )
    }

    var body: some View {
        Form {
            Section("Audio Layer") {
                TextField("Name", text: $narration.name)
                if narration.voiceProfileID != nil {
                TextField(
                    "Text",
                    text: $replacementText,
                    axis: .vertical
                )
                .lineLimit(4)
                Picker("Language", selection: $replacementLanguage) {
                    ForEach(VoiceLanguage.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value.rawValue)
                    }
                    if VoiceLanguage(rawValue: narration.language) == nil {
                        Text(narration.language).tag(narration.language)
                    }
                }
                Button("Regenerate This Narration") {
                    let text = replacementText
                    isRegenerating = true
                    Task {
                        await onRegenerate(text, replacementLanguage)
                        isRegenerating = false
                    }
                }
                .disabled(
                    isRegenerating
                        || replacementText.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                        || (replacementText == narration.text && replacementLanguage == narration.language)
                )
                }
                TextField(
                    "Start",
                    value: $narration.startTime,
                    format: .number.precision(.fractionLength(2))
                )
                LabeledContent("Duration") {
                    Text(
                        narration.duration,
                        format: .number.precision(.fractionLength(2))
                    )
                }
                TextField("Volume", value: $narration.volume, format: .number)
                Toggle("Mute", isOn: $narration.isMuted)
                TextField("Fade in (s)", value: $narration.fadeIn, format: .number)
                TextField("Fade out (s)", value: $narration.fadeOut, format: .number)
                TextField("Source start (s)", value: $trimStart, format: .number)
                TextField("Use duration (s)", value: $trimDuration, format: .number)
                Button("Apply Trim") {
                    var edited = narration
                    edited.sourceStart = trimStart
                    edited.duration = trimDuration
                    narration = edited
                }
                Button("Split at Playhead", action: onSplit)
                Button("Duplicate Layer", action: onDuplicate)
            }
            Section {
                Button(
                    "Delete Audio Layer",
                    role: .destructive,
                    action: onDelete
                )
            }
        }
        .formStyle(.grouped)
        .onChange(of: narration.id) { _, _ in
            trimStart = narration.sourceStart; trimDuration = narration.duration
            replacementText = narration.text; replacementLanguage = narration.language
        }
        .onChange(of: narration.sourceStart) { _, value in trimStart = value }
        .onChange(of: narration.duration) { _, value in trimDuration = value }
        .onChange(of: narration.language) { _, value in replacementLanguage = value }
        .onChange(of: narration.text) { _, value in
            replacementText = value
        }
    }
}

private struct OverlayStyleEditor: View {
    @Binding var style: TextOverlayStyle

    var body: some View {
        Section("Background") {
            ColorPicker(
                "Color",
                selection: Binding(
                    get: { Color(hex: style.backgroundHex) },
                    set: { style.backgroundHex = $0.hexRGB }
                ),
                supportsOpacity: false
            )
            Slider(value: $style.backgroundOpacity, in: 0...1) {
                Text("Opacity")
            }
            Text(
                style.backgroundOpacity.formatted(
                    .percent.precision(.fractionLength(0))
                )
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            ColorPicker(
                "Text color",
                selection: Binding(
                    get: { Color(hex: style.foregroundHex) },
                    set: { style.foregroundHex = $0.hexRGB }
                ),
                supportsOpacity: false
            )
            Slider(value: $style.fontSize, in: 8...96) {
                Text("Font size")
            }
        }
    }
}

private extension DemoEffect {
    var displayName: String {
        switch self {
        case .spotlight: "Spotlight"
        case .panZoom: "Pan & Zoom"
        case .title: "Title"
        case .cta: "CTA"
        }
    }
}
