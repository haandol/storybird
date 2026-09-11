import CoreGraphics
import Foundation

/// Immutable bitmaps may be shared by simultaneous previews and exports. The
/// lock protects metadata; rendering stays outside it. Both bytes and entries
/// are bounded so animated geometry cannot retain a frame-sized image per tick.
final class OverlayRasterCache: @unchecked Sendable {
    enum Key: Hashable {
        case text(String, fontSize: CGFloat, width: CGFloat, height: CGFloat, color: String)
        case spotlight(
            x: Double, y: Double, width: Double, height: Double, opacity: Double,
            frameX: CGFloat, frameY: CGFloat, frameWidth: CGFloat, frameHeight: CGFloat
        )
    }

    private struct Entry {
        let image: CGImage
        let cost: Int
    }

    private struct TextLayoutKey: Hashable {
        let text: String
        let fontSize: CGFloat
        let width: CGFloat
        let lineLimit: Int
    }

    private let lock = NSLock()
    private let byteLimit: Int
    private let countLimit: Int
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var cost = 0
    private var textLayouts: [TextLayoutKey: CGSize] = [:]

    init(byteLimit: Int = 32 * 1_024 * 1_024, countLimit: Int = 128) {
        self.byteLimit = max(0, byteLimit)
        self.countLimit = max(0, countLimit)
    }

    func image(for key: Key, create: () -> CGImage?) -> CGImage? {
        if let cached = lock.withLock({ entries[key]?.image }) { return cached }
        guard let image = create() else { return nil }
        let (imageCost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !overflow, imageCost <= byteLimit, countLimit > 0 else { return image }
        return lock.withLock {
            if let cached = entries[key]?.image { return cached }
            while !order.isEmpty && (entries.count >= countLimit || cost > byteLimit - imageCost) {
                let removed = order.removeFirst()
                if let entry = entries.removeValue(forKey: removed) { cost -= entry.cost }
            }
            entries[key] = Entry(image: image, cost: imageCost)
            order.append(key)
            cost += imageCost
            return image
        }
    }

    /// Text wrapping is as stable as its raster; avoid rebuilding Core Text's
    /// framesetter on each tick just to recover the same label dimensions.
    func textSize(
        _ text: String, fontSize: CGFloat, width: CGFloat, lineLimit: Int,
        measure: () -> CGSize
    ) -> CGSize {
        let key = TextLayoutKey(text: text, fontSize: fontSize, width: width, lineLimit: lineLimit)
        if let value = lock.withLock({ textLayouts[key] }) { return value }
        let value = measure()
        guard countLimit > 0 else { return value }
        lock.withLock {
            if textLayouts.count >= countLimit { textLayouts.removeAll(keepingCapacity: true) }
            textLayouts[key] = value
        }
        return value
    }
}
