import Foundation

/// Retains the original linear fade when a split keeps only part of it.
/// This is derived editing state, not a second audio asset or a new gain control.
public struct AudioFadeEnvelope: Codable, Hashable, Sendable {
    public var duration: Double
    public var fadeIn: Double
    public var fadeOut: Double
    public var offset: Double

    public init(duration: Double, fadeIn: Double, fadeOut: Double, offset: Double = 0) {
        self.duration = duration
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.offset = offset
    }

    /// Interpolates the retained portion of the original envelope without
    /// restarting a fade at a split boundary.
    public func gain(at localTime: Double) -> Double {
        let time = offset + localTime
        if fadeIn > 0, time < fadeIn { return max(0, time / fadeIn) }
        if fadeOut > 0, time > duration - fadeOut { return max(0, (duration - time) / fadeOut) }
        return 1
    }

    /// Supplies exact ramp boundaries, including truncated fade endpoints.
    public func breakpoints(length: Double) -> [Double] {
        Array(Set([0, length, fadeIn - offset, duration - fadeOut - offset]
            .filter { $0 >= 0 && $0 <= length })).sorted()
    }
}

extension NarrationClip {
    public var effectiveFadeEnvelope: AudioFadeEnvelope {
        fadeEnvelope ?? AudioFadeEnvelope(duration: duration, fadeIn: fadeIn, fadeOut: fadeOut)
    }
}
