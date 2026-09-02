import AppKit
import StorybirdCore
import SwiftUI

struct DemoEditorView: View {
    @ObservedObject var store: AppStore
    @Binding var project: DemoProject
    @Binding var selectedStepID: UUID?
    @Binding var selectedHotspotID: UUID?
    @Binding var isAddingHotspot: Bool

    var body: some View {
        if project.steps.isEmpty {
            EmptyEditorView()
        } else {
            HSplitView {
                StepRail(
                    store: store,
                    project: project,
                    selectedStepID: $selectedStepID,
                    selectedHotspotID: $selectedHotspotID
                )
                .frame(minWidth: 145, idealWidth: 185, maxWidth: 230)

                EditorCanvasColumn(
                    store: store,
                    project: $project,
                    selectedStepID: $selectedStepID,
                    selectedHotspotID: $selectedHotspotID,
                    isAddingHotspot: $isAddingHotspot
                )
                .frame(minWidth: 400)

                DemoInspector(
                    store: store,
                    project: $project,
                    selectedStepID: $selectedStepID,
                    selectedHotspotID: $selectedHotspotID
                )
                .frame(minWidth: 215, idealWidth: 260, maxWidth: 320)
            }
        }
    }
}

private struct EmptyEditorView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("Add your first screen")
                .font(.title2.weight(.semibold))
            Text("Press Record Flow in the toolbar. Storybird will turn every click into the next connected screen.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.34))
    }
}

private struct StepRail: View {
    @ObservedObject var store: AppStore
    let project: DemoProject
    @Binding var selectedStepID: UUID?
    @Binding var selectedHotspotID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Screens")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(project.steps.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(12)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(project.steps.enumerated()), id: \.element.id) { index, step in
                        Button {
                            selectedStepID = step.id
                            selectedHotspotID = nil
                        } label: {
                            StepThumbnail(
                                index: index,
                                step: step,
                                imageURL: store.repository.assetURL(
                                    projectID: project.id,
                                    filename: step.assetFilename
                                ),
                                isSelected: selectedStepID == step.id,
                                accent: Color(hex: project.theme.accentHex)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
        .background(.bar.opacity(0.55))
    }
}

private struct StepThumbnail: View {
    let index: Int
    let step: DemoStep
    let imageURL: URL
    let isSelected: Bool
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topLeading) {
                AssetImageView(url: imageURL, contentMode: .fill)
                    .frame(height: 92)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                Text("\(index + 1)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(accent, in: Capsule())
                    .padding(6)
            }

            HStack(spacing: 5) {
                Text(step.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if !step.hotspots.isEmpty {
                    Label("\(step.hotspots.count)", systemImage: "cursorarrow.click")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? accent.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected ? accent.opacity(0.8) : Color.secondary.opacity(0.14),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
    }
}

private struct EditorCanvasColumn: View {
    @ObservedObject var store: AppStore
    @Binding var project: DemoProject
    @Binding var selectedStepID: UUID?
    @Binding var selectedHotspotID: UUID?
    @Binding var isAddingHotspot: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    isAddingHotspot.toggle()
                } label: {
                    Label(
                        isAddingHotspot ? "Click the screen…" : "Add Hotspot",
                        systemImage: isAddingHotspot ? "scope" : "plus.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: project.theme.accentHex))

                if isAddingHotspot {
                    Text("Choose a point on the screenshot")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("Drag a hotspot to reposition it")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar.opacity(0.75))

            if let stepIndex = project.steps.firstIndex(where: {
                $0.id == selectedStepID
            }) {
                DemoCanvas(
                    step: $project.steps[stepIndex],
                    imageURL: store.repository.assetURL(
                        projectID: project.id,
                        filename: project.steps[stepIndex].assetFilename
                    ),
                    selectedHotspotID: $selectedHotspotID,
                    isAddingHotspot: $isAddingHotspot,
                    accent: Color(hex: project.theme.accentHex)
                )
            } else {
                Color.clear
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.52))
    }
}

private struct DemoCanvas: View {
    @Binding var step: DemoStep
    let imageURL: URL
    @Binding var selectedHotspotID: UUID?
    @Binding var isAddingHotspot: Bool
    let accent: Color

    private var image: NSImage? {
        NSImage(contentsOf: imageURL)
    }

    var body: some View {
        GeometryReader { proxy in
            let container = CGRect(origin: .zero, size: proxy.size)
                .insetBy(dx: 24, dy: 24)
            let imageFrame = AspectFit.frame(
                contentSize: image?.size ?? .zero,
                in: container
            )

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.black.opacity(0.88))
                    .frame(width: imageFrame.width + 18, height: imageFrame.height + 18)
                    .position(x: imageFrame.midX, y: imageFrame.midY)
                    .shadow(color: .black.opacity(0.22), radius: 24, y: 12)

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: imageFrame.width, height: imageFrame.height)
                        .position(x: imageFrame.midX, y: imageFrame.midY)
                }

                Color.clear
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .contentShape(Rectangle())
                    .position(x: imageFrame.midX, y: imageFrame.midY)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                guard isAddingHotspot,
                                      imageFrame.width > 0,
                                      imageFrame.height > 0
                                else {
                                    return
                                }
                                let hotspot = Hotspot(
                                    x: value.location.x / imageFrame.width,
                                    y: value.location.y / imageFrame.height,
                                    title: "Continue"
                                )
                                step.hotspots.append(hotspot)
                                selectedHotspotID = hotspot.id
                                isAddingHotspot = false
                            }
                    )

                ForEach(Array(step.hotspots.indices), id: \.self) { hotspotIndex in
                    let hotspot = step.hotspots[hotspotIndex]
                    HotspotMarker(
                        number: hotspotIndex + 1,
                        kind: hotspot.kind,
                        color: accent,
                        isSelected: selectedHotspotID == hotspot.id
                    )
                    .position(
                        x: imageFrame.minX + CGFloat(hotspot.x) * imageFrame.width,
                        y: imageFrame.minY + CGFloat(hotspot.y) * imageFrame.height
                    )
                    .contentShape(Circle())
                    .onTapGesture {
                        selectedHotspotID = hotspot.id
                    }
                    .highPriorityGesture(
                        DragGesture(coordinateSpace: .named("demoCanvas"))
                            .onChanged { value in
                                guard imageFrame.width > 0,
                                      imageFrame.height > 0
                                else {
                                    return
                                }
                                step.hotspots[hotspotIndex].x = min(
                                    max(
                                        Double((value.location.x - imageFrame.minX) / imageFrame.width),
                                        0
                                    ),
                                    1
                                )
                                step.hotspots[hotspotIndex].y = min(
                                    max(
                                        Double((value.location.y - imageFrame.minY) / imageFrame.height),
                                        0
                                    ),
                                    1
                                )
                            }
                    )
                }
            }
            .coordinateSpace(name: "demoCanvas")
        }
    }
}

private struct DemoInspector: View {
    @ObservedObject var store: AppStore
    @Binding var project: DemoProject
    @Binding var selectedStepID: UUID?
    @Binding var selectedHotspotID: UUID?

    var body: some View {
        ScrollView {
            if let stepIndex = project.steps.firstIndex(where: {
                $0.id == selectedStepID
            }) {
                VStack(alignment: .leading, spacing: 18) {
                    InspectorSectionTitle("Screen")

                    LabeledContent("Title") {
                        TextField("Screen title", text: $project.steps[stepIndex].title)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Caption")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $project.steps[stepIndex].caption)
                            .font(.callout)
                            .frame(minHeight: 62)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(Color.secondary.opacity(0.2))
                            )
                    }

                    HStack {
                        Button {
                            store.moveStep(
                                projectID: project.id,
                                stepID: project.steps[stepIndex].id,
                                offset: -1
                            )
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .disabled(stepIndex == 0)

                        Button {
                            store.moveStep(
                                projectID: project.id,
                                stepID: project.steps[stepIndex].id,
                                offset: 1
                            )
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .disabled(stepIndex == project.steps.count - 1)

                        Spacer()

                        Button("Delete Screen", role: .destructive) {
                            let stepID = project.steps[stepIndex].id
                            selectedHotspotID = nil
                            selectedStepID = nil
                            store.deleteStep(projectID: project.id, stepID: stepID)
                        }
                    }

                    Divider()

                    if let hotspotIndex = project.steps[stepIndex].hotspots.firstIndex(
                        where: { $0.id == selectedHotspotID }
                    ) {
                        HotspotInspector(
                            hotspot: $project.steps[stepIndex].hotspots[hotspotIndex],
                            steps: project.steps,
                            onDelete: {
                                project.steps[stepIndex].hotspots.remove(
                                    at: hotspotIndex
                                )
                                selectedHotspotID = nil
                            }
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            InspectorSectionTitle("Hotspot")
                            Text("Select a hotspot on the screen, or add a new one.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    ThemeInspector(project: $project)
                }
                .padding(16)
            }
        }
        .background(.bar.opacity(0.45))
    }
}

private struct HotspotInspector: View {
    @Binding var hotspot: Hotspot
    let steps: [DemoStep]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            InspectorSectionTitle("Hotspot")

            Picker("Behavior", selection: $hotspot.kind) {
                ForEach(HotspotKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            LabeledContent("Title") {
                TextField("Hotspot title", text: $hotspot.title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $hotspot.body)
                    .font(.callout)
                    .frame(minHeight: 76)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.secondary.opacity(0.2))
                    )
            }

            Picker("Leads to", selection: $hotspot.targetStepID) {
                Text("Next screen").tag(Optional<UUID>.none)
                ForEach(steps) { step in
                    Text(step.title).tag(Optional(step.id))
                }
            }

            HStack {
                Text(
                    String(
                        format: "%.0f%%, %.0f%%",
                        hotspot.x * 100,
                        hotspot.y * 100
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)

                Spacer()

                Button("Delete Hotspot", role: .destructive, action: onDelete)
            }
        }
    }
}

private struct ThemeInspector: View {
    @Binding var project: DemoProject

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSectionTitle("Appearance")

            ColorPicker(
                "Accent",
                selection: Binding(
                    get: { Color(hex: project.theme.accentHex) },
                    set: { project.theme.accentHex = $0.hexRGB }
                ),
                supportsOpacity: false
            )

            Toggle("Show Storybird branding", isOn: $project.theme.showsBranding)

            VStack(alignment: .leading, spacing: 6) {
                Text("Demo summary")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Optional description", text: $project.summary)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

private struct InspectorSectionTitle: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(.headline)
    }
}
