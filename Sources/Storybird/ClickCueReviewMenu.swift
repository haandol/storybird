import StorybirdCore
import SwiftUI

/// A read-only route from the timeline to every Cue that still blocks export.
struct ClickCueReviewMenu: View {
    let clicks: [TimedPointerClick]
    let onSelect: (UUID) -> Void

    private var incomplete: [TimedPointerClick] { clicks.filter { !$0.isComplete } }

    var body: some View {
        Menu {
            if incomplete.isEmpty {
                Text("All click descriptions and subtitles are complete.")
            } else {
                ForEach(incomplete) { click in
                    Button {
                        onSelect(click.id)
                    } label: {
                        Text("\(String(format: "%.2fs", click.time)) · \(Self.missingText(click))")
                    }
                }
            }
        } label: {
            Label(
                incomplete.isEmpty ? "Clicks complete" : "\(incomplete.count) incomplete clicks",
                systemImage: incomplete.isEmpty ? "checkmark.circle" : "exclamationmark.triangle"
            )
        }
        .foregroundStyle(incomplete.isEmpty ? Color.secondary : .orange)
        .accessibilityIdentifier("timeline-incomplete-cues")
        .help("Complete every click description and subtitle before exporting.")
    }

    /// Names only the missing slots, using the same whitespace rule as Cue completeness.
    static func missingText(_ click: TimedPointerClick) -> String {
        var fields: [String] = []
        if click.description.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields.append("description")
        }
        if click.cueSubtitle.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields.append("subtitle")
        }
        return "Missing " + fields.joined(separator: " and ")
    }
}

enum VideoExportAvailability {
    /// The native button and shortcut use the exporter's existing value-validation
    /// gate, so incomplete Cues cannot look ready to export.
    static func isReady(_ project: DemoProject?) -> Bool {
        guard let project else { return false }
        return (try? LayeredVideoExporter.validateForExport(project)) != nil
    }
}
