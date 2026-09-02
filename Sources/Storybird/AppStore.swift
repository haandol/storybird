import AppKit
import Combine
import Foundation
import StorybirdCore

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var projects: [DemoProject] = []
    @Published var selectedProjectID: UUID?
    @Published var errorMessage: String?
    @Published var permissionPrompt: RecordingPermissionPrompt?

    let repository: ProjectRepository

    init(repository: ProjectRepository? = nil) {
        let resolvedRepository: ProjectRepository
        do {
            resolvedRepository = try repository ?? .live()
        } catch {
            let fallback = ProjectRepository(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("Storybird", isDirectory: true)
            )
            self.repository = fallback
            projects = []
            errorMessage = "Storybird could not open its library: \(error.localizedDescription)"
            return
        }

        self.repository = resolvedRepository
        do {
            projects = try resolvedRepository.loadProjects()
            selectedProjectID = projects.first?.id
        } catch {
            projects = []
            errorMessage = "Storybird could not open its library: \(error.localizedDescription)"
        }
    }

    var selectedProject: DemoProject? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    func project(id: UUID) -> DemoProject? {
        projects.first { $0.id == id }
    }

    func createProject(name: String = "Untitled demo") -> UUID {
        let project = DemoProject(name: name)
        projects.insert(project, at: 0)
        selectedProjectID = project.id
        persist()
        return project.id
    }

    func createSampleProject() {
        let project = DemoProject(
            name: "Storybird product tour",
            summary: "A three-step sample made entirely on this Mac."
        )

        do {
            var completed = project
            let screens = SampleArtGenerator.makeScreens()
            completed.steps = try screens.enumerated().map { index, screen in
                let filename = try repository.writeImage(
                    screen.image,
                    projectID: project.id
                )
                return DemoStep(
                    title: screen.title,
                    caption: screen.caption,
                    assetFilename: filename
                )
            }

            if completed.steps.count == 3 {
                completed.steps[0].hotspots = [
                    Hotspot(
                        x: 0.77,
                        y: 0.16,
                        title: "Create a new demo",
                        body: "Start with a capture or a set of screenshots.",
                        targetStepID: completed.steps[1].id
                    ),
                ]
                completed.steps[1].hotspots = [
                    Hotspot(
                        x: 0.69,
                        y: 0.52,
                        kind: .information,
                        title: "Guide the viewer",
                        body: "Place hotspots directly on the screen, then choose where each one leads.",
                        targetStepID: completed.steps[2].id
                    ),
                ]
                completed.steps[2].hotspots = [
                    Hotspot(
                        x: 0.84,
                        y: 0.16,
                        title: "Export the experience",
                        body: "Storybird creates a standalone web demo.",
                        targetStepID: nil
                    ),
                ]
            }

            projects.insert(completed, at: 0)
            selectedProjectID = completed.id
            persist()
        } catch {
            errorMessage = "The sample could not be created: \(error.localizedDescription)"
        }
    }

    func replaceProject(_ project: DemoProject) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else {
            return
        }
        var updated = project
        updated.updatedAt = Date()
        projects[index] = updated
        persist()
    }

    @discardableResult
    func beginRecordedFlow(
        with image: NSImage,
        in projectID: UUID
    ) throws -> UUID {
        guard let projectIndex = projects.firstIndex(where: {
            $0.id == projectID
        }) else {
            throw RecordingStoreError.projectNotFound
        }

        let filename = try repository.writeImage(
            image,
            projectID: projectID
        )
        let step = DemoStep(
            title: "Recorded screen \(projects[projectIndex].steps.count + 1)",
            caption: "Captured when recording started.",
            assetFilename: filename
        )
        projects[projectIndex].steps.append(step)
        projects[projectIndex].updatedAt = Date()
        persist()
        return step.id
    }

    @discardableResult
    func appendRecordedClick(
        at normalizedPoint: CGPoint,
        resultingImage: NSImage,
        from sourceStepID: UUID,
        in projectID: UUID
    ) throws -> UUID {
        guard let projectIndex = projects.firstIndex(where: {
            $0.id == projectID
        }) else {
            throw RecordingStoreError.projectNotFound
        }
        let filename = try repository.writeImage(
            resultingImage,
            projectID: projectID
        )
        let nextStep = DemoStep(
            title: "Recorded screen \(projects[projectIndex].steps.count + 1)",
            caption: "Captured after click \(projects[projectIndex].steps.count).",
            assetFilename: filename
        )
        try RecordedFlowBuilder.append(
            nextStep: nextStep,
            clickPoint: normalizedPoint,
            from: sourceStepID,
            to: &projects[projectIndex]
        )
        persist()
        return nextStep.id
    }

    func deleteProject(id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            return
        }

        do {
            try repository.removeProjectAssets(projectID: id)
        } catch {
            errorMessage = "Some project files could not be removed: \(error.localizedDescription)"
        }

        projects.remove(at: index)
        if selectedProjectID == id {
            selectedProjectID = projects.first?.id
        }
        persist()
    }

    func deleteStep(projectID: UUID, stepID: UUID) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let stepIndex = projects[projectIndex].steps.firstIndex(where: {
                  $0.id == stepID
              })
        else {
            return
        }

        let filename = projects[projectIndex].steps[stepIndex].assetFilename
        projects[projectIndex].steps.remove(at: stepIndex)
        for index in projects[projectIndex].steps.indices {
            for hotspotIndex in projects[projectIndex].steps[index].hotspots.indices
            where projects[projectIndex].steps[index].hotspots[hotspotIndex].targetStepID == stepID {
                projects[projectIndex].steps[index].hotspots[hotspotIndex].targetStepID = nil
            }
        }
        projects[projectIndex].updatedAt = Date()
        try? repository.removeAsset(projectID: projectID, filename: filename)
        persist()
    }

    func moveStep(projectID: UUID, stepID: UUID, offset: Int) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let source = projects[projectIndex].steps.firstIndex(where: {
                  $0.id == stepID
              })
        else {
            return
        }
        let destination = source + offset
        guard projects[projectIndex].steps.indices.contains(destination) else {
            return
        }
        projects[projectIndex].steps.swapAt(source, destination)
        projects[projectIndex].updatedAt = Date()
        persist()
    }

    func record(_ event: AnalyticsEvent, in projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else {
            return
        }
        projects[index].events.append(event)
        persist()
    }

    func clearAnalytics(projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else {
            return
        }
        projects[index].events = []
        projects[index].updatedAt = Date()
        persist()
    }

    private func persist() {
        do {
            try repository.saveProjects(projects)
        } catch {
            errorMessage = "Changes could not be saved: \(error.localizedDescription)"
        }
    }
}

enum RecordingStoreError: LocalizedError {
    case projectNotFound

    var errorDescription: String? {
        switch self {
        case .projectNotFound:
            return "The recording project no longer exists."
        }
    }
}

struct RecordingPermissionPrompt: Identifiable {
    enum Kind: String {
        case screenRecording
        case inputMonitoring
    }

    let kind: Kind
    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .screenRecording:
            return "Allow Screen Recording"
        case .inputMonitoring:
            return "Allow Input Monitoring"
        }
    }

    var message: String {
        switch kind {
        case .screenRecording:
            return "Storybird needs Screen Recording access to save the screen that appears after each click."
        case .inputMonitoring:
            return "Storybird needs Input Monitoring access to observe mouse clicks during a recording session. Keyboard input is not recorded."
        }
    }

    var settingsURL: URL? {
        let pane: String
        switch kind {
        case .screenRecording:
            pane = "Privacy_ScreenCapture"
        case .inputMonitoring:
            pane = "Privacy_ListenEvent"
        }
        return URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        )
    }
}
