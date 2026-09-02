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
                    _ = store.createProject()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New demo")
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
                    Text("No demos yet")
                        .font(.subheadline.weight(.medium))
                    Text("Create a blank project or start with the sample.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(24)
            } else {
                List(selection: $store.selectedProjectID) {
                    Section("Demos") {
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

            HStack {
                Button {
                    store.createSampleProject()
                } label: {
                    Label("Add Sample", systemImage: "sparkles")
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Spacer()

                Text("\(store.projects.count) demo\(store.projects.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
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
                Image(systemName: "cursorarrow.motionlines")
                    .foregroundStyle(Color(hex: project.theme.accentHex))
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .lineLimit(1)
                Text("\(project.steps.count) screens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
