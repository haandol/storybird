import AVFAudio
import Combine
import Foundation

@MainActor
protocol VoicePreviewPlayback: AnyObject {
    var onCompletion: ((String?) -> Void)? { get set }
    func play() -> Bool
    func stop()
}

@MainActor
final class VoicePreviewPlayer: ObservableObject {
    @Published private(set) var playingURL: URL?
    @Published private(set) var errorMessage: String?

    private let makePlayback: (URL) throws -> any VoicePreviewPlayback
    private var playback: (any VoicePreviewPlayback)?
    private var playbackID: UUID?

    init(makePlayback: @escaping (URL) throws -> any VoicePreviewPlayback = {
        try NativeVoicePreviewPlayback(url: $0)
    }) {
        self.makePlayback = makePlayback
    }

    /// A second click stops the sample; selecting another sample replaces it.
    func toggle(_ url: URL) {
        let wasPlaying = playingURL == url
        stop()
        errorMessage = nil
        guard !wasPlaying else { return }
        do {
            let next = try makePlayback(url)
            let id = UUID()
            playbackID = id
            playback = next
            playingURL = url
            next.onCompletion = { [weak self] error in
                guard let self, self.playbackID == id else { return }
                self.stop()
                self.errorMessage = error
            }
            if !next.play() {
                stop()
                errorMessage = "The voice sample could not be played."
            }
        } catch {
            stop()
            errorMessage = error.localizedDescription
        }
    }

    /// Clear identity before stopping so a late callback cannot stop a new sample.
    func stop() {
        playbackID = nil
        playback?.onCompletion = nil
        playback?.stop()
        playback = nil
        playingURL = nil
    }
}

@MainActor
private final class NativeVoicePreviewPlayback: NSObject, VoicePreviewPlayback, AVAudioPlayerDelegate {
    var onCompletion: ((String?) -> Void)?
    private let player: AVAudioPlayer

    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
    }

    func play() -> Bool { player.play() }
    func stop() { player.stop() }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.onCompletion?(flag ? nil : "The voice sample could not finish playing.")
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let message = error?.localizedDescription ?? "The voice sample could not be decoded."
        Task { @MainActor [weak self] in
            self?.onCompletion?(message)
        }
    }
}
