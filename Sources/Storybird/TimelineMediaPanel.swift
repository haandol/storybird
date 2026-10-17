import AppKit
import StorybirdCore
import SwiftUI
import UniformTypeIdentifiers

struct TimelineMediaPanel: View {
    private struct ImagePlacement: Identifiable {
        let asset: ProjectMediaAsset
        let revision: Int
        let destination: Int
        var id: UUID { asset.id }
    }
    @ObservedObject var store: AppStore
    let projectID: UUID
    let playhead: Double
    let onPlaced: (UUID) -> Void
    @State private var importing = false
    @State private var errorMessage: String?
    @State private var imageToPlace: ImagePlacement?
    @State private var imageDuration = ""
    @State private var placementError: String?
    @State private var importJobID: UUID?
    var chooseFile: @MainActor () -> URL? = {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .png, .jpeg]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Project media", systemImage: "photo.on.rectangle").font(.headline)
                Spacer()
                Button("Import…", action: importMedia)
                    .disabled(importing)
                    .accessibilityIdentifier("timeline-media-import")
            }
            if importing {
                HStack {
                    ProgressView("Importing media…").controlSize(.small)
                    if let importJobID {
                        Button("Cancel") { _ = try? store.mediaImports.cancel(id: importJobID) }
                    }
                }
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            ScrollView {
                if let project = store.project(id: projectID) {
                    LazyVStack(spacing: 10) {
                        ForEach(project.availableMediaAssets) { asset in
                            HStack(spacing: 8) {
                                MediaCardThumbnail(asset: asset,
                                    url: store.repository.assetURL(projectID: projectID, filename: asset.filename))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(asset.name).font(.caption.weight(.semibold)).lineLimit(2)
                                    Text("\(asset.width) × \(asset.height)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    if let duration = asset.duration {
                                        Text("\(duration, format: .number.precision(.fractionLength(2)))s")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                Button("Add") {
                                    if asset.kind == .image {
                                        imageDuration = ""; placementError = nil
                                        imageToPlace = ImagePlacement(asset: asset, revision: project.revision,
                                            destination: destination(in: project))
                                    } else { _ = place(asset, duration: nil, revision: project.revision, destination: destination(in: project)) }
                                }
                                .accessibilityIdentifier("media-place-\(asset.id.uuidString)")
                            }
                            .padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            Text("Add at the clip boundary nearest the playhead. Source files remain reusable.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .sheet(item: $imageToPlace) { placement in
            VStack(alignment: .leading, spacing: 16) {
                Text("Place image").font(.headline)
                Text(placement.asset.name)
                TextField("Duration in seconds", text: $imageDuration)
                    .accessibilityIdentifier("image-placement-duration")
                if let placementError { Text(placementError).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Cancel") { imageToPlace = nil }
                    Spacer()
                    Button("Add") {
                        if let value = Double(imageDuration), value.isFinite, value > 0 {
                            if place(placement.asset, duration: value, revision: placement.revision,
                                     destination: placement.destination) { imageToPlace = nil }
                        }
                    }
                    .disabled(Double(imageDuration).map { !$0.isFinite || $0 <= 0 } ?? true)
                    .keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 320)
        }
    }

    private func importMedia() {
        guard let url = chooseFile() else { return }
        importing = true; errorMessage = nil
        Task {
            defer { importing = false; importJobID = nil }
            do {
                var job = try store.mediaImports.start(kind: .media, path: url.path, projectID: projectID,
                    key: UUID().uuidString, nativeSource: url)
                importJobID = job.jobID
                while job.state == .importing {
                    try await Task.sleep(for: .milliseconds(100))
                    job = try store.mediaImports.get(id: job.jobID)
                }
                if job.state == .failed { errorMessage = job.error ?? "Media import failed." }
            }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func destination(in project: DemoProject) -> Int {
        let clips = VideoTimelineSchedule(project: project).items.compactMap { item -> VideoTimelineSchedule.ScheduledClip? in
            if case let .clip(value) = item { return value }; return nil
        }
        return clips.firstIndex { playhead < ($0.projectStart + $0.projectEnd) / 2 } ?? clips.count
    }

    /// The selected slot is a view choice; placement always uses the current
    /// revision and the same app-owned command as MCP.
    private func place(_ asset: ProjectMediaAsset, duration: Double?, revision: Int, destination: Int) -> Bool {
        guard let project = store.project(id: projectID) else { return false }
        do {
            let edited = try store.placeMediaAsset(projectID: projectID, assetID: asset.id,
                expectedRevision: revision, destination: destination, duration: duration)
            if let added = edited.clips.first(where: { candidate in !project.clips.contains { $0.id == candidate.id } }) {
                onPlaced(added.id)
            }
            errorMessage = nil
            placementError = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            placementError = error.localizedDescription
            return false
        }
    }
}

private struct MediaCardThumbnail: View {
    let asset: ProjectMediaAsset
    let url: URL
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else { Image(systemName: asset.kind == .image ? "photo" : "film").foregroundStyle(.secondary) }
        }
        .frame(width: 64, height: 46)
        .task(id: url) { image = try? await ProjectMediaFiles.preview(asset: asset, url: url).image }
    }
}
