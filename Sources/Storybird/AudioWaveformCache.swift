import Foundation

/// Presentation-only summaries share in-flight reads across duplicated layers.
/// Publication and export still validate real media independently of this cache.
actor AudioWaveformCache {
    static let shared = AudioWaveformCache()
    private struct Key: Hashable {
        let url: URL
        let size: Int?
        let modified: Date?
    }
    private var values: [Key: AudioFileSummary] = [:]
    private var pending: [Key: Task<AudioFileSummary, Error>] = [:]
    private let loader: @Sendable (URL) throws -> AudioFileSummary

    init(loader: @escaping @Sendable (URL) throws -> AudioFileSummary = { try ProjectAudioFiles.inspect($0) }) {
        self.loader = loader
    }

    /// Reuses bounded in-memory summaries and refreshes after source replacement.
    /// Failed reads are never cached as valid waveform data.
    func summary(for url: URL) async throws -> AudioFileSummary {
        var refreshedURL = url
        refreshedURL.removeAllCachedResourceValues()
        let metadata = try refreshedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = Key(url: url, size: metadata.fileSize, modified: metadata.contentModificationDate)
        if let value = values[key] { return value }
        let task: Task<AudioFileSummary, Error>
        if let existing = pending[key] {
            task = existing
        } else {
            let loader = self.loader
            task = Task.detached { try loader(url) }
            pending[key] = task
        }
        defer { pending[key] = nil }
        let value = try await task.value
        // This is a small display cache, never a persistent media index.
        if values.count >= 128 { values.removeAll(keepingCapacity: true) }
        values[key] = value
        return value
    }
}
