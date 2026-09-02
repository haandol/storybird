import AppKit
import StorybirdCore
import SwiftUI

struct DemoPreviewView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var store: AppStore
    let projectID: UUID

    @State private var currentStepID: UUID?
    @State private var informationHotspot: Hotspot?
    @State private var sessionID = UUID()
    @State private var didStartSession = false
    @State private var didComplete = false

    var body: some View {
        if let project = store.project(id: projectID),
           let currentIndex = currentIndex(in: project),
           project.steps.indices.contains(currentIndex) {
            let step = project.steps[currentIndex]
            ZStack {
                Color(hex: project.theme.backgroundHex)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("INTERACTIVE DEMO")
                                .font(.caption2.weight(.bold))
                                .tracking(1.6)
                                .foregroundStyle(.white.opacity(0.56))
                            Text(step.title)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        Text("\(currentIndex + 1) / \(project.steps.count)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.62))
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(.white.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                    }

                    PreviewStage(
                        step: step,
                        imageURL: store.repository.assetURL(
                            projectID: project.id,
                            filename: step.assetFilename
                        ),
                        accent: Color(hex: project.theme.accentHex),
                        onHotspot: { hotspot in
                            activate(hotspot, step: step, project: project)
                        }
                    )

                    HStack(spacing: 14) {
                        Spacer()

                        Button("Back") {
                            move(to: currentIndex - 1, in: project)
                        }
                        .buttonStyle(
                            PreviewNavigationButtonStyle(
                                color: .white.opacity(0.12)
                            )
                        )
                        .disabled(currentIndex == 0)

                        Button(currentIndex == project.steps.count - 1 ? "Finish" : "Next") {
                            if currentIndex == project.steps.count - 1 {
                                complete()
                            } else {
                                move(to: currentIndex + 1, in: project)
                            }
                        }
                        .buttonStyle(
                            PreviewNavigationButtonStyle(
                                color: Color(hex: project.theme.accentHex)
                            )
                        )
                        .keyboardShortcut(.defaultAction)
                    }

                    if project.theme.showsBranding {
                        Text("Made with Storybird")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.36))
                    }
                }
                .padding(24)

                if let informationHotspot {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture {
                            self.informationHotspot = nil
                        }

                    PreviewCallout(
                        hotspot: informationHotspot,
                        accent: Color(hex: project.theme.accentHex),
                        onContinue: {
                            self.informationHotspot = nil
                            follow(informationHotspot, in: project)
                        }
                    )
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .onAppear {
                startSessionIfNeeded(project: project)
            }
        } else {
            ContentUnavailableView(
                "Nothing to preview",
                systemImage: "play.slash",
                description: Text("Add at least one screen first.")
            )
            .frame(width: 620, height: 420)
        }
    }

    private func currentIndex(in project: DemoProject) -> Int? {
        if let currentStepID {
            return project.steps.firstIndex { $0.id == currentStepID }
        }
        return project.steps.isEmpty ? nil : 0
    }

    private func startSessionIfNeeded(project: DemoProject) {
        guard !didStartSession, let first = project.steps.first else { return }
        didStartSession = true
        currentStepID = first.id
        store.record(
            AnalyticsEvent(sessionID: sessionID, type: .sessionStarted),
            in: projectID
        )
        recordView(stepID: first.id)
    }

    private func activate(
        _ hotspot: Hotspot,
        step: DemoStep,
        project: DemoProject
    ) {
        store.record(
            AnalyticsEvent(
                sessionID: sessionID,
                type: .hotspotClicked,
                stepID: step.id,
                hotspotID: hotspot.id
            ),
            in: projectID
        )

        if hotspot.kind == .information {
            withAnimation(.easeOut(duration: 0.18)) {
                informationHotspot = hotspot
            }
        } else {
            follow(hotspot, in: project)
        }
    }

    private func follow(_ hotspot: Hotspot, in project: DemoProject) {
        if let targetStepID = hotspot.targetStepID,
           let index = project.steps.firstIndex(where: {
               $0.id == targetStepID
           }) {
            move(to: index, in: project)
            return
        }

        guard let index = currentIndex(in: project) else { return }
        if index < project.steps.count - 1 {
            move(to: index + 1, in: project)
        } else {
            complete()
        }
    }

    private func move(to index: Int, in project: DemoProject) {
        guard project.steps.indices.contains(index) else { return }
        currentStepID = project.steps[index].id
        informationHotspot = nil
        recordView(stepID: project.steps[index].id)
    }

    private func recordView(stepID: UUID) {
        store.record(
            AnalyticsEvent(
                sessionID: sessionID,
                type: .stepViewed,
                stepID: stepID
            ),
            in: projectID
        )
    }

    private func complete() {
        guard !didComplete else { return }
        didComplete = true
        store.record(
            AnalyticsEvent(sessionID: sessionID, type: .completed),
            in: projectID
        )
        dismiss()
    }
}

private struct PreviewNavigationButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(color.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

private struct PreviewStage: View {
    let step: DemoStep
    let imageURL: URL
    let accent: Color
    let onHotspot: (Hotspot) -> Void

    private var image: NSImage? {
        NSImage(contentsOf: imageURL)
    }

    var body: some View {
        GeometryReader { proxy in
            let container = CGRect(origin: .zero, size: proxy.size)
            let imageFrame = AspectFit.frame(
                contentSize: image?.size ?? .zero,
                in: container
            )

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(.black.opacity(0.54))
                    .shadow(color: .black.opacity(0.42), radius: 28, y: 16)

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: imageFrame.width, height: imageFrame.height)
                        .position(x: imageFrame.midX, y: imageFrame.midY)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                ScreenSubtitleOverlay(
                    text: step.caption,
                    position: step.subtitlePosition,
                    style: step.subtitleStyle,
                    imageFrame: imageFrame
                )

                ForEach(step.hotspots) { hotspot in
                    HotspotCaptionOverlay(
                        hotspot: hotspot,
                        imageFrame: imageFrame
                    )
                }

                ForEach(Array(step.hotspots.enumerated()), id: \.element.id) { index, hotspot in
                    Button {
                        onHotspot(hotspot)
                    } label: {
                        HotspotMarker(
                            number: index + 1,
                            kind: hotspot.kind,
                            color: accent,
                            isSelected: false
                        )
                    }
                    .buttonStyle(.plain)
                    .position(
                        x: imageFrame.minX + CGFloat(hotspot.x) * imageFrame.width,
                        y: imageFrame.minY + CGFloat(hotspot.y) * imageFrame.height
                    )
                    .help(hotspot.title)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct PreviewCallout: View {
    let hotspot: Hotspot
    let accent: Color
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(accent)
                Text(hotspot.title.isEmpty ? "Learn more" : hotspot.title)
                    .font(.headline)
            }

            if !hotspot.body.isEmpty {
                Text(hotspot.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Continue", action: onContinue)
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.3), radius: 28, y: 14)
    }
}
