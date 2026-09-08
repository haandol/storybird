import StorybirdCore
import SwiftUI

struct ProjectSidebar: View {
    @ObservedObject var store: AppStore
    @Binding var projectPendingDeletion: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                StorybirdMark(size: 30)
                Text("Storybird")
                    .font(.headline)
                Spacer()
                Button {
                    _ = store.createProject(name: "Untitled recording")
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New recording project")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if store.projects.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No videos yet")
                        .font(.subheadline.weight(.medium))
                    Text("Import an existing video or record one display or window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(24)
            } else {
                List(selection: $store.selectedProjectID) {
                    Section("Projects") {
                        ForEach(store.projects) { project in
                            ProjectSidebarRow(project: project)
                                .tag(project.id)
                                .contextMenu {
                                    Button("Delete", role: .destructive) {
                                        projectPendingDeletion = project.id
                                    }
                                }
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()

            Text("\(store.projects.count) project\(store.projects.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(12)
        }
    }
}

private struct ProjectSidebarRow: View {
    let project: DemoProject

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(hex: project.theme.accentHex).opacity(0.14))
                Image(systemName: "video.fill")
                    .foregroundStyle(Color(hex: project.theme.accentHex))
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var detail: String {
        if let recording = project.recording {
            let seconds = max(Int(recording.duration.rounded()), 0)
            return String(
                format: "%d:%02d · %d clicks",
                seconds / 60,
                seconds % 60,
                project.clicks.count
            )
        }
        return project.steps.isEmpty
            ? "No video"
            : "Legacy screenshot project"
    }
}
