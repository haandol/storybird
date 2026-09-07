import Foundation
import StorybirdCore
import SwiftUI

struct ProjectWorkspaceView: View {
    @ObservedObject var store: AppStore
    let projectID: UUID

    var body: some View {
        if let project = store.project(id: projectID) {
            let projectBinding = Binding(
                get: { store.project(id: projectID) ?? project },
                set: {
                    store.replaceProject(
                        VideoTimelineEditor.remapContentLayers($0)
                    )
                }
            )

            VStack(spacing: 0) {
                ProjectHeader(project: projectBinding)
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
                        "Record a video",
                        systemImage: "record.circle",
                        description: Text(
                            "Choose Record Video to capture one display or window."
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
        return "No video recorded"
    }

    private static func time(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
