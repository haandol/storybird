import Combine
import Foundation
import StorybirdCore

@MainActor
final class VoiceProfileCreationModel: ObservableObject {
    enum InputMethod: Hashable {
        case record
        case importFile
    }

    struct Input {
        let name: String
        let url: URL
        let transcript: String
        let language: VoiceLanguage
        let source: VoiceReferenceSource
    }

    @Published var profileName = ""
    @Published var referenceLanguage: VoiceLanguage = .korean
    @Published var inputMethod: InputMethod = .record
    @Published var transcript = ""
    @Published var consentConfirmed = false
    @Published var errorMessage: String?
    @Published private(set) var selectedFileURL: URL?
    @Published private(set) var isSaving = false
    @Published private(set) var isClosed = false

    private let persist: (Input) async throws -> Void
    private let discardSample: () -> Void

    /// Keeps a creation attempt separate from shared settings and makes its
    /// save/cleanup boundary testable without accessing a real microphone.
    init(
        persist: @escaping (Input) async throws -> Void,
        discardSample: @escaping () -> Void
    ) {
        self.persist = persist
        self.discardSample = discardSample
    }

    /// Connects the sheet to the app's validated writer; cleanup removes only
    /// the recorder's temporary sample after successful save or cancellation.
    convenience init(store: AppStore, recorder: some VoiceSampleRecording) {
        self.init(
            persist: { input in
                _ = try await store.importVoiceProfile(
                    name: input.name,
                    sourceURL: input.url,
                    transcript: input.transcript,
                    language: input.language.rawValue,
                    source: input.source,
                    consentConfirmed: true
                )
            },
            discardSample: { recorder.discard() }
        )
    }

    /// File choice stages input only; consent and an open, idle attempt are
    /// required before a selected file can become a save candidate.
    func selectFile(_ url: URL) {
        guard consentConfirmed, !isSaving, !isClosed else { return }
        selectedFileURL = url
        errorMessage = nil
    }

    /// Requires a name, consent, and complete input for the selected method.
    /// The app writer separately validates actual audio and microphone duration.
    func canSave(recordedURL: URL?) -> Bool {
        guard !isSaving, !isClosed, consentConfirmed,
              !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        switch inputMethod {
        case .record:
            return recordedURL != nil
        case .importFile:
            return selectedFileURL != nil
                && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Saves one immutable input snapshot. Failure leaves the attempt open
    /// with its inputs and sample intact; only a successful write closes it.
    func save(recordedURL: URL?) async {
        guard canSave(recordedURL: recordedURL),
              let url = inputMethod == .record ? recordedURL : selectedFileURL
        else { return }
        let input = Input(
            name: profileName,
            url: url,
            transcript: inputMethod == .record
                ? referenceLanguage.referencePrompt : transcript,
            language: referenceLanguage,
            source: inputMethod == .record ? .microphone : .importedFile
        )
        isSaving = true
        errorMessage = nil
        do {
            try await persist(input)
            discardSample()
            isClosed = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    /// Cancels before publishing a profile and invalidates pending microphone
    /// start requests through recorder cleanup. An active save owns dismissal.
    func cancel() {
        guard !isSaving, !isClosed else { return }
        discardSample()
        isClosed = true
    }
}
