import Foundation

public enum AudioLayerEditor {
    /// Places a reusable complete asset without changing it. A failed range or
    /// scene anchor leaves the caller's project and asset library untouched.
    public static func place(
        assetID: UUID, in project: DemoProject, startTime: Double,
        sourceStart: Double = 0, duration: Double? = nil,
        timingMode: LayerTimingMode = .project
    ) throws -> DemoProject {
        guard let asset = project.availableAudioAssets.first(where: { $0.id == assetID }) else {
            throw VideoProjectValidationError.invalidAssetFilename
        }
        var result = project
        result.narrations.append(NarrationClip(
            voiceProfileID: asset.voiceProfileID, filename: asset.filename,
            text: asset.text, language: asset.language, startTime: startTime,
            duration: duration ?? (asset.duration - sourceStart),
            sceneAnchor: timingMode == .scene ? try SceneTiming.anchor(at: startTime, in: project) : nil,
            assetID: asset.id, name: asset.name, sourceStart: sourceStart, sourceDuration: asset.duration
        ))
        try VideoProjectValidator.validate(result)
        return result
    }

    /// Updates all requested properties as one value replacement and maintains
    /// scene ownership when a layer's start time changes.
    public static func replace(
        _ layer: NarrationClip, in project: DemoProject, timingMode: LayerTimingMode? = nil
    ) throws -> DemoProject {
        var result = project
        guard let index = result.narrations.firstIndex(where: { $0.id == layer.id }) else {
            throw VideoProjectValidationError.invalidNarration(layer.id, "Audio layer not found.")
        }
        let old = result.narrations[index]
        var replacement = reconcileFade(from: old, to: layer)
        if timingMode != nil || old.startTime != layer.startTime {
            let mode = timingMode ?? (old.sceneAnchor == nil ? .project : .scene)
            replacement.sceneAnchor = mode == .scene ? try SceneTiming.anchor(at: layer.startTime, in: project) : nil
        }
        result.narrations[index] = replacement
        try VideoProjectValidator.validate(result)
        return result
    }

    /// Keeps the audible part of a fade when trimming. Explicit fade edits
    /// start a new envelope; split-created envelopes are already authoritative.
    public static func reconcileFade(from old: NarrationClip, to next: NarrationClip) -> NarrationClip {
        guard old.assetID == next.assetID, old.filename == next.filename else {
            var replacement = next
            replacement.fadeEnvelope = nil
            return replacement
        }
        guard next.fadeEnvelope == old.fadeEnvelope else { return next }
        var result = next
        if next.fadeIn != old.fadeIn || next.fadeOut != old.fadeOut {
            result.fadeEnvelope = nil
        } else if next.sourceStart != old.sourceStart || next.duration != old.duration {
            let offset = next.sourceStart - old.sourceStart
            if offset >= 0, offset + next.duration <= old.duration {
                var envelope = old.effectiveFadeEnvelope
                envelope.offset += offset
                result.fadeEnvelope = envelope
                result.fadeIn = max(0, min(next.duration, old.fadeIn - offset))
                result.fadeOut = max(0, min(next.duration, offset + next.duration - (old.duration - old.fadeOut)))
            } else {
                result.fadeEnvelope = nil
            }
        }
        return result
    }

    /// Reuses the immutable asset with a new layer identity and an explicit
    /// placement. Overlap is intentional and never shifts another layer.
    public static func duplicate(
        layerID: UUID, in project: DemoProject, startTime: Double? = nil
    ) throws -> DemoProject {
        guard var copy = project.narrations.first(where: { $0.id == layerID }) else {
            throw VideoProjectValidationError.invalidNarration(layerID, "Audio layer not found.")
        }
        copy.id = UUID()
        copy.startTime = startTime ?? copy.startTime
        if copy.sceneAnchor != nil { copy.sceneAnchor = try SceneTiming.anchor(at: copy.startTime, in: project) }
        var result = project
        result.narrations.append(copy)
        try VideoProjectValidator.validate(result)
        return result
    }

    /// Splits the selected source range into adjacent, positive-length layers
    /// referencing the same complete file; the split boundary belongs to the right.
    public static func split(layerID: UUID, in project: DemoProject, at time: Double) throws -> DemoProject {
        guard let index = project.narrations.firstIndex(where: { $0.id == layerID }) else {
            throw VideoProjectValidationError.invalidNarration(layerID, "Audio layer not found.")
        }
        let original = project.narrations[index]
        guard time.isFinite, time > original.startTime, time < original.endTime else {
            throw VideoProjectValidationError.invalidNarration(layerID, "Split inside the audio layer.")
        }
        var left = original
        var right = original
        let offset = time - original.startTime
        left.duration = offset
        left.fadeIn = min(original.fadeIn, left.duration)
        left.fadeOut = max(0, offset - (original.duration - original.fadeOut))
        left.fadeEnvelope = original.effectiveFadeEnvelope
        right.id = UUID()
        right.sourceStart += offset
        right.startTime = time
        right.duration -= offset
        right.fadeIn = max(0, original.fadeIn - offset)
        right.fadeEnvelope = original.effectiveFadeEnvelope
        right.fadeEnvelope?.offset += offset
        right.fadeOut = min(original.fadeOut, right.duration)
        if original.sceneAnchor != nil { right.sceneAnchor = try SceneTiming.anchor(at: time, in: project) }
        var result = project
        result.narrations.replaceSubrange(index...index, with: [left, right])
        try VideoProjectValidator.validate(result)
        return result
    }
}
