import StorybirdCore
import SwiftUI

struct BatchPropertySession: Identifiable {
    let id = UUID()
    let projectID: UUID
    let revision: Int
    let targets: [ProjectEditReference]
    let fields: [String: ProjectEditField]
    let values: [String: [ProjectEditValue]]

    static func make(project: DemoProject, targets: [ProjectEditReference]) throws -> Self {
        var fields: [String: ProjectEditField] = [:]
        var values: [String: [ProjectEditValue]] = [:]
        for (index, target) in targets.enumerated() {
            let available = try ProjectEditPlanner.fields(for: target.target, id: target.id, in: project)
            if index == 0 { fields = available }
            else { fields = fields.filter { available[$0.key]?.type == $0.value.type } }
            let current = try ProjectEditPlanner.values(for: target, in: project)
            for (key, value) in current { values[key, default: []].append(value) }
        }
        return Self(projectID: project.id, revision: project.revision, targets: targets,
            fields: fields, values: values.filter { fields[$0.key] != nil && $0.value.count == targets.count })
    }
}

/// A chosen property is one explicit atomic change across the selection. Mixed
/// values stay visible, and changing it cannot overwrite other properties.
struct BatchPropertySheet: View {
    @ObservedObject var store: AppStore
    let session: BatchPropertySession
    @Environment(\.dismiss) private var dismiss
    @State private var property: String
    @State private var value: ProjectEditValue
    @State private var error: String?

    init(store: AppStore, session: BatchPropertySession) {
        self.store = store
        self.session = session
        let first = session.values.keys.sorted().first ?? ""
        _property = State(initialValue: first)
        _value = State(initialValue: session.values[first]?.first ?? .string(""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit \(session.targets.count) selected layers").font(.headline)
            if session.values.isEmpty {
                Text("These layers have no common editable properties. Move, duplicate, or delete them from the selection toolbar.")
            } else {
                Picker("Property", selection: $property) {
                    ForEach(session.values.keys.sorted(), id: \.self) { key in Text(title(key)).tag(key) }
                }
                .accessibilityIdentifier("batch-property-name")
                if Set(session.values[property] ?? []).count > 1 {
                    Text("Mixed values").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                if let field = session.fields[property] { input(field) }
                Text("Only this property is applied to the selection.").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Spacer(minLength: 0)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply value") { apply() }.disabled(property.isEmpty)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("batch-property-apply")
            }
        }
        .padding(20).frame(width: 420, height: 320)
        .onChange(of: property) { _, next in value = session.values[next]?.first ?? .string(""); error = nil }
    }

    @ViewBuilder private func input(_ field: ProjectEditField) -> some View {
        switch field.type {
        case .number, .integer:
            TextField("Value", value: Binding(get: {
                if case let .number(number) = value { number } else { 0 }
            }, set: { value = .number($0) }), format: .number)
            .accessibilityIdentifier("batch-property-value")
        case .boolean:
            Toggle("Enabled", isOn: Binding(get: {
                if case let .boolean(boolean) = value { boolean } else { false }
            }, set: { value = .boolean($0) }))
        case .string:
            let text = Binding(get: { if case let .string(string) = value { string } else { "" } }, set: { value = .string($0) })
            if let choices = field.choices {
                Picker("Value", selection: text) { ForEach(choices, id: \.self) { Text(title($0)).tag($0) } }
            } else if property.hasSuffix("_hex") {
                ColorPicker("Value", selection: Binding(get: { Color(hex: text.wrappedValue) },
                    set: { text.wrappedValue = $0.hexRGB }), supportsOpacity: false)
            } else {
                TextField("Value", text: text, axis: .vertical).lineLimit(3...6)
                    .accessibilityIdentifier("batch-property-value")
            }
        }
    }

    private func title(_ key: String) -> String {
        if key == "project" { return "Fixed project time" }
        if key == "scene" { return "Follow scene" }
        return key.replacingOccurrences(of: "_hex", with: " color").replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func apply() {
        do {
            _ = try store.editProject(projectID: session.projectID, expectedRevision: session.revision,
                edits: session.targets.map { ProjectEdit(target: $0.target, id: $0.id, action: .update, values: [property: value]) })
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
