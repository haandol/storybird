import Foundation
import StorybirdCore
import SwiftUI

struct ProjectWorkspaceView: View {
    @ObservedObject var store: AppStore
    let projectID: UUID

    var body: some View {
        if let project = store.project(id: projectID) {
            let projectBinding = projectBinding(for: project)

            VStack(spacing: 0) {
                HStack {
                    ProjectHeader(project: projectBinding)
                    if project.recording != nil {
                        Button("Duplicate") {
                            Task {
                                do {
                                    _ = try await store.duplicateProject(
                                        projectID: project.id,
                                        expectedRevision: project.revision
                                    )
                                } catch {
                                    store.errorMessage = error.localizedDescription
                                }
                            }
                        }
                        .disabled(store.storageChangeDisabledReason != nil)
                        .padding(.trailing, 18)
                    }
                }
                Divider()

                if let recording = project.recording {
                    let videoURL = store.repository.assetURL(
                        projectID: project.id,
                        filename: recording.filename
                    )
                    if FileManager.default.fileExists(atPath: videoURL.path) {
                        VideoTimelineEditorView(
                            store: store,
                            project: projectBinding,
                            videoURL: videoURL,
                            duration: recording.duration
                        )
                    } else {
                        ContentUnavailableView(
                            "Recording unavailable",
                            systemImage: "video.slash",
                            description: Text(
                                "The original video file is missing from this project."
                            )
                        )
                    }
                } else if project.recording != nil || !project.steps.isEmpty {
                    ContentUnavailableView(
                        "Unsupported existing project",
                        systemImage: "rectangle.stack.badge.exclamationmark",
                        description: Text(
                            "This project remains on disk, but the new Click Cue timeline does not convert or edit older project models."
                        )
                    )
                } else {
                    ContentUnavailableView(
                        "Add a video",
                        systemImage: "video.badge.plus",
                        description: Text(
                            "Record one display or window, or import an MP4 or QuickTime MOV."
                        )
                    )
                }
            }
        } else {
            ContentUnavailableView(
                "Recording not found",
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    /// Uses the same value-edit pipeline for every native inspector. Click time
    /// edits reanchor before remapping and invalid edits leave the stored project intact.
    func projectBinding(for fallback: DemoProject) -> Binding<DemoProject> {
        Binding(
            get: { store.project(id: projectID) ?? fallback },
            set: {
                do {
                    let current = store.project(id: projectID) ?? fallback
                    let cards = try DemoEffectEditor.reconcileCardEdit(from: current, to: $0)
                    let cues = try ClickCueEditor.reconcileTimeEdits(from: current, to: cards)
                    let timed = try SceneTiming.reanchorTimeEdits(
                        from: current, to: cues
                    )
                    let reanchored =
                    try VideoTimelineEditor.reanchorChangedContentEffectTimes(
                        from: store.project(id: projectID) ?? fallback,
                        to: timed
                    )
                    store.replaceProject(VideoTimelineEditor.remapContentLayers(reanchored))
                } catch { store.errorMessage = error.localizedDescription }
            }
        )
    }
}

private struct ProjectHeader: View {
    @Binding var project: DemoProject

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Recording name", text: $project.name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                Text(projectSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var projectSummary: String {
        if let recording = project.recording {
            return "\(Self.time(recording.duration)) · \(project.clicks.count) clicks · \(project.subtitles.count) subtitles"
        }
        if !project.steps.isEmpty {
            return "Legacy screenshot project · \(project.steps.count) screens"
        }
        return "No video"
    }

    private static func time(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
