import StorybirdCore
import SwiftUI

struct InsightsView: View {
    let project: DemoProject
    let onClear: () -> Void

    private var summary: AnalyticsSummary {
        AnalyticsSummary(project: project)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local preview analytics")
                            .font(.title2.weight(.semibold))
                        Text("These events come from previews played on this Mac.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear Events", role: .destructive, action: onClear)
                        .disabled(project.events.isEmpty)
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                    ],
                    spacing: 14
                ) {
                    InsightMetric(
                        title: "Sessions",
                        value: "\(summary.sessions)",
                        icon: "play.circle.fill",
                        color: Color(hex: "#5B5CE2")
                    )
                    InsightMetric(
                        title: "Completed",
                        value: "\(summary.completedSessions)",
                        icon: "checkmark.circle.fill",
                        color: .green
                    )
                    InsightMetric(
                        title: "Completion",
                        value: summary.completionRate.formatted(.percent.precision(.fractionLength(0))),
                        icon: "chart.line.uptrend.xyaxis",
                        color: .teal
                    )
                    InsightMetric(
                        title: "Hotspot clicks",
                        value: "\(summary.hotspotClicks)",
                        icon: "cursorarrow.click.2",
                        color: .orange
                    )
                }

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Screen engagement")
                            .font(.headline)

                        if summary.stepResults.isEmpty {
                            EmptyInsight(text: "Add screens to see engagement.")
                        } else {
                            ForEach(summary.stepResults) { result in
                                StepEngagementRow(
                                    result: result,
                                    maximumViews: max(
                                        summary.stepResults.map(\.views).max() ?? 0,
                                        1
                                    ),
                                    accent: Color(hex: project.theme.accentHex)
                                )
                            }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.secondary.opacity(0.14))
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recent activity")
                            .font(.headline)

                        if summary.recentEvents.isEmpty {
                            EmptyInsight(text: "Play a preview to create the first session.")
                        } else {
                            ForEach(summary.recentEvents) { event in
                                HStack(spacing: 10) {
                                    Image(systemName: event.type.systemImage)
                                        .frame(width: 22)
                                        .foregroundStyle(
                                            Color(hex: project.theme.accentHex)
                                        )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.type.displayName)
                                            .font(.callout.weight(.medium))
                                        Text(
                                            event.timestamp.formatted(
                                                date: .abbreviated,
                                                time: .shortened
                                            )
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                if event.id != summary.recentEvents.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .padding(18)
                    .frame(width: 330, alignment: .topLeading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.secondary.opacity(0.14))
                    )
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }
}

private struct InsightMetric: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Spacer()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.14))
        )
    }
}

private struct StepEngagementRow: View {
    let result: AnalyticsSummary.StepResult
    let maximumViews: Int
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(result.title)
                    .lineLimit(1)
                Spacer()
                Text("\(result.views) views · \(result.clicks) clicks")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill(accent)
                        .frame(
                            width: proxy.size.width
                                * CGFloat(result.views)
                                / CGFloat(maximumViews)
                        )
                }
            }
            .frame(height: 7)
        }
        .padding(.vertical, 3)
    }
}

private struct EmptyInsight: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(
                Color.secondary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 10)
            )
    }
}
