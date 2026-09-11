import Foundation

/// Reuses JSON for unchanged projects while still writing one complete, atomic
/// library. Entries are value snapshots, never revision-only or disk-read caches.
final class ProjectLibraryEncoder {
    private struct Entry {
        let project: DemoProject
        let data: Data
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private let encoder: JSONEncoder

    init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func encode(_ projects: [DemoProject]) throws -> Data {
        try lock.withLock {
            var next: [UUID: Entry] = [:]
            var ordered: [Data] = []
            ordered.reserveCapacity(projects.count)
            for project in projects {
                let entry: Entry
                if let existing = entries[project.id], existing.project == project {
                    entry = existing
                } else {
                    let encoded = try encoder.encode(project)
                    // Indent each reusable object as an element of the library
                    // array, preserving the readable, sorted JSON representation.
                    var indented = Data()
                    for (index, line) in encoded.split(separator: 0x0a).enumerated() {
                        if index > 0 { indented.append(0x0a) }
                        indented.append(contentsOf: [0x20, 0x20])
                        indented.append(contentsOf: line)
                    }
                    entry = Entry(project: project, data: indented)
                }
                next[project.id] = entry
                ordered.append(entry.data)
            }
            var result = Data()
            result.reserveCapacity(ordered.reduce(4) { $0 + $1.count + 2 })
            result.append(contentsOf: projects.isEmpty ? [0x5b, 0x5d] : [0x5b, 0x0a])
            for (index, data) in ordered.enumerated() {
                if index > 0 { result.append(contentsOf: [0x2c, 0x0a]) }
                result.append(data)
            }
            if !projects.isEmpty { result.append(contentsOf: [0x0a, 0x5d]) }
            // A failed encode cannot publish partial entries. Drop deleted
            // projects so the cache does not become another undo history.
            entries = next
            return result
        }
    }
}
