import AppKit
import StorybirdCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: AppStore
    @StateObject private var recorder: RecordingCoordinator

    @State private var isPreviewPresented = false
    @State private var projectPendingDeletion: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isCompactWindow = false

    init(store: AppStore) {
        self.store = store
        _recorder = StateObject(
            wrappedValue: RecordingCoordinator(store: store)
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectSidebar(
                store: store,
                projectPendingDeletion: $projectPendingDeletion
            )
            .navigationSplitViewColumnWidth(min: 185, ideal: 220, max: 270)
        } detail: {
            if let projectID = store.selectedProjectID,
               store.project(id: projectID) != nil {
                ProjectWorkspaceView(store: store, projectID: projectID)
                    .id(projectID)
            } else {
                WelcomeView(
                    store: store,
                    onRecord: startRecording
                )
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: WindowWidthPreferenceKey.self,
                    value: proxy.size.width
                )
            }
        }
        .onPreferenceChange(WindowWidthPreferenceKey.self) { width in
            let compact = width < 900
            guard compact != isCompactWindow else { return }
            isCompactWindow = compact
            columnVisibility = compact ? .detailOnly : .all
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if recorder.isActive {
                        recorder.stop()
                    } else {
                        startRecording()
                    }
                } label: {
                    Label(
                        recorder.toolbarTitle,
                        systemImage: recorder.isActive
                            ? "stop.circle.fill"
                            : "record.circle"
                    )
                }
                .tint(.red)
                .help("Record clicks and turn each resulting screen into a step")

                Button {
                    isPreviewPresented = true
                } label: {
                    Label("Preview", systemImage: "play.fill")
                }
                .disabled(
                    store.selectedProject?.steps.isEmpty != false
                        || recorder.isActive
                )
                .help("Play this demo")

                Button {
                    exportDemo()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(
                    store.selectedProject?.steps.isEmpty != false
                        || recorder.isActive
                )
                .help("Export a standalone web demo")
            }
        }
        .sheet(isPresented: $isPreviewPresented) {
            if let projectID = store.selectedProjectID {
                DemoPreviewView(store: store, projectID: projectID)
                    .frame(width: 760, height: 560)
            }
        }
        .sheet(isPresented: $recorder.isSourcePickerPresented) {
            CaptureSourcePickerView(recorder: recorder)
                .frame(width: 680, height: 480)
                .interactiveDismissDisabled()
        }
        .alert(
            "Storybird",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .alert(item: $store.permissionPrompt) { prompt in
            Alert(
                title: Text(prompt.title),
                message: Text(
                    "\(prompt.message) Enable it in System Settings, then return to Storybird and press Record Flow again."
                ),
                primaryButton: .default(Text("Open System Settings")) {
                    if let url = prompt.settingsURL {
                        NSWorkspace.shared.open(url)
                    }
                    store.permissionPrompt = nil
                },
                secondaryButton: .cancel {
                    store.permissionPrompt = nil
                }
            )
        }
        .confirmationDialog(
            "Delete this demo?",
            isPresented: Binding(
                get: { projectPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        projectPendingDeletion = nil
                    }
                }
            )
        ) {
            Button("Delete Demo", role: .destructive) {
                if let id = projectPendingDeletion {
                    store.deleteProject(id: id)
                }
                projectPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                projectPendingDeletion = nil
            }
        } message: {
            Text("Its screens and local analytics will be removed from this Mac.")
        }
    }

    private func startRecording() {
        let projectID = store.selectedProjectID
            ?? store.createProject(name: "Recorded flow")
        recorder.start(projectID: projectID)
    }

    private func exportDemo() {
        guard let project = store.selectedProject else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose an export folder"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK,
              let parentDirectory = panel.url
        else {
            return
        }

        do {
            let exporter = StaticDemoExporter()
            let destination = try exporter.export(
                project: project,
                sourceAssetsDirectory: store.repository.assetsDirectory(
                    projectID: project.id
                ),
                into: parentDirectory
            )
            NSWorkspace.shared.activateFileViewerSelecting([
                destination.appendingPathComponent("index.html"),
            ])
        } catch {
            store.errorMessage = "The demo could not be exported: \(error.localizedDescription)"
        }
    }
}

private struct WindowWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 1000

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
