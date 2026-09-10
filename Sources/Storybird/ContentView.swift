import AppKit
import StorybirdCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: AppStore
    @StateObject private var recorder: RecordingCoordinator
    let commandCenter: StorybirdCommandCenter

    @State private var projectPendingDeletion: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isCompactWindow = false
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportProgress = 0.0
    @State private var exportTask: Task<Void, Never>?
    @State private var commandOwnerID = UUID()

    init(
        store: AppStore,
        commandCenter: StorybirdCommandCenter
    ) {
        self.store = store
        self.commandCenter = commandCenter
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
                    .id("\(store.repository.rootURL.path):\(projectID)")
            } else {
                WelcomeView(
                    store: store,
                    onRecord: startRecording,
                    onImport: importVideo
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
        .onChange(of: store.requestedPreviewProjectID) { _, projectID in
            guard let projectID, store.project(id: projectID) != nil else {
                return
            }
            store.selectedProjectID = projectID
            store.requestedPreviewProjectID = nil
        }
        .onChange(of: store.repository.rootURL) { _, _ in
            projectPendingDeletion = nil
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
                .disabled(!canToggleRecording)
                .help("Record one display or window as continuous video")

                Button {
                    importVideo()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .disabled(!canImportVideo)
                .help("Import an MP4 or QuickTime MOV as a new project")

                Button {
                    NotificationCenter.default.post(name: .storybirdOpenProjectAudio, object: store.selectedProjectID)
                } label: {
                    Label("Audio", systemImage: "waveform")
                }
                .disabled(store.selectedProject?.recording == nil)
                .help("Open project audio beside the timeline")

                Button {
                    exportVideo()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(!canExportVideo)
                .help("Export an MP4 with click and subtitle layers")
            }
        }
        .sheet(isPresented: $recorder.isSourcePickerPresented) {
            CaptureSourcePickerView(recorder: recorder)
                .frame(width: 680, height: 480)
                .interactiveDismissDisabled()
        }
        .overlay {
            if isExporting || isImporting {
                ZStack {
                    Color.black.opacity(0.24)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        if isExporting {
                            ProgressView(value: exportProgress)
                                .frame(width: 240)
                        } else {
                            ProgressView()
                        }
                        Text(isExporting ? "Rendering video…" : "Importing video…")
                            .font(.headline)
                        if isExporting {
                            Button("Cancel") {
                                exportTask?.cancel()
                            }
                        }
                    }
                    .padding(24)
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                }
            }
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
                    "\(prompt.message) Enable it in System Settings, then return to Storybird and press Record Video again."
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
        .alert(item: $store.externalControlPrompt) { prompt in
            Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                primaryButton: .default(
                    Text(prompt.destructive ? "Delete" : "Allow")
                ) {
                    store.resolveExternalControlApproval(true)
                },
                secondaryButton: .cancel {
                    store.resolveExternalControlApproval(false)
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
            Text("Its original recording and timeline layers will be removed from this Mac.")
        }
        .onAppear {
            installCommandHandlers()
        }
        .onDisappear {
            commandCenter.uninstall(ownerID: commandOwnerID)
        }
    }

    private func startRecording() {
        recorder.start()
    }

    /// Opens a native, user-scoped movie picker and publishes a new project only
    /// after the selected source has been copied and validated.
    private func importVideo() {
        let panel = NSOpenPanel()
        panel.title = "Import a Storybird Video"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let sourceURL = panel.url else {
            return
        }
        isImporting = true
        Task {
            do {
                _ = try await store.importVideo(from: sourceURL)
                isImporting = false
            } catch is CancellationError {
                isImporting = false
            } catch {
                isImporting = false
                store.errorMessage =
                    "The video could not be imported: \(error.localizedDescription)"
            }
        }
    }

    private var canImportVideo: Bool {
        !recorder.isActive && !isImporting && !isExporting
    }

    private var canToggleRecording: Bool {
        !isImporting && !isExporting
    }

    private var canExportVideo: Bool {
        VideoExportAvailability.isReady(store.selectedProject)
            && !recorder.isActive
            && !isImporting
            && !isExporting
            && !store.isExportActive
    }

    /// Routes local shortcuts and menu commands through the same state checks
    /// and action methods used by the visible project toolbar.
    private func installCommandHandlers() {
        commandCenter.install(
            ownerID: commandOwnerID,
            handlers: [
                .newProject: .init(
                    isEnabled: {
                        !recorder.isActive
                            && !isImporting
                            && !isExporting
                    },
                    perform: {
                        _ = store.createProject(
                            name: "Untitled recording"
                        )
                    }
                ),
                .toggleRecording: .init(
                    isEnabled: { canToggleRecording },
                    perform: {
                        if recorder.isActive {
                            recorder.stop()
                        } else {
                            startRecording()
                        }
                    }
                ),
                .importVideo: .init(
                    isEnabled: { canImportVideo },
                    perform: { importVideo() }
                ),
                .exportVideo: .init(
                    isEnabled: { canExportVideo },
                    perform: { exportVideo() }
                ),
            ]
        )
    }

    private func exportVideo() {
        guard let project = store.selectedProject,
              let recording = project.recording,
              !project.clips.isEmpty
        else {
            return
        }

        let exportID: UUID
        do {
            exportID = try store.beginExport()
        } catch {
            store.errorMessage = error.localizedDescription
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Storybird Video"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "\(slug(project.name)).mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            store.endExport(exportID)
            return
        }
        let sourceURL = store.repository.assetURL(
            projectID: project.id,
            filename: recording.filename
        )
        isExporting = true
        exportProgress = 0
        exportTask = Task {
            defer {
                store.endExport(exportID)
            }
            do {
                let exporter = LayeredVideoExporter()
                let result = try await exporter.export(
                    project: project,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL
                ) { progress in
                    Task { @MainActor in
                        exportProgress = progress
                    }
                }
                isExporting = false
                exportTask = nil
                NSWorkspace.shared.activateFileViewerSelecting([result])
            } catch is CancellationError {
                isExporting = false
                exportTask = nil
            } catch {
                isExporting = false
                exportTask = nil
                store.errorMessage =
                    "The video could not be exported: \(error.localizedDescription)"
            }
        }
    }

    private func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let pieces = value.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let collapsed = String(pieces)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "storybird-video" : collapsed
    }
}

private struct WindowWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 1000

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
