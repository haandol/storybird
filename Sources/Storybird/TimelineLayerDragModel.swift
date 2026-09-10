import StorybirdCore
import SwiftUI

@MainActor
final class TimelineLayerDragModel: ObservableObject {
    @Published private(set) var target: TimelineLayerTarget?
    @Published private(set) var delta: Double = 0
    private var baseline: DemoProject?
    private var canvasWidth: Double = 1

    /// Captures the project once per gesture. Further pointer movement changes
    /// only the preview offset, never the project or its undo history.
    func update(
        target: TimelineLayerTarget, translation: Double, canvasWidth: Double, project: DemoProject
    ) {
        guard translation.isFinite, canvasWidth.isFinite, canvasWidth > 0 else { return }
        if self.target == nil {
            self.target = target
            baseline = project
            self.canvasWidth = canvasWidth
        }
        guard self.target == target, let baseline else { return }
        delta = translation / self.canvasWidth * baseline.timelineDuration
    }

    /// Commits against the current project so same-revision suggestion and asset
    /// updates survive the gesture. Changed output revisions and failed writes
    /// leave the stored project and undo unchanged.
    func finish(in store: AppStore) {
        defer { cancel() }
        guard let target, let baseline, delta != 0 else { return }
        do {
            guard let current = store.project(id: baseline.id) else {
                throw RecordingStoreError.projectNotFound
            }
            guard current.revision == baseline.revision else {
                throw RecordingStoreError.revisionConflict(current.revision)
            }
            let moved = try TimelineLayerEditor.move(target, by: delta, in: current)
            try store.saveProject(moved, expectedRevision: baseline.revision)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    /// Ends an interrupted gesture without applying its preview.
    func cancel() {
        target = nil
        baseline = nil
        delta = 0
    }
}
