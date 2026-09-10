import StorybirdCore
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let storybirdOpenProjectAudio = Notification.Name("Storybird.OpenProjectAudio")
}

struct TimelineAudioReference: Codable, Equatable {
    enum Kind: String, Codable { case asset, draft }
    let projectID: UUID
    let itemID: UUID
    let kind: Kind
    let revision: Int
    let token: UUID

    static let contentType = UTType(exportedAs: "com.storybird.timeline-audio")
}

@MainActor
final class TimelineAudioModel: ObservableObject {
    enum Adjustment: Equatable { case trimStart, trimEnd, fadeIn, fadeOut, volume }
    enum Action { case split, duplicate, mute, delete }

    @Published var selectedLayerID: UUID?
    @Published private(set) var previewLayer: NarrationClip?
    @Published private(set) var adjustment: Adjustment?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPlacing = false
    @Published private(set) var dragging: TimelineAudioReference?
    @Published var dropTime: Double?
    @Published var timingMode: LayerTimingMode = .scene
    private var baseline: DemoProject?

    /// Carries only project identity, never an external file path. The unique
    /// drag token prevents a cancelled drag from authorizing a later provider.
    func beginDrag(itemID: UUID, kind: TimelineAudioReference.Kind, project: DemoProject) -> NSItemProvider {
        let reference = TimelineAudioReference(
            projectID: project.id, itemID: itemID, kind: kind, revision: project.revision, token: UUID()
        )
        dragging = reference
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(reference)
        provider.registerDataRepresentation(
            forTypeIdentifier: TimelineAudioReference.contentType.identifier, visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// Reads display metadata from the current project instead of trusting the
    /// drag payload. Only complete assets and ready drafts can be placed.
    func duration(of reference: TimelineAudioReference, in project: DemoProject) -> Double? {
        guard reference.projectID == project.id else { return nil }
        switch reference.kind {
        case .asset:
            return project.availableAudioAssets.first { $0.id == reference.itemID }?.duration
        case .draft:
            return project.narrationDrafts.first { $0.id == reference.itemID && $0.state == .ready }?.duration
        }
    }

    /// A provider can complete after the user changes project or cancels the
    /// drag. Authenticate its token and the still-visible project before saving.
    func receiveDrop(_ data: Data?, reference: TimelineAudioReference, at time: Double, in store: AppStore) async {
        let decoded = data.flatMap { try? JSONDecoder().decode(TimelineAudioReference.self, from: $0) }
        guard dragging == reference else { return }
        guard decoded == reference, store.selectedProjectID == reference.projectID else {
            cancel()
            return
        }
        await place(reference, at: time, in: store)
    }

    /// Validates the whole source range at the indicated project time. Cards
    /// use fixed timing; playable scenes follow the panel's timing selection.
    func place(
        _ reference: TimelineAudioReference, at time: Double, in store: AppStore
    ) async {
        guard !isPlacing else { return }
        isPlacing = true
        errorMessage = nil
        defer { isPlacing = false; dragging = nil; dropTime = nil }
        do {
            guard let project = store.project(id: reference.projectID),
                  duration(of: reference, in: project) != nil else {
                throw NarrationDraftError.notReady
            }
            let mode: LayerTimingMode = timingMode == .scene
                && (try? SceneTiming.anchor(at: time, in: project)) != nil ? .scene : .project
            let updated: DemoProject
            switch reference.kind {
            case .asset:
                updated = try store.placeAudioAsset(
                    projectID: project.id, assetID: reference.itemID, expectedRevision: reference.revision,
                    startTime: time, timingMode: mode
                )
            case .draft:
                updated = try await store.placeNarrationDraft(
                    projectID: project.id, draftID: reference.itemID, expectedRevision: reference.revision,
                    startTime: time, timingMode: mode
                )
            }
            selectedLayerID = Self.addedLayerID(in: updated, comparedTo: project)
        } catch { report(error, in: store) }
    }

    /// Keeps trim/fade/volume gestures transient. A revision captured on first
    /// movement prevents later updates from silently rebasing concurrent edits.
    func update(layerID: UUID, adjustment: Adjustment, value: Double, project: DemoProject) {
        guard value.isFinite else { return }
        if baseline == nil {
            baseline = project
            self.adjustment = adjustment
            previewLayer = project.narrations.first { $0.id == layerID }
            errorMessage = nil
        }
        guard self.adjustment == adjustment, let baseline,
              let original = baseline.narrations.first(where: { $0.id == layerID }) else { return }
        var changed = original
        switch adjustment {
        case .trimStart:
            changed.startTime += value
            changed.sourceStart += value
            changed.duration -= value
        case .trimEnd: changed.duration += value
        case .fadeIn: changed.fadeIn = min(max(0, original.fadeIn + value), max(0, original.duration - original.fadeOut))
        case .fadeOut: changed.fadeOut = min(max(0, original.fadeOut - value), max(0, original.duration - original.fadeIn))
        case .volume: changed.volume = max(0, value)
        }
        // Explicit fade changes reset any envelope retained by a prior trim,
        // just as publication does, so the preview line matches saved playback.
        previewLayer = AudioLayerEditor.reconcileFade(from: original, to: changed)
    }

    /// Publishes a gesture once against the current project. Validation failure,
    /// stale revision or disk failure preserves the project and its undo stack.
    func finish(in store: AppStore) {
        defer { cancelAdjustment() }
        guard let baseline, let previewLayer,
              let original = baseline.narrations.first(where: { $0.id == previewLayer.id }),
              previewLayer != original else { return }
        do {
            guard let current = store.project(id: baseline.id) else { throw RecordingStoreError.projectNotFound }
            guard current.revision == baseline.revision else {
                throw RecordingStoreError.revisionConflict(current.revision)
            }
            let edited = try AudioLayerEditor.replace(previewLayer, in: current)
            try store.saveProject(edited, expectedRevision: baseline.revision)
        } catch { report(error, in: store) }
    }

    /// Removes only the temporary gesture state, retaining any failure message.
    func cancelAdjustment() {
        baseline = nil
        previewLayer = nil
        adjustment = nil
    }

    /// Cancels view-owned interactions on project switch or dismissal.
    func cancel() {
        cancelAdjustment()
        dragging = nil
        dropTime = nil
    }

    /// Applies the same validated command for toolbar and context-menu actions.
    /// Duplication intentionally overlaps the original and selects the copy.
    func perform(_ action: Action, layerID: UUID, at time: Double, project: DemoProject, store: AppStore) {
        errorMessage = nil
        do {
            guard let current = store.project(id: project.id),
                  let layer = current.narrations.first(where: { $0.id == layerID }) else {
                throw RecordingStoreError.projectNotFound
            }
            guard current.revision == project.revision else { throw RecordingStoreError.revisionConflict(current.revision) }
            var changed = current
            switch action {
            case .split: changed = try AudioLayerEditor.split(layerID: layerID, in: current, at: time)
            case .duplicate: changed = try AudioLayerEditor.duplicate(layerID: layerID, in: current)
            case .mute:
                var edited = layer
                edited.isMuted.toggle()
                changed = try AudioLayerEditor.replace(edited, in: current)
            case .delete: changed.narrations.removeAll { $0.id == layerID }
            }
            let saved = try store.saveProject(changed, expectedRevision: current.revision)
            selectedLayerID = action == .delete ? nil
                : Self.addedLayerID(in: saved, comparedTo: current) ?? layerID
        } catch { report(error, in: store) }
    }

    /// Selects the first inserted layer in published order. Build the old ID
    /// set once so placement, split and duplicate do not rescan it per layer.
    private static func addedLayerID(in updated: DemoProject, comparedTo original: DemoProject) -> UUID? {
        let existingIDs = Set(original.narrations.map(\.id))
        return updated.narrations.first { !existingIDs.contains($0.id) }?.id
    }

    /// Keeps failures visible next to the audio controls and in the app alert.
    private func report(_ error: Error, in store: AppStore) {
        errorMessage = error.localizedDescription
        store.errorMessage = error.localizedDescription
    }
}

struct TimelineAudioDropDelegate: DropDelegate {
    let model: TimelineAudioModel
    let store: AppStore
    let project: DemoProject
    let width: Double

    /// Accepts only a local audio card belonging to the displayed project.
    func validateDrop(info: DropInfo) -> Bool {
        model.dragging?.projectID == project.id && !model.isPlacing
            && info.hasItemsConforming(to: [TimelineAudioReference.contentType])
    }

    /// Maps the pointer to the same horizontal time scale as every audio block.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        model.dropTime = max(0, info.location.x / max(width, 1) * project.timelineDuration)
        return DropProposal(operation: .copy)
    }

    /// Hides the insertion preview outside the audio row while allowing reentry.
    func dropExited(info: DropInfo) { model.dropTime = nil }

    /// Authenticates the provider against the exact local drag token before
    /// performing an asynchronous, revision-checked placement.
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let reference = model.dragging,
              let provider = info.itemProviders(for: [TimelineAudioReference.contentType]).first else { return false }
        let time = max(0, info.location.x / max(width, 1) * project.timelineDuration)
        provider.loadDataRepresentation(forTypeIdentifier: TimelineAudioReference.contentType.identifier) { data, _ in
            Task { @MainActor in
                await model.receiveDrop(data, reference: reference, at: time, in: store)
            }
        }
        return true
    }
}
