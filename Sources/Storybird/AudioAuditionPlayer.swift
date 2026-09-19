import AVFAudio
import Foundation
import StorybirdCore
import SwiftUI

enum AudioAuditionID: Equatable {
    case item(UUID)
    case layer(UUID)
}

@MainActor
protocol AudioAuditionPlayback: AnyObject {
    var onCompletion: ((String?) -> Void)? { get set }
    func play() -> Bool
    func stop()
}

@MainActor
private final class AudioAuditionDevice: NSObject, AudioAuditionPlayback, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    var onCompletion: ((String?) -> Void)?

    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
    }

    func play() -> Bool { player.play() }
    func stop() { player.stop() }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.onCompletion?(flag ? nil : "The audio could not finish playing.")
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let message = error?.localizedDescription ?? "The audio could not be decoded."
        Task { @MainActor [weak self] in self?.onCompletion?(message) }
    }
}

/// One editor owns one audition, shared by asset cards and layer properties.
@MainActor
final class AudioAuditionPlayer: ObservableObject {
    struct PreparedAudio: Sendable {
        let url: URL
        var temporary = false

        func discard() {
            if temporary { try? FileManager.default.removeItem(at: url) }
        }
    }

    @Published private(set) var activeID: AudioAuditionID?
    @Published private(set) var isPreparing = false
    @Published private(set) var errorMessage: String?
    private let makePlayback: (URL) throws -> any AudioAuditionPlayback
    private var playback: (any AudioAuditionPlayback)?
    private var preparation: Task<Void, Never>?
    private var prepared: PreparedAudio?
    private var generation = UUID()

    init(makePlayback: ((URL) throws -> any AudioAuditionPlayback)? = nil) {
        self.makePlayback = makePlayback ?? { try AudioAuditionDevice(url: $0) }
    }

    func toggleFile(id: UUID, url: URL) {
        toggle(id: .item(id)) { PreparedAudio(url: url) }
    }

    func toggleLayer(_ layer: NarrationClip, project: DemoProject, sourceURL: URL) {
        toggle(id: .layer(layer.id)) {
            let result = try await AudioPreviewRenderer.render(
                project: project, sourceURL: sourceURL, startTime: layer.startTime,
                duration: layer.duration, layerID: layer.id
            )
            return PreparedAudio(url: URL(fileURLWithPath: result.path), temporary: true)
        }
    }

    func toggle(
        id: AudioAuditionID,
        prepare: @escaping @Sendable () async throws -> PreparedAudio
    ) {
        if activeID == id { stop(); return }
        stop()
        errorMessage = nil
        activeID = id
        isPreparing = true
        let token = generation
        preparation = Task { [weak self] in
            do {
                let audio = try await prepare()
                guard let self, self.generation == token, !Task.isCancelled else {
                    audio.discard()
                    return
                }
                self.prepared = audio
                let player = try self.makePlayback(audio.url)
                player.onCompletion = { [weak self] error in
                    guard let self, self.generation == token else { return }
                    self.stop()
                    self.errorMessage = error
                }
                self.playback = player
                guard player.play() else {
                    throw NSError(domain: "StorybirdAudio", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "The audio could not start playing."])
                }
                self.isPreparing = false
                self.preparation = nil
            } catch {
                guard let self, self.generation == token else { return }
                self.stop()
                if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func stop() {
        // SwiftUI subscriptions may replay video state when the editor updates.
        // Publishing idle -> idle here creates a stop/update/resubscribe loop.
        guard activeID != nil || isPreparing || preparation != nil || playback != nil || prepared != nil else {
            return
        }
        generation = UUID()
        preparation?.cancel()
        preparation = nil
        playback?.onCompletion = nil
        playback?.stop()
        playback = nil
        prepared?.discard()
        prepared = nil
        activeID = nil
        isPreparing = false
    }

    func stop(id: AudioAuditionID) {
        if activeID == id { stop() }
    }

    func stopItems() {
        if case .item = activeID { stop() }
    }
}
