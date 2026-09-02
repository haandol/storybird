import StorybirdCore
import SwiftUI

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case editor = "Editor"
    case insights = "Insights"

    var id: String { rawValue }
}

struct ProjectWorkspaceView: View {
    @ObservedObject var store: AppStore
    let projectID: UUID

    @State private var mode: WorkspaceMode = .editor
    @State private var selectedStepID: UUID?
    @State private var selectedHotspotID: UUID?
    @State private var isAddingHotspot = false

    var body: some View {
        if let project = store.project(id: projectID) {
            let projectBinding = Binding(
                get: { store.project(id: projectID) ?? project },
                set: { store.replaceProject($0) }
            )

            VStack(spacing: 0) {
                ProjectHeader(project: projectBinding, mode: $mode)
                Divider()

                switch mode {
                case .editor:
                    DemoEditorView(
                        store: store,
                        project: projectBinding,
                        selectedStepID: $selectedStepID,
                        selectedHotspotID: $selectedHotspotID,
                        isAddingHotspot: $isAddingHotspot
                    )
                case .insights:
                    InsightsView(
                        project: project,
                        onClear: {
                            store.clearAnalytics(projectID: projectID)
                        }
                    )
                }
            }
            .onAppear {
                ensureStepSelection(for: project)
            }
            .onChange(of: project.steps.map(\.id)) { _, _ in
                ensureStepSelection(for: store.project(id: projectID) ?? project)
            }
        } else {
            ContentUnavailableView(
                "Demo not found",
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private func ensureStepSelection(for project: DemoProject) {
        if let selectedStepID,
           project.steps.contains(where: { $0.id == selectedStepID }) {
            return
        }
        selectedStepID = project.steps.first?.id
        selectedHotspotID = nil
        isAddingHotspot = false
    }
}

private struct ProjectHeader: View {
    @Binding var project: DemoProject
    @Binding var mode: WorkspaceMode

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Demo name", text: $project.name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                Text(project.steps.isEmpty
                     ? "Press Record Flow to capture the first interactive path."
                     : "\(project.steps.count) screens · Updated \(project.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Workspace", selection: $mode) {
                ForEach(WorkspaceMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
