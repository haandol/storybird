import Foundation

public struct CaptionListEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case independent, cue }
    public var id: UUID
    public var kind: Kind
    public var startTime: Double
    public var endTime: Double
    public var text: String
    public var description: String?
    public var complete: Bool
    private enum CodingKeys: String, CodingKey {
        case id, kind, text, description, complete
        case startTime = "start_time", endTime = "end_time"
    }
    public var target: ProjectEditReference { ProjectEditReference(target: kind == .cue ? .click : .subtitle, id: id) }

    /// Lists complete source text, including empty Cue slots, without replacing
    /// either caption kind or changing completion rules.
    public static func entries(in project: DemoProject) -> [Self] {
        let independent = project.subtitles.map { Self(id: $0.id, kind: .independent, startTime: $0.startTime,
            endTime: $0.endTime, text: $0.text, complete: !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        let cues = project.clicks.map { Self(id: $0.id, kind: .cue, startTime: $0.cueSubtitle.startTime,
            endTime: $0.cueSubtitle.endTime, text: $0.cueSubtitle.text, description: $0.description.text, complete: $0.isComplete) }
        return (independent + cues).sorted {
            ($0.startTime, $0.endTime, $0.kind == .independent ? 0 : 1, $0.id.uuidString)
                < ($1.startTime, $1.endTime, $1.kind == .independent ? 0 : 1, $1.id.uuidString)
        }
    }
}

public enum SubtitleEditing {
    /// Splits by Swift Character count (extended Unicode grapheme clusters).
    /// Text is sliced verbatim; the new right start must also have a valid owner
    /// when the original caption follows a scene.
    public static func split(_ id: UUID, in project: DemoProject, at time: Double, textOffset: Int) throws -> DemoProject {
        guard let index = project.subtitles.firstIndex(where: { $0.id == id }) else { throw missing(id) }
        let original = project.subtitles[index]
        guard time.isFinite, time > original.startTime, time < original.endTime else {
            throw ProjectEditError(code: "invalid_split", targetID: id, property: "time",
                allowedRange: "\(original.startTime) < time < \(original.endTime)", message: "Split inside the caption interval.")
        }
        guard textOffset > 0, textOffset < original.text.count else {
            throw ProjectEditError(code: "invalid_split", targetID: id, property: "text_offset",
                allowedRange: "0 < grapheme offset < \(original.text.count)", message: "Choose an internal Unicode character boundary.")
        }
        let boundary = original.text.index(original.text.startIndex, offsetBy: textOffset)
        let first = String(original.text[..<boundary]), second = String(original.text[boundary...])
        guard !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !second.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectEditError(code: "invalid_split", targetID: id, property: "text_offset", message: "Both caption parts need text.")
        }
        var left = original, right = original
        left.text = first
        left.endTime = time
        right.id = UUID()
        right.text = second
        right.startTime = time
        if original.sceneAnchor != nil { right.sceneAnchor = try SceneTiming.anchor(at: time, in: project) }
        var result = project
        result.subtitles.replaceSubrange(index...index, with: [left, right])
        return result
    }

    /// Extends the first independent caption through adjacent, non-overlapping
    /// selected captions, preserving its style/position/start ownership. The
    /// caller supplies the exact combined text; no Cue is converted or removed.
    public static func merge(_ firstID: UUID, relatedIDs: [UUID], text: String, in project: DemoProject) throws -> DemoProject {
        let ids = [firstID] + relatedIDs
        guard ids.count >= 2, Set(ids).count == ids.count,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectEditError(code: "invalid_merge", targetID: firstID, property: "related_ids/text",
                message: "Merge at least two distinct captions with nonblank combined text.")
        }
        let sorted = project.subtitles.sorted { ($0.startTime, $0.endTime, $0.id.uuidString) < ($1.startTime, $1.endTime, $1.id.uuidString) }
        let chosen = sorted.enumerated().filter { ids.contains($0.element.id) }
        guard chosen.count == ids.count else { throw missing(ids.first { id in !project.subtitles.contains { $0.id == id } } ?? firstID) }
        guard chosen.first?.element.id == firstID else {
            throw ProjectEditError(code: "invalid_merge", targetID: firstID, property: "id", message: "Use the earliest selected caption as the merge target.")
        }
        for pair in zip(chosen, chosen.dropFirst()) {
            guard pair.1.offset == pair.0.offset + 1, pair.0.element.endTime <= pair.1.element.startTime else {
                throw ProjectEditError(code: "invalid_merge", targetID: firstID, property: "related_ids",
                    message: "Selected independent captions must be adjacent in time order and must not overlap.")
            }
        }
        var merged = chosen[0].element
        merged.text = text
        merged.endTime = chosen.last!.element.endTime
        var result = project
        result.subtitles = result.subtitles.compactMap { value in
            if value.id == firstID { return merged }
            return ids.contains(value.id) ? nil : value
        }
        return result
    }

    private static func missing(_ id: UUID) -> ProjectEditError {
        ProjectEditError(code: "missing_target", targetID: id, property: "id", message: "The independent caption does not exist. Cue captions cannot be split or merged.")
    }
}

public enum SRTCaptionScope: String, Codable, CaseIterable, Sendable { case independent, cue, both }

public enum SRTError: LocalizedError, Equatable {
    case invalidUTF8, invalidBlock(Int), invalidTime(Int), unrepresentableText(UUID), collapsedInterval(UUID)
    public var errorDescription: String? {
        switch self {
        case .invalidUTF8: "The subtitle file must be UTF-8."
        case let .invalidBlock(line): "Invalid SRT caption near line \(line)."
        case let .invalidTime(line): "Invalid SRT time interval near line \(line)."
        case let .unrepresentableText(id): "Caption \(id) needs nonblank text without blank lines for SRT export."
        case let .collapsedInterval(id): "Caption \(id) has no positive interval after rounding to milliseconds."
        }
    }
}

public enum SRTCaptions {
    /// Parses a whole UTF-8 SRT before its caller appends any captions. Numeric
    /// sequence labels are input labels, not persisted identities.
    public static func parse(_ data: Data) throws -> [TimedSubtitle] {
        guard var text = String(data: data, encoding: .utf8) else { throw SRTError.invalidUTF8 }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var index = 0
        var captions: [TimedSubtitle] = []
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }
            let line = index + 1
            guard let number = Int(lines[index].trimmingCharacters(in: .whitespaces)), number > 0,
                  index + 1 < lines.count else { throw SRTError.invalidBlock(line) }
            index += 1
            let bounds = lines[index].components(separatedBy: "-->")
            guard bounds.count == 2 else { throw SRTError.invalidTime(index + 1) }
            let start = try seconds(bounds[0], line: index + 1), end = try seconds(bounds[1], line: index + 1)
            guard start < end else { throw SRTError.invalidTime(index + 1) }
            index += 1
            var textLines: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                textLines.append(lines[index]); index += 1
            }
            guard !textLines.isEmpty else { throw SRTError.invalidBlock(line) }
            captions.append(TimedSubtitle(startTime: start, endTime: end, text: textLines.joined(separator: "\n")))
        }
        guard !captions.isEmpty else { throw SRTError.invalidBlock(1) }
        return captions
    }

    /// Produces deterministic text without modifying project captions. Decimal
    /// rounding keeps exact half-millisecond inputs directed upward.
    public static func encode(project: DemoProject, scope: SRTCaptionScope) throws -> String {
        struct Row { var id: UUID; var start: Double; var end: Double; var text: String; var kind: Int }
        var rows: [Row] = []
        if scope != .cue { rows += project.subtitles.map { Row(id: $0.id, start: $0.startTime, end: $0.endTime, text: $0.text, kind: 0) } }
        if scope != .independent { rows += project.clicks.map { Row(id: $0.id, start: $0.cueSubtitle.startTime, end: $0.cueSubtitle.endTime, text: $0.cueSubtitle.text, kind: 1) } }
        rows.sort { ($0.start, $0.end, $0.kind, $0.id.uuidString) < ($1.start, $1.end, $1.kind, $1.id.uuidString) }
        return try rows.enumerated().map { index, row in
            let lines = row.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            guard !row.text.contains("\0"), !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                throw SRTError.unrepresentableText(row.id)
            }
            let start = try milliseconds(row.start, id: row.id), end = try milliseconds(row.end, id: row.id)
            guard end > start else { throw SRTError.collapsedInterval(row.id) }
            return "\(index + 1)\n\(timestamp(start)) --> \(timestamp(end))\n\(row.text)\n"
        }.joined(separator: "\n")
    }

    private static func seconds(_ text: String, line: Int) throws -> Double {
        let parts = text.trimmingCharacters(in: .whitespaces).components(separatedBy: ":")
        guard parts.count == 3 else { throw SRTError.invalidTime(line) }
        let fraction = parts[2].components(separatedBy: ",")
        let digits = CharacterSet(charactersIn: "0123456789")
        guard fraction.count == 2, parts[0].count >= 2, parts[1].count == 2,
              fraction[0].count == 2, fraction[1].count == 3,
              [parts[0], parts[1], fraction[0], fraction[1]].allSatisfy({ $0.unicodeScalars.allSatisfy(digits.contains) }),
              let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(fraction[0]), let millis = Double(fraction[1]),
              minutes < 60, seconds < 60 else { throw SRTError.invalidTime(line) }
        let value = hours * 3600 + minutes * 60 + seconds + millis / 1000
        guard value.isFinite else { throw SRTError.invalidTime(line) }
        return value
    }

    private static func milliseconds(_ seconds: Double, id: UUID) throws -> Int64 {
        guard seconds.isFinite, seconds >= 0, var value = Decimal(string: String(seconds), locale: Locale(identifier: "en_US_POSIX")) else {
            throw SRTError.collapsedInterval(id)
        }
        value *= 1000
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        let number = NSDecimalNumber(decimal: rounded)
        guard number != .notANumber, number.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending else { throw SRTError.collapsedInterval(id) }
        return number.int64Value
    }

    private static func timestamp(_ value: Int64) -> String {
        String(format: "%02lld:%02lld:%02lld,%03lld", value / 3_600_000, value / 60_000 % 60, value / 1000 % 60, value % 1000)
    }
}
