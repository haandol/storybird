import StorybirdCore
import SwiftUI

@MainActor
final class VoiceProfileRenameModel: ObservableObject {
    @Published var name: String
    @Published private(set) var errorMessage: String?
    @Published private(set) var isClosed = false
    private let profileID: UUID
    private let store: AppStore

    /// Captures the selected profile's identity while keeping draft text local
    /// until an explicit save succeeds.
    init(profile: VoiceProfile, store: AppStore) {
        name = profile.name
        profileID = profile.id
        self.store = store
    }

    var canSave: Bool {
        !isClosed && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Keeps the editor and its input available for retry when validation or
    /// persistence fails; a successful rename closes this editing session.
    func save() {
        guard !isClosed else { return }
        do {
            try store.renameVoiceProfile(id: profileID, name: name)
            errorMessage = nil
            isClosed = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Discards the draft without publishing a profile change.
    func cancel() { isClosed = true }
}

struct VoiceProfileRenameView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: VoiceProfileRenameModel
    @FocusState private var nameIsFocused: Bool

    /// Gives each rename presentation its own draft and failure state.
    init(model: VoiceProfileRenameModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Voice Profile")
                .font(.title2.weight(.semibold))
            TextField("Profile name", text: $model.name)
                .textFieldStyle(.roundedBorder)
                .focused($nameIsFocused)
                .accessibilityIdentifier("voice-profile-rename-name")
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSave)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { nameIsFocused = true }
        .onChange(of: model.isClosed) { _, isClosed in
            if isClosed { dismiss() }
        }
        .onDisappear { model.cancel() }
    }
}
