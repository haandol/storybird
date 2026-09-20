import StorybirdCore
import SwiftUI

struct NarrationLayerInspector: View {
    @Binding var narration: NarrationClip
    @ObservedObject var audition: AudioAuditionPlayer
    let onListen: () -> Void
    let onSplit: () -> Void
    let onDuplicate: () -> Void
    let onRegenerate: (String, String, CustomVoiceOptions?) async -> Void
    let onDelete: () -> Void
    @State private var replacementText: String
    @State private var replacementLanguage: String
    @State private var speaker: CustomVoiceSpeaker
    @State private var instruct: String
    @State private var isRegenerating = false
    @State private var trimStart: Double
    @State private var trimDuration: Double

    /// Keeps replacement text, language and preset instructions separate from
    /// saved audio so a failed regeneration leaves the user's draft available.
    init(
        narration: Binding<NarrationClip>,
        audition: AudioAuditionPlayer,
        onListen: @escaping () -> Void,
        onSplit: @escaping () -> Void, onDuplicate: @escaping () -> Void,
        onRegenerate: @escaping (String, String, CustomVoiceOptions?) async -> Void,
        onDelete: @escaping () -> Void
    ) {
        _narration = narration
        self.audition = audition
        self.onListen = onListen
        self.onSplit = onSplit
        self.onDuplicate = onDuplicate
        _trimStart = State(initialValue: narration.wrappedValue.sourceStart)
        _trimDuration = State(initialValue: narration.wrappedValue.duration)
        self.onRegenerate = onRegenerate
        self.onDelete = onDelete
        _replacementLanguage = State(initialValue: narration.wrappedValue.language)
        _speaker = State(initialValue: narration.wrappedValue.customVoice?.speaker ?? .sohee)
        _instruct = State(initialValue: narration.wrappedValue.customVoice?.instruct ?? "")
        _replacementText = State(
            initialValue: narration.wrappedValue.text
        )
    }

    var body: some View {
        Form {
            Section("Audio Layer") {
                Button(action: onListen) {
                    Label(audition.activeID == .layer(narration.id) ? "Stop" : "Listen to This Layer",
                          systemImage: audition.activeID == .layer(narration.id) ? "stop.fill" : "play.fill")
                }
                .accessibilityIdentifier("audio-layer-listen")
                if audition.activeID == .layer(narration.id), audition.isPreparing {
                    ProgressView().controlSize(.small)
                }
                if narration.isMuted {
                    Text("This layer is muted.").font(.caption).foregroundStyle(.secondary)
                }
                if let error = audition.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                TextField("Name", text: $narration.name)
                if narration.voiceProfileID != nil || narration.customVoice != nil {
                TextField(
                    "Text",
                    text: $replacementText,
                    axis: .vertical
                )
                .lineLimit(4)
                Picker("Language", selection: $replacementLanguage) {
                    ForEach(VoiceLanguage.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value.rawValue)
                    }
                    if VoiceLanguage(rawValue: narration.language) == nil {
                        Text(narration.language).tag(narration.language)
                    }
                }
                if narration.customVoice != nil {
                    CustomVoiceControls(speaker: $speaker, instruct: $instruct)
                }
                Button("Regenerate This Narration") {
                    let text = replacementText
                    isRegenerating = true
                    Task {
                        await onRegenerate(text, replacementLanguage,
                                           narration.customVoice == nil ? nil : CustomVoiceOptions(speaker: speaker, instruct: instruct))
                        isRegenerating = false
                    }
                }
                .disabled(
                    isRegenerating
                        || replacementText.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                        || (replacementText == narration.text && replacementLanguage == narration.language
                            && (narration.customVoice == nil || narration.customVoice == CustomVoiceOptions(speaker: speaker, instruct: instruct)))
                )
                }
                TextField(
                    "Start",
                    value: $narration.startTime,
                    format: .number.precision(.fractionLength(2))
                )
                LabeledContent("Duration") {
                    Text(
                        narration.duration,
                        format: .number.precision(.fractionLength(2))
                    )
                }
                TextField("Volume", value: $narration.volume, format: .number)
                Toggle("Mute", isOn: $narration.isMuted)
                TextField("Fade in (s)", value: $narration.fadeIn, format: .number)
                TextField("Fade out (s)", value: $narration.fadeOut, format: .number)
                TextField("Source start (s)", value: $trimStart, format: .number)
                TextField("Use duration (s)", value: $trimDuration, format: .number)
                Button("Apply Trim") {
                    var edited = narration
                    edited.sourceStart = trimStart
                    edited.duration = trimDuration
                    narration = edited
                }
                Button("Split at Playhead", action: onSplit)
                Button("Duplicate Layer", action: onDuplicate)
            }
            Section {
                Button(
                    "Delete Audio Layer",
                    role: .destructive,
                    action: onDelete
                )
            }
        }
        .formStyle(.grouped)
        .onDisappear { audition.stop(id: .layer(narration.id)) }
        .onChange(of: narration) { previous, _ in audition.stop(id: .layer(previous.id)) }
        .onChange(of: narration.id) { _, _ in
            trimStart = narration.sourceStart; trimDuration = narration.duration
            replacementText = narration.text; replacementLanguage = narration.language
            speaker = narration.customVoice?.speaker ?? .sohee
            instruct = narration.customVoice?.instruct ?? ""
        }
        .onChange(of: narration.sourceStart) { _, value in trimStart = value }
        .onChange(of: narration.duration) { _, value in trimDuration = value }
        .onChange(of: narration.language) { _, value in replacementLanguage = value }
        .onChange(of: narration.customVoice) { _, value in
            speaker = value?.speaker ?? .sohee; instruct = value?.instruct ?? ""
        }
        .onChange(of: narration.text) { _, value in
            replacementText = value
        }
    }
}
