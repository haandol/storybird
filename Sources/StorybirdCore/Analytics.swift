import Foundation

public struct AnalyticsSummary: Equatable, Sendable {
    public struct StepResult: Identifiable, Equatable, Sendable {
        public var id: UUID
        public var title: String
        public var views: Int
        public var clicks: Int

        public init(id: UUID, title: String, views: Int, clicks: Int) {
            self.id = id
            self.title = title
            self.views = views
            self.clicks = clicks
        }
    }

    public var sessions: Int
    public var completedSessions: Int
    public var hotspotClicks: Int
    public var completionRate: Double
    public var stepResults: [StepResult]
    public var recentEvents: [AnalyticsEvent]

    public init(project: DemoProject) {
        let started = Set(
            project.events
                .filter { $0.type == .sessionStarted }
                .map(\.sessionID)
        )
        let completed = Set(
            project.events
                .filter { $0.type == .completed }
                .map(\.sessionID)
        )

        sessions = started.count
        completedSessions = completed.intersection(started).count
        hotspotClicks = project.events.filter { $0.type == .hotspotClicked }.count
        completionRate = sessions == 0
            ? 0
            : Double(completedSessions) / Double(sessions)
        stepResults = project.steps.map { step in
            StepResult(
                id: step.id,
                title: step.title,
                views: project.events.filter {
                    $0.type == .stepViewed && $0.stepID == step.id
                }.count,
                clicks: project.events.filter {
                    $0.type == .hotspotClicked && $0.stepID == step.id
                }.count
            )
        }
        recentEvents = Array(
            project.events
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(12)
        )
    }
}
