import CoreMedia

/// Picture edits and narration share this conversion precision. Source sample
/// rates and the short source slice used for freeze frames remain separate.
enum ProjectCompositionTime {
    static func fromSeconds(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 48_000)
    }
}
