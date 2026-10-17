import AppKit
import StorybirdCore
import SwiftUI

@MainActor
final class TimelineClipEditModel: ObservableObject {
    enum Operation { case trimStart, trimEnd, reorder }
    @Published private(set) var clipID: UUID?
    @Published private(set) var label = ""
    @Published private(set) var guide: Double?
    @Published private(set) var guideLabel = ""
    @Published private(set) var previewSummary = ""
    @Published private(set) var error: String?
    private var baseline: DemoProject?
    private var clip: VideoClip?
    private var operation: Operation = .reorder
    private var pointsPerSecond: Double = 1
    private var start: Double = 0
    private var end: Double = 0
    private var playhead: Double = 0
    private var draft: ProjectEdit?

    /// A gesture owns one baseline revision. Pointer updates are local previews;
    /// another editor's save can never be silently overwritten on mouse-up.
    func begin(clipID: UUID, operation: Operation, project: DemoProject, canvasWidth: Double, playhead: Double) {
        cancel()
        guard canvasWidth > 0, project.timelineDuration > 0,
              let item = VideoTimelineSchedule(project: project).items.first(where: {
                  if case let .clip(value) = $0 { value.clip.id == clipID } else { false }
              }), case let .clip(scheduled) = item else { return }
        self.clipID = clipID
        self.operation = operation
        baseline = project
        clip = scheduled.clip
        start = scheduled.projectStart
        end = scheduled.projectEnd
        pointsPerSecond = canvasWidth / project.timelineDuration
        self.playhead = playhead
    }

    func update(translation: Double, bypassSnap: Bool = false) {
        guard let baseline, let clip, translation.isFinite else { return }
        let delta = translation / pointsPerSecond
        let candidates = TimelineSnapping.candidates(in: baseline, playhead: playhead)
        let proposed = operation == .trimStart ? start + delta : end + delta
        let snap = TimelineSnapping.nearest(to: proposed, tolerance: 8 / pointsPerSecond,
            candidates: candidates, excluding: [clip.id], bypass: bypassSnap)
        let snappedDelta = (snap?.time ?? proposed) - (operation == .trimStart ? start : end)
        guide = snap?.time
        guideLabel = snap.map { candidate in
            let kind: String
            switch candidate.kind { case .playhead: kind = "Playhead"; case .clipBoundary: kind = "Clip boundary"; case .layerBoundary: kind = "Layer boundary" }
            return String(format: "%@ · %.2fs", kind, candidate.time)
        } ?? ""
        switch operation {
        case .reorder:
            let center = (start + end) / 2 + delta
            let remaining = VideoTimelineSchedule(project: baseline).items.compactMap { item -> VideoTimelineSchedule.ScheduledClip? in
                if case let .clip(value) = item, value.clip.id != clip.id { value } else { nil }
            }
            let destination = remaining.filter { ($0.projectStart + $0.projectEnd) / 2 < center }.count
            draft = ProjectEdit(target: .clip, id: clip.id, action: .move, values: ["destination_index": .number(Double(destination))])
            guide = destination < remaining.count ? remaining[destination].projectStart : remaining.last?.projectEnd ?? 0
            label = "Insert at position \(destination + 1)"
            guideLabel = String(format: "%@ · %.2fs", label, guide ?? 0)
        case .trimStart, .trimEnd:
            let values: [String: ProjectEditValue]
            if clip.kind == .video {
                let minimum = min(0.001, (clip.sourceEnd - clip.sourceStart) / 2)
                let sourceDuration = baseline.mediaAsset(for: clip)?.duration ?? clip.sourceEnd
                let sourceStart = operation == .trimStart
                    ? min(max(clip.sourceStart + snappedDelta * clip.playbackRate, 0), clip.sourceEnd - minimum) : clip.sourceStart
                let sourceEnd = operation == .trimEnd
                    ? max(min(clip.sourceEnd + snappedDelta * clip.playbackRate, sourceDuration), clip.sourceStart + minimum) : clip.sourceEnd
                values = ["source_start": .number(sourceStart), "source_end": .number(sourceEnd)]
                label = String(format: "Source %.2f–%.2fs", sourceStart, sourceEnd)
            } else {
                let duration = max(min(0.001, clip.outputDuration / 2),
                    clip.outputDuration + (operation == .trimStart ? -snappedDelta : snappedDelta))
                values = ["duration": .number(duration)]
                label = String(format: "Duration %.2fs", duration)
            }
            draft = ProjectEdit(target: .clip, id: clip.id, action: .update, values: values)
        }
        do {
            if let draft {
                let plan = try ProjectEditPlanner.plan([draft], in: baseline)
                let count = plan.derived.filter { $0.target != .clip && $0.target != .project }.count
                previewSummary = String(format: "%@ · Timeline %.2fs · %d linked layers", label, plan.project.timelineDuration, count)
            }
            error = nil
        } catch { self.error = error.localizedDescription; previewSummary = label + " · " + error.localizedDescription }
    }

    @discardableResult
    func finish(in store: AppStore) -> Bool {
        defer { cancel() }
        guard let baseline, let draft else { return false }
        do {
            _ = try store.editProject(projectID: baseline.id, expectedRevision: baseline.revision, edits: [draft])
            return true
        } catch { store.errorMessage = error.localizedDescription; return false }
    }

    func cancel() {
        clipID = nil
        baseline = nil
        clip = nil
        draft = nil
        label = ""
        guide = nil
        guideLabel = ""
        previewSummary = ""
        error = nil
    }
}

struct TimelineClipBlock: View {
    @ObservedObject var store: AppStore
    @ObservedObject var model: TimelineClipEditModel
    let project: DemoProject
    let clip: VideoClip
    let start: Double
    let end: Double
    let canvasWidth: Double
    let selected: Bool
    let playhead: Double
    let snapEnabled: Bool
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onTap: () -> Void
    let onBegin: () -> Void
    let onEnd: () -> Void
    @State private var frames: [NSImage] = []

    private var scale: Double { canvasWidth / max(project.timelineDuration, 0.001) }
    private var width: Double { max(18, (end - start) * scale) }
    private var frameCount: Int { width.isFinite ? Int(min(8, max(1, width / 56))) : 1 }
    private var asset: ProjectMediaAsset? { project.mediaAsset(for: clip) }
    private var clipLabel: String { "\((project.clips.firstIndex { $0.id == clip.id } ?? 0) + 1). \(asset?.name ?? clip.kind.rawValue.capitalized)" }
    private var thumbnailKey: String { "\(asset?.id.uuidString ?? ""):\(clip.sourceStart):\(clip.sourceEnd):\(frameCount)" }

    @GestureState private var gestureActive = false
    @State private var moved = false

    private func editingGesture(_ operation: TimelineClipEditModel.Operation) -> some Gesture {
        TimelinePointerGestures.drag(updating: $gestureActive, onChanged: { value, flags in
            if model.clipID == nil {
                moved = false
                onSelect(flags)
                model.begin(clipID: clip.id, operation: operation, project: project,
                    canvasWidth: canvasWidth, playhead: playhead)
            }
            if !moved { moved = true; onBegin() }
            model.update(translation: value.translation.width, bypassSnap: flags.contains(.option) || !snapEnabled)
        }, onEnded: { value, flags in
            if moved {
                model.update(translation: value.translation.width, bypassSnap: flags.contains(.option) || !snapEnabled)
                model.finish(in: store)
            } else { model.cancel() }
            moved = false
            onEnd()
        })
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Button {
                onSelect(NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags)
                onTap()
            } label: {
            ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.22))
            if !frames.isEmpty {
                HStack(spacing: 0) {
                    ForEach(frames.indices, id: \.self) { index in
                        Image(nsImage: frames[index]).resizable().scaledToFill()
                            .frame(width: width / Double(frames.count), height: 38).clipped()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text(model.clipID == clip.id && !model.label.isEmpty ? model.label : clipLabel)
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading).background(.black.opacity(0.55))
                .allowsHitTesting(false)
            }
            .frame(width: width, height: 38)
            .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .highPriorityGesture(TimelinePointerGestures.commandTap { onSelect([.command]); onTap() })
            .simultaneousGesture(editingGesture(.reorder))
            HStack(spacing: 0) {
                Button { onSelect([]) } label: {
                    RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.9)).frame(width: 8, height: 28)
                        .frame(width: 10, height: 38).contentShape(Rectangle())
                }.buttonStyle(.plain).simultaneousGesture(editingGesture(.trimStart))
                Spacer(minLength: 0)
                Button { onSelect([]) } label: {
                    RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.9)).frame(width: 8, height: 28)
                        .frame(width: 10, height: 38).contentShape(Rectangle())
                }.buttonStyle(.plain).simultaneousGesture(editingGesture(.trimEnd))
            }
        }
        .frame(width: width, height: 38)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(
            model.clipID == clip.id && model.error != nil ? Color.red : selected ? Color.accentColor : .clear, lineWidth: 2)
            .allowsHitTesting(false))
        .offset(x: start * scale)
        .accessibilityIdentifier("timeline-layer-\(clip.id.uuidString)")
        .help(model.error ?? "Drag the middle to reorder. Drag either edge to trim. Hold Option to bypass snapping.")
        .onChange(of: gestureActive) { _, active in
            if !active {
                Task { @MainActor in
                    guard !gestureActive, model.clipID == clip.id else { return }
                    model.cancel(); moved = false; onEnd()
                }
            }
        }
        .onExitCommand { model.cancel(); moved = false; onEnd() }
        .task(id: thumbnailKey) {
            guard let asset else { return }
            let url = store.repository.assetURL(projectID: project.id, filename: asset.filename)
            var images: [NSImage] = []
            for index in 0..<frameCount {
                if clip.kind != .video, let first = images.first {
                    images.append(first)
                    continue
                }
                let time = asset.kind == .image ? 0 : min(
                    clip.kind == .video ? clip.sourceStart + (clip.sourceEnd - clip.sourceStart) * Double(index) / Double(frameCount) : clip.sourceStart,
                    (asset.duration ?? clip.sourceEnd).nextDown)
                guard let frame = try? await ProjectMediaFiles.preview(asset: asset, url: url, time: time), !Task.isCancelled else { return }
                images.append(NSImage(cgImage: frame.image, size: .zero))
            }
            if !Task.isCancelled { frames = images }
        }
    }
}
