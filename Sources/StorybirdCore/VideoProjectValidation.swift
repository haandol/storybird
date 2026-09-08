import Foundation

public enum VideoProjectValidationError: LocalizedError, Equatable {
    case missingRecording
    case invalidRecording
    case invalidAssetFilename
    case invalidClick(UUID)
    case invalidSubtitle(UUID)
    case invalidClip(UUID)
    case invalidEffect(UUID)
    case invalidSuggestion(UUID)
    case duplicateLayerID(UUID)

    public var errorDescription: String? {
        switch self {
        case .missingRecording:
            return "This project does not contain a video recording."
        case .invalidRecording:
            return "The recording duration or dimensions are invalid."
        case .invalidAssetFilename:
            return "The recording asset filename is invalid."
        case let .invalidClick(id):
            return "Click layer \(id.uuidString) is outside the recording."
        case let .invalidSubtitle(id):
            return "Subtitle layer \(id.uuidString) is outside the recording."
        case let .invalidClip(id):
            return "Timeline clip \(id.uuidString) is invalid."
        case let .invalidEffect(id):
            return "Effect \(id.uuidString) is invalid."
        case let .invalidSuggestion(id):
            return "Suggestion \(id.uuidString) is invalid."
        case let .duplicateLayerID(id):
            return "Layer \(id.uuidString) appears more than once."
        }
    }
}

public enum VideoProjectValidator {
    /// Rejects invalid time and coordinate metadata before it can replace a persisted project.
    public static func validate(_ project: DemoProject) throws {
        guard let recording = project.recording else {
            throw VideoProjectValidationError.missingRecording
        }
        guard recording.duration.isFinite,
              recording.duration > 0,
              recording.width > 0,
              recording.height > 0,
              recording.mediaStartTime?.isFinite != false
        else {
            throw VideoProjectValidationError.invalidRecording
        }
        guard isSimpleFilename(recording.filename),
              ["mp4", "mov"].contains(
                  recording.filename.pathExtension.lowercased()
              )
        else {
            throw VideoProjectValidationError.invalidAssetFilename
        }

        var layerIDs = Set<UUID>()
        for clip in project.clips {
            guard layerIDs.insert(clip.id).inserted else {
                throw VideoProjectValidationError.duplicateLayerID(clip.id)
            }
            let valid: Bool
            switch clip.kind {
            case .video:
                valid = clip.sourceStart.isFinite
                    && clip.sourceEnd.isFinite
                    && clip.sourceStart >= 0
                    && clip.sourceStart < clip.sourceEnd
                    && clip.sourceEnd <= recording.duration
                    && (0.25...4).contains(clip.playbackRate)
            case .freeze:
                valid = clip.sourceStart.isFinite
                    && (0...recording.duration).contains(clip.sourceStart)
                    && clip.freezeDuration.isFinite
                    && clip.freezeDuration > 0
            }
            guard valid else {
                throw VideoProjectValidationError.invalidClip(clip.id)
            }
        }
        let timelineDuration = project.timelineDuration
        var previousClickTime = -Double.infinity
        for click in project.clicks {
            guard layerIDs.insert(click.id).inserted else {
                throw VideoProjectValidationError.duplicateLayerID(click.id)
            }
            guard click.time.isFinite,
                  (0...timelineDuration).contains(click.time),
                  click.sourceTime.isFinite,
                  (0...recording.duration).contains(click.sourceTime),
                  click.x.isFinite,
                  click.y.isFinite,
                  (0...1).contains(click.x),
                  (0...1).contains(click.y),
                  click.time >= previousClickTime,
                  isHexColor(click.indicator.colorHex),
                  click.indicator.startTime <= click.time,
                  click.indicator.endTime > click.time,
                  click.description.startTime <= click.time,
                  click.description.endTime > click.time,
                  click.cueSubtitle.startTime <= click.time,
                  click.cueSubtitle.endTime > click.time,
                  click.indicator.endTime <= timelineDuration,
                  click.description.endTime <= timelineDuration,
                  click.cueSubtitle.endTime <= timelineDuration,
                  isHexColor(click.description.style.backgroundHex),
                  isHexColor(click.description.style.foregroundHex),
                  isHexColor(click.cueSubtitle.style.backgroundHex),
                  isHexColor(click.cueSubtitle.style.foregroundHex)
            else {
                throw VideoProjectValidationError.invalidClick(click.id)
            }
            if let anchor = click.sourceAnchor {
                guard let clip = project.clips.first(
                    where: { $0.id == anchor.clipID }
                ),
                    clip.kind == anchor.clipKind,
                    anchor.clipOffset.isFinite,
                    anchor.clipOffset >= 0,
                    anchor.clipOffset < clip.outputDuration
                else {
                    throw VideoProjectValidationError.invalidClick(click.id)
                }
                switch clip.kind {
                case .video:
                    guard click.sourceTime >= clip.sourceStart,
                          click.sourceTime < clip.sourceEnd
                    else {
                        throw VideoProjectValidationError.invalidClick(click.id)
                    }
                case .freeze:
                    guard abs(click.sourceTime - clip.sourceStart) <= 0.001
                    else {
                        throw VideoProjectValidationError.invalidClick(click.id)
                    }
                }
            }
            previousClickTime = click.time
        }

        for subtitle in project.subtitles {
            guard layerIDs.insert(subtitle.id).inserted else {
                throw VideoProjectValidationError.duplicateLayerID(subtitle.id)
            }
            guard subtitle.startTime.isFinite,
                  subtitle.endTime.isFinite,
                  subtitle.startTime >= 0,
                  subtitle.startTime < subtitle.endTime,
                  subtitle.endTime <= timelineDuration,
                  !subtitle.text.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty,
                  isHexColor(subtitle.style.backgroundHex),
                  isHexColor(subtitle.style.foregroundHex)
            else {
                throw VideoProjectValidationError.invalidSubtitle(subtitle.id)
            }
        }

        let sortedNarrations = project.narrations.sorted {
            $0.startTime < $1.startTime
        }
        var previousNarrationEnd = 0.0
        for narration in sortedNarrations {
            guard layerIDs.insert(narration.id).inserted,
                  isSimpleFilename(narration.filename),
                  narration.filename.pathExtension.lowercased() == "wav",
                  !narration.text.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty,
                  narration.startTime.isFinite,
                  narration.duration.isFinite,
                  narration.volume.isFinite,
                  narration.startTime >= 0,
                  narration.duration > 0,
                  narration.endTime <= timelineDuration,
                  narration.volume >= 0,
                  narration.startTime >= previousNarrationEnd
            else {
                throw VideoProjectValidationError.invalidRecording
            }
            previousNarrationEnd = narration.endTime
        }

        let duration = timelineDuration
        var spotlightRanges: [ClosedRange<Double>] = []
        var panZoomRanges: [ClosedRange<Double>] = []
        guard cardsFollowClipBoundaries(project) else {
            throw VideoProjectValidationError.invalidRecording
        }
        for effect in project.effects {
            guard layerIDs.insert(effect.id).inserted else {
                throw VideoProjectValidationError.duplicateLayerID(effect.id)
            }
            guard effect.startTime.isFinite,
                  effect.endTime.isFinite,
                  effect.startTime >= 0,
                  effect.startTime < effect.endTime,
                  effect.endTime <= duration
            else {
                throw VideoProjectValidationError.invalidEffect(effect.id)
            }
            let range = effect.startTime...effect.endTime
            switch effect {
            case let .spotlight(value):
                guard normalizedRect(
                    x: value.x,
                    y: value.y,
                    width: value.width,
                    height: value.height
                ),
                    !spotlightRanges.contains(where: { overlaps($0, range) })
                else {
                    throw VideoProjectValidationError.invalidEffect(effect.id)
                }
                spotlightRanges.append(range)
                try validateEffectAnchor(value.sourceAnchor, in: project)
            case let .panZoom(value):
                guard normalizedPoint(x: value.startX, y: value.startY),
                      normalizedPoint(x: value.endX, y: value.endY),
                      (1...3).contains(value.startScale),
                      (1...3).contains(value.endScale),
                      !panZoomRanges.contains(where: { overlaps($0, range) })
                else {
                    throw VideoProjectValidationError.invalidEffect(effect.id)
                }
                panZoomRanges.append(range)
                try validateEffectAnchor(value.sourceAnchor, in: project)
            case let .title(value):
                guard !value.title.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty else {
                    throw VideoProjectValidationError.invalidEffect(effect.id)
                }
            case let .cta(value):
                guard !value.title.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty,
                    !value.buttonLabel.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty,
                    abs(value.endTime - duration) <= 0.001
                else {
                    throw VideoProjectValidationError.invalidEffect(effect.id)
                }
            }
        }

        var suggestedClickIDs = Set<UUID>()
        let clickIDs = Set(project.clicks.map(\.id))
        for suggestion in project.suggestions {
            guard layerIDs.insert(suggestion.id).inserted,
                  clickIDs.contains(suggestion.clickID),
                  suggestedClickIDs.insert(suggestion.clickID).inserted
            else {
                throw VideoProjectValidationError.invalidSuggestion(suggestion.id)
            }
        }
    }

    /// Rejects persisted content-effect anchors that outlive their owning clip or
    /// describe source/offset ranges outside that clip's editable content.
    private static func validateEffectAnchor(
        _ anchor: ContentEffectAnchor?,
        in project: DemoProject
    ) throws {
        guard let anchor else { return }
        guard let clip = project.clips.first(
            where: { $0.id == anchor.clipID }
        ),
            clip.kind == anchor.clipKind
        else {
            throw VideoProjectValidationError.invalidRecording
        }
        switch clip.kind {
        case .video:
            guard anchor.sourceStart.isFinite,
                  anchor.sourceEnd.isFinite,
                  anchor.sourceStart >= clip.sourceStart,
                  anchor.sourceStart < anchor.sourceEnd,
                  anchor.sourceEnd <= clip.sourceEnd
            else {
                throw VideoProjectValidationError.invalidRecording
            }
        case .freeze:
            guard anchor.clipStartOffset.isFinite,
                  anchor.clipEndOffset.isFinite,
                  anchor.clipStartOffset >= 0,
                  anchor.clipStartOffset < anchor.clipEndOffset,
                  anchor.clipEndOffset <= clip.outputDuration
            else {
                throw VideoProjectValidationError.invalidRecording
            }
        }
    }

    /// Keeps recording assets inside their project directory instead of accepting path traversal.
    private static func isSimpleFilename(_ value: String) -> Bool {
        !value.isEmpty
            && value == (value as NSString).lastPathComponent
            && value != "."
            && value != ".."
    }

    /// Keeps preview and export color interpretation identical by accepting one canonical RGB form.
    private static func isHexColor(_ value: String) -> Bool {
        let hexadecimal = CharacterSet(
            charactersIn: "0123456789abcdefABCDEF"
        )
        return value.count == 7
            && value.first == "#"
            && value.dropFirst().unicodeScalars.allSatisfy(
                hexadecimal.contains
            )
    }

    private static func normalizedPoint(x: Double, y: Double) -> Bool {
        x.isFinite && y.isFinite
            && (0...1).contains(x)
            && (0...1).contains(y)
    }

    private static func normalizedRect(
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> Bool {
        normalizedPoint(x: x, y: y)
            && width.isFinite
            && height.isFinite
            && width > 0
            && height > 0
            && x + width <= 1
            && y + height <= 1
    }

    private static func overlaps(
        _ lhs: ClosedRange<Double>,
        _ rhs: ClosedRange<Double>
    ) -> Bool {
        lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
    }

    private static func cardsFollowClipBoundaries(
        _ project: DemoProject
    ) -> Bool {
        VideoTimelineSchedule(project: project).isStructurallyValid
    }
}

private extension String {
    var pathExtension: String {
        (self as NSString).pathExtension
    }
}
