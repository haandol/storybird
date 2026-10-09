import StorybirdCore
import SwiftUI

struct ClickLayerInspector: View {
    @Binding var click: TimedPointerClick
    let duration: Double
    let onDelete: () -> Void

    var body: some View {
        Form {
            Section("Click") {
                Label(
                    click.isComplete ? "Complete" : ClickCueReviewMenu.missingText(click),
                    systemImage: click.isComplete ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .foregroundStyle(click.isComplete ? Color.secondary : .orange)
                TextField("Time", value: $click.time, format: .number)
                Picker("Button", selection: $click.button) {
                    ForEach(PointerButton.allCases) { button in
                        Text(button.rawValue.capitalized).tag(button)
                    }
                }
                TextField(
                    "Description",
                    text: $click.description.text,
                    axis: .vertical
                )
                    .lineLimit(3)
                TextField(
                    "Subtitle",
                    text: $click.cueSubtitle.text,
                    axis: .vertical
                )
                    .lineLimit(3)
                Slider(value: $click.x, in: 0...1) {
                    Text("Horizontal position")
                }
                Slider(value: $click.y, in: 0...1) {
                    Text("Vertical position")
                }
                TextField(
                    "Indicator start",
                    value: $click.indicator.startTime,
                    format: .number
                )
                TextField(
                    "Indicator end",
                    value: $click.indicator.endTime,
                    format: .number
                )
                ColorPicker(
                    "Indicator",
                    selection: Binding(
                        get: { Color(hex: click.indicator.colorHex) },
                        set: { click.indicator.colorHex = $0.hexRGB }
                    ),
                    supportsOpacity: false
                )
                Slider(value: $click.indicator.size, in: 0.25...3) {
                    Text("Indicator size")
                }
                Slider(value: $click.indicator.opacity, in: 0...1) {
                    Text("Indicator opacity")
                }
            }
            Section("Description timing & position") {
                TextField(
                    "Start",
                    value: $click.description.startTime,
                    format: .number
                )
                TextField(
                    "End",
                    value: $click.description.endTime,
                    format: .number
                )
                Picker("Position", selection: $click.description.position) {
                    ForEach(ClickDescriptionPosition.allCases) { position in
                        Text(position.rawValue.capitalized).tag(position)
                    }
                }
                if click.description.position == .custom {
                    Slider(value: $click.description.x, in: 0...1) {
                        Text("Description X")
                    }
                    Slider(value: $click.description.y, in: 0...1) {
                        Text("Description Y")
                    }
                }
            }
            OverlayStyleEditor(style: $click.description.style)
            Section("Cue subtitle") {
                TextField(
                    "Start",
                    value: $click.cueSubtitle.startTime,
                    format: .number
                )
                TextField(
                    "End",
                    value: $click.cueSubtitle.endTime,
                    format: .number
                )
                Picker("Position", selection: $click.cueSubtitle.position) {
                    ForEach(SubtitlePosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                OverlayStyleEditor(style: $click.cueSubtitle.style)
            }
            Section {
                Button("Delete Click Layer", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
    }
}

struct ClipLayerInspector: View {
    @Binding var clip: VideoClip
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Form {
            Section("Clip") {
                Picker("Kind", selection: $clip.kind) {
                    Text("Video").tag(VideoClipKind.video)
                    Text("Freeze").tag(VideoClipKind.freeze)
                }
                TextField("Source start", value: $clip.sourceStart, format: .number)
                TextField("Source end", value: $clip.sourceEnd, format: .number)
                if clip.kind == .video {
                    HStack {
                        Button("1×") { clip.playbackRate = 1 }
                        Button("2×") { clip.playbackRate = 2 }
                        Button("4×") { clip.playbackRate = 4 }
                        Spacer()
                        Text(String(format: "%.2g×", clip.playbackRate))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $clip.playbackRate, in: 0.25...4) {
                        Text("Speed")
                    }
                } else {
                    TextField(
                        "Freeze duration",
                        value: $clip.freezeDuration,
                        format: .number
                    )
                }
            }
            Section("Order") {
                Button("Move Earlier", action: onMoveLeft)
                    .disabled(!canMoveLeft)
                Button("Move Later", action: onMoveRight)
                    .disabled(!canMoveRight)
            }
            Section {
                Button("Delete Clip", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
    }
}

struct EffectLayerInspector: View {
    @Binding var effect: DemoEffect
    let onDelete: () -> Void

    var body: some View {
        Form {
            switch effect {
            case let .spotlight(value):
                SpotlightEditor(
                    value: Binding(
                        get: { value },
                        set: { effect = .spotlight($0) }
                    )
                )
            case let .panZoom(value):
                PanZoomEditor(
                    value: Binding(
                        get: { value },
                        set: { effect = .panZoom($0) }
                    )
                )
            case let .title(value):
                CardEditor(
                    title: "Title card",
                    value: Binding(
                        get: {
                            (value.startTime, value.endTime, value.title, value.subtitle)
                        },
                        set: {
                            effect = .title(
                                TitleCardEffect(
                                    id: value.id,
                                    startTime: $0.0,
                                    endTime: $0.1,
                                    title: $0.2,
                                    subtitle: $0.3,
                                    style: value.style
                                )
                            )
                        }
                    )
                )
                OverlayStyleEditor(
                    style: Binding(
                        get: { value.style },
                        set: {
                            effect = .title(
                                TitleCardEffect(
                                    id: value.id,
                                    startTime: value.startTime,
                                    endTime: value.endTime,
                                    title: value.title,
                                    subtitle: value.subtitle,
                                    style: $0
                                )
                            )
                        }
                    )
                )
            case let .cta(value):
                CardEditor(
                    title: "CTA card",
                    value: Binding(
                        get: {
                            (value.startTime, value.endTime, value.title, value.buttonLabel)
                        },
                        set: {
                            effect = .cta(
                                CTACardEffect(
                                    id: value.id,
                                    startTime: $0.0,
                                    endTime: $0.1,
                                    title: $0.2,
                                    buttonLabel: $0.3,
                                    style: value.style
                                )
                            )
                        }
                    )
                )
                OverlayStyleEditor(
                    style: Binding(
                        get: { value.style },
                        set: {
                            effect = .cta(
                                CTACardEffect(
                                    id: value.id,
                                    startTime: value.startTime,
                                    endTime: value.endTime,
                                    title: value.title,
                                    buttonLabel: value.buttonLabel,
                                    style: $0
                                )
                            )
                        }
                    )
                )
            }
            Section {
                Button("Delete Effect", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
    }
}

struct SuggestionInspector: View {
    @Binding var suggestion: ClickEditSuggestion
    let onApply: () -> Void
    let onReject: () -> Void

    var body: some View {
        Form {
            Section("Edit suggestion") {
                LabeledContent("State", value: suggestion.state.rawValue)
                TextField(
                    "Split",
                    value: $suggestion.splitTime,
                    format: .number
                )
                Text("Includes a click marker, split, spotlight, and pan & zoom draft.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if suggestion.state == .pending {
                SpotlightEditor(value: $suggestion.spotlight)
                PanZoomEditor(value: $suggestion.panZoom)
                Section {
                    Button("Apply Suggestion", action: onApply)
                    Button(
                        "Reject Suggestion",
                        role: .destructive,
                        action: onReject
                    )
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SpotlightEditor: View {
    @Binding var value: SpotlightEffect

    var body: some View {
        Section("Spotlight") {
            TextField("Start", value: $value.startTime, format: .number)
            TextField("End", value: $value.endTime, format: .number)
            Slider(value: $value.x, in: 0...1) { Text("X") }
            Slider(value: $value.y, in: 0...1) { Text("Y") }
            Slider(value: $value.width, in: 0.01...1) { Text("Width") }
            Slider(value: $value.height, in: 0.01...1) { Text("Height") }
            Slider(value: $value.dimOpacity, in: 0...1) { Text("Dim") }
        }
    }
}

private struct PanZoomEditor: View {
    @Binding var value: PanZoomEffect

    var body: some View {
        Section("Pan & Zoom") {
            TextField("Start", value: $value.startTime, format: .number)
            TextField("End", value: $value.endTime, format: .number)
            Slider(value: $value.startX, in: 0...1) { Text("Start X") }
            Slider(value: $value.startY, in: 0...1) { Text("Start Y") }
            Slider(value: $value.startScale, in: 1...3) {
                Text("Start scale")
            }
            Slider(value: $value.endX, in: 0...1) { Text("End X") }
            Slider(value: $value.endY, in: 0...1) { Text("End Y") }
            Slider(value: $value.endScale, in: 1...3) { Text("End scale") }
        }
    }
}

private struct CardEditor: View {
    let title: String
    @Binding var value: (Double, Double, String, String)

    var body: some View {
        Section(title) {
            TextField("Start", value: $value.0, format: .number)
            TextField("End", value: $value.1, format: .number)
            TextField("Title", text: $value.2)
            TextField("Subtitle / Label", text: $value.3)
        }
    }
}

struct SubtitleLayerInspector: View {
    @Binding var subtitle: TimedSubtitle
    let duration: Double
    let onDelete: () -> Void

    var body: some View {
        Form {
            Section("Subtitle") {
                TextField("Text", text: $subtitle.text, axis: .vertical)
                    .lineLimit(4)
                TextField(
                    "Start",
                    value: $subtitle.startTime,
                    format: .number.precision(.fractionLength(2))
                )
                TextField(
                    "End",
                    value: $subtitle.endTime,
                    format: .number.precision(.fractionLength(2))
                )
                Picker("Position", selection: $subtitle.position) {
                    ForEach(SubtitlePosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
            }
            OverlayStyleEditor(style: $subtitle.style)
            Section {
                Button("Delete Subtitle", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
    }
}

private struct OverlayStyleEditor: View {
    @Binding var style: TextOverlayStyle

    var body: some View {
        Section("Background") {
            ColorPicker(
                "Color",
                selection: Binding(
                    get: { Color(hex: style.backgroundHex) },
                    set: { style.backgroundHex = $0.hexRGB }
                ),
                supportsOpacity: false
            )
            Slider(value: $style.backgroundOpacity, in: 0...1) {
                Text("Opacity")
            }
            Text(
                style.backgroundOpacity.formatted(
                    .percent.precision(.fractionLength(0))
                )
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            ColorPicker(
                "Text color",
                selection: Binding(
                    get: { Color(hex: style.foregroundHex) },
                    set: { style.foregroundHex = $0.hexRGB }
                ),
                supportsOpacity: false
            )
            Slider(value: $style.fontSize, in: 8...96) {
                Text("Font size")
            }
        }
    }
}
