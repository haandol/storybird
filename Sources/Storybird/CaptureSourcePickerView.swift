import SwiftUI

struct CaptureSourcePickerView: View {
    @ObservedObject var recorder: RecordingCoordinator

    private let columns = [
        GridItem(.adaptive(minimum: 205, maximum: 245), spacing: 12),
    ]

    private var displays: [CaptureSource] {
        recorder.captureSources.filter { $0.kind == .display }
    }

    private var windows: [CaptureSource] {
        recorder.captureSources.filter { $0.kind == .window }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Choose what to record")
                        .font(.title2.weight(.semibold))
                    Text("Select an entire display or one open window. You do not need to bring each window to the front to inspect it.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    recorder.cancelSourcePicker()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(18)

            Divider()

            if recorder.isLoadingSources {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Capturing window previews…")
                        .font(.headline)
                    Text("Storybird is collecting local thumbnails for the selection gallery.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if recorder.captureSources.isEmpty {
                ContentUnavailableView(
                    "No recordable windows",
                    systemImage: "macwindow.badge.xmark",
                    description: Text("Open a product window and try again.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !displays.isEmpty {
                            SourceSection(
                                title: "Entire screens",
                                sources: displays,
                                columns: columns,
                                onSelect: recorder.selectCaptureSource
                            )
                        }

                        if !windows.isEmpty {
                            SourceSection(
                                title: "Windows",
                                sources: windows,
                                columns: columns,
                                onSelect: recorder.selectCaptureSource
                            )
                        }
                    }
                    .padding(18)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SourceSection: View {
    let title: String
    let sources: [CaptureSource]
    let columns: [GridItem]
    let onSelect: (CaptureSource) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Text("\(sources.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(sources) { source in
                    CaptureSourceCard(
                        source: source,
                        onSelect: { onSelect(source) }
                    )
                }
            }
        }
    }
}

private struct CaptureSourceCard: View {
    let source: CaptureSource
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color.black.opacity(0.84))

                    if let thumbnail = source.thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(7)
                    } else {
                        Image(
                            systemName: source.kind == .display
                                ? "display"
                                : "macwindow"
                        )
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.white.opacity(0.62))
                    }
                }
                .frame(height: 112)

                HStack(spacing: 9) {
                    Image(
                        systemName: source.kind == .display
                            ? "display"
                            : "macwindow"
                    )
                    .foregroundStyle(Color(hex: "#5B5CE2"))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(source.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        isHovering
                            ? Color(hex: "#5B5CE2").opacity(0.10)
                            : Color(nsColor: .controlBackgroundColor)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isHovering
                            ? Color(hex: "#5B5CE2").opacity(0.8)
                            : Color.secondary.opacity(0.16),
                        lineWidth: isHovering ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(
            "\(source.title), \(source.subtitle)"
        )
        .help("Record \(source.title)")
    }
}
