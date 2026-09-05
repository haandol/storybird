import AVFoundation
import AVKit
import StorybirdCore
import SwiftUI

private final class VideoTimeObserverBox: @unchecked Sendable {
    weak var player: AVPlayer?
    var token: Any?

    deinit {
        if let token {
            player?.removeTimeObserver(token)
        }
    }
}

private struct VideoPlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    /// Creates a stable AppKit player surface while Storybird owns playback controls.
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    /// Keeps the reusable AppKit view attached to the current project player.
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    /// Detaches media resources when the project view leaves the SwiftUI tree.
    static func dismantleNSView(
        _ view: AVPlayerView,
        coordinator: ()
    ) {
        view.player = nil
    }
}

@MainActor
final class VideoPlaybackModel: ObservableObject {
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double

    let player: AVPlayer
    private let timeObserver = VideoTimeObserverBox()

    /// Creates one player whose periodic observer drives every preview layer on the same clock.
    init(url: URL, project: DemoProject) {
        duration = max(project.timelineDuration, 0)
        player = AVPlayer()
        timeObserver.player = player
        timeObserver.token = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = min(
                    max(CMTimeGetSeconds(time), 0),
                    self.duration
                )
                self.isPlaying = self.player.rate != 0
            }
        }
        rebuild(url: url, project: project)
    }

    /// Replaces the player item with the current non-destructive clip composition.
    func rebuild(url: URL, project: DemoProject) {
        let resumeTime = min(currentTime, project.timelineDuration)
        Task {
            do {
                let result = try await EditedVideoAssetBuilder.build(
                    project: project,
                    sourceURL: url
                )
                player.replaceCurrentItem(
                    with: AVPlayerItem(asset: result.asset)
                )
                duration = max(result.duration, 0)
                seek(to: resumeTime)
            } catch {
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                duration = project.recording?.duration ?? 0
                seek(to: min(resumeTime, duration))
            }
        }
    }

    /// Toggles the raw recording while keeping the overlay clock tied to player time.
    func togglePlayback() {
        if player.rate == 0 {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    /// Seeks the video and overlay preview to one bounded project-time value.
    func seek(to seconds: Double) {
        let bounded = min(max(seconds, 0), duration)
        player.seek(
            to: CMTime(seconds: bounded, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = bounded
    }
}

private enum TimelineLayerSelection: Equatable {
    case clip(UUID)
    case click(UUID)
    case subtitle(UUID)
    case effect(UUID)
    case suggestion(UUID)
}

struct VideoTimelineEditorView: View {
    @ObservedObject var store: AppStore
    @Binding var project: DemoProject

    @StateObject private var playback: VideoPlaybackModel
    private let videoURL: URL
    @State private var selection: TimelineLayerSelection?
    @State private var isInspectorPresented = false

    private var selectedClickID: UUID? {
        guard case let .click(id) = selection else { return nil }
        return id
    }

    private var selectedSubtitleID: UUID? {
        guard case let .subtitle(id) = selection else { return nil }
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
        _playback = StateObject(
            wrappedValue: VideoPlaybackModel(
                url: videoURL,
                project: project.wrappedValue
            )
        )
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width < 820 {
                compactLayout
            } else {
                regularLayout
            }
        }
        .onDisappear {
            playback.player.pause()
        }
        .onChange(of: project.clips) {
            playback.rebuild(url: videoURL, project: project)
        }
    }

    private var regularLayout: some View {
        HSplitView {
            VStack(spacing: 0) {
                playerStage
                Divider()
                timeline
            }
            .frame(minWidth: 460)

            inspector
                .frame(minWidth: 250, idealWidth: 280, maxWidth: 340)
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

            playerStage
            Divider()
            timeline
        }
        .sheet(isPresented: $isInspectorPresented) {
            inspector
                .frame(width: 360, height: 520)
        }
    }

    private var playerStage: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
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
                        VideoOverlayCanvas(
                            project: project,
                            time: playback.currentTime,
                            imageFrame: frame
                        )
                    }
                    .scaleEffect(
                        activeCamera.scale,
                        anchor: UnitPoint(
                            x: activeCamera.x,
                            y: activeCamera.y
                        )
                    )
                    VideoScreenOverlayCanvas(
                        project: project,
                        time: playback.currentTime,
                        imageFrame: frame
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            HStack(spacing: 12) {
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

                Slider(
                    value: Binding(
                        get: { playback.currentTime },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...max(playback.duration, 0.001)
                )

                Text(
                    "\(Self.time(playback.currentTime)) / \(Self.time(playback.duration))"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 104, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var activeCamera: (x: CGFloat, y: CGFloat, scale: CGFloat) {
        guard let effect = project.effects.compactMap({
            if case let .panZoom(value) = $0,
               value.startTime <= playback.currentTime,
               playback.currentTime <= value.endTime {
                return value
            }
            return nil
        }).first else {
            return (0.5, 0.5, 1)
        }
        let progress = min(
            max(
                (playback.currentTime - effect.startTime)
                    / max(effect.endTime - effect.startTime, 0.001),
                0
            ),
            1
        )
        return (
            CGFloat(effect.startX + (effect.endX - effect.startX) * progress),
            CGFloat(effect.startY + (effect.endY - effect.startY) * progress),
            CGFloat(
                effect.startScale
                    + (effect.endScale - effect.startScale) * progress
            )
        )
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Timeline layers")
                    .font(.headline)
                Spacer()
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
                    .disabled(selectedClipID == nil)
                    Button("Freeze current frame") {
                        addFreeze()
                    }
                    .disabled(selectedClipID == nil)
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
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(project.clips) { clip in
                        layerButton(
                            title: clip.kind == .video ? "Video clip" : "Freeze",
                            time: clip.sourceStart,
                            systemImage: "film",
                            isSelected: selectedClipID == clip.id
                        ) {
                            selection = .clip(clip.id)
                        }
                    }

                    ForEach(project.clicks) { click in
                        layerButton(
                            title: click.button == .left
                                ? "Click"
                                : "Right click",
                            time: click.time,
                            systemImage: "cursorarrow.click",
                            isSelected: selectedClickID == click.id
                        ) {
                            selection = .click(click.id)
                            playback.seek(to: click.time)
                        }
                    }

                    ForEach(project.subtitles) { subtitle in
                        layerButton(
                            title: subtitle.text.isEmpty
                                ? "Subtitle"
                                : subtitle.text,
                            time: subtitle.startTime,
                            systemImage: "captions.bubble.fill",
                            isSelected: selectedSubtitleID == subtitle.id
                        ) {
                            selection = .subtitle(subtitle.id)
                            playback.seek(to: subtitle.startTime)
                        }
                    }

                    ForEach(project.effects) { effect in
                        layerButton(
                            title: effect.displayName,
                            time: effect.startTime,
                            systemImage: "wand.and.stars",
                            isSelected: selectedEffectID == effect.id
                        ) {
                            selection = .effect(effect.id)
                            playback.seek(to: effect.startTime)
                        }
                    }

                    ForEach(project.suggestions) { suggestion in
                        layerButton(
                            title: "Suggestion · \(suggestion.state.rawValue)",
                            time: suggestion.splitTime,
                            systemImage: "sparkles",
                            isSelected: selectedSuggestionID == suggestion.id
                        ) {
                            selection = .suggestion(suggestion.id)
                            playback.seek(to: suggestion.splitTime)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            if project.clips.isEmpty
                && project.clicks.isEmpty
                && project.subtitles.isEmpty
                && project.effects.isEmpty
                && project.suggestions.isEmpty {
                Text("Recorded clicks and subtitles will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(minHeight: 128, alignment: .top)
        .background(.bar.opacity(0.65))
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
                        project.clips.remove(at: index)
                        project = VideoTimelineEditor.remapContentLayers(project)
                        selection = nil
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
                SubtitleLayerInspector(
                    subtitle: $project.subtitles[index],
                    duration: playback.duration,
                    onDelete: {
                        project.subtitles.remove(at: index)
                        selection = nil
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

    /// Creates a compact timeline card that also seeks the preview to the layer time.
    private func layerButton(
        title: String,
        time: Double,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: systemImage)
                    .lineLimit(1)
                Text(Self.time(time))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 142, alignment: .leading)
            .padding(9)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.18)
                    : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 9)
            )
        }
        .buttonStyle(.plain)
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
            text: "New subtitle"
        )
        project.subtitles.append(subtitle)
        selection = .subtitle(subtitle.id)
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
              let sourceTime = VideoTimelineEditor.sourceTime(
                in: project,
                at: playback.currentTime
              )
        else { return }
        do {
            project = try VideoTimelineEditor.split(
                project: project,
                clipID: selectedClipID,
                sourceTime: sourceTime
            )
            selection = nil
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    /// Inserts one editable one-second freeze segment after the selected clip.
    private func addFreeze() {
        guard let selectedClipID,
              let sourceTime = VideoTimelineEditor.sourceTime(
                in: project,
                at: playback.currentTime
              )
        else { return }
        do {
            project = try VideoTimelineEditor.insertFreeze(
                project: project,
                after: selectedClipID,
                sourceTime: sourceTime,
                duration: 1
            )
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    /// Adds one contract-valid effect draft at the playhead for immediate inspector editing.
    private func addEffect(_ kind: NewEffectKind) {
        let start = min(playback.currentTime, max(project.timelineDuration - 0.1, 0))
        let end = min(max(start + 1, start + 0.1), project.timelineDuration)
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
        project.effects.append(effect)
        selection = .effect(effect.id)
    }

    /// Formats a project-time value without depending on locale-specific media controls.
    private static func time(_ seconds: Double) -> String {
        let bounded = max(seconds, 0)
        let minutes = Int(bounded) / 60
        let remainder = bounded - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, remainder)
    }
}

private struct VideoOverlayCanvas: View {
    let project: DemoProject
    let time: Double
    let imageFrame: CGRect

    var body: some View {
        let metrics = VideoOverlayMetrics(frameSize: imageFrame.size)
        ZStack(alignment: .topLeading) {
            ForEach(project.clicks.filter {
                $0.indicator.startTime <= time
                    && time <= $0.indicator.endTime
            }) { click in
                let point = VideoOverlayLayout.clickPoint(
                    x: click.x,
                    y: click.y,
                    in: imageFrame,
                    axis: .topDown
                )
                let progress = min(
                    max(
                        (
                            time - click.time
                                + VideoOverlayTiming.clickLead
                        ) / (
                            VideoOverlayTiming.clickLead
                                + VideoOverlayTiming.clickTail
                        ),
                        0
                    ),
                    1
                )
                Circle()
                    .fill(Color(hex: click.indicator.colorHex).opacity(0.18))
                    .overlay(
                        Circle()
                            .stroke(
                                Color(hex: click.indicator.colorHex),
                                lineWidth: 3
                            )
                    )
                    .frame(
                        width: metrics.clickRingDiameter * click.indicator.size
                            * (0.65 + 0.7 * progress),
                        height: metrics.clickRingDiameter * click.indicator.size
                            * (0.65 + 0.7 * progress)
                    )
                    .opacity(
                        click.indicator.opacity * (1 - progress * 0.85)
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
                    metrics: metrics
                )
            }
        }
        .allowsHitTesting(false)
    }
}

private struct VideoScreenOverlayCanvas: View {
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
                    card(title: value.title, secondary: value.subtitle)
                case let .cta(value):
                    card(title: value.title, secondary: value.buttonLabel)
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

    private func card(title: String, secondary: String) -> some View {
        ZStack {
            Color.black.opacity(0.88)
            VStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 32, weight: .bold))
                if !secondary.isEmpty {
                    Text(secondary)
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }
            .foregroundStyle(.white)
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
                fontSize: metrics.subtitleFontSize,
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
            fontSize: metrics.captionFontSize,
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
        .position(
            x: captionOrigin.x + labelSize.width / 2,
            y: captionOrigin.y + labelSize.height / 2
        )
    }

    private var captionOrigin: CGPoint {
        let x = click.description.position == .custom
            ? click.description.x
            : click.x
        let y = click.description.position == .custom
            ? click.description.y
            : click.y
        return VideoOverlayLayout.captionOrigin(
            labelSize: labelSize,
            x: x,
            y: y,
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
