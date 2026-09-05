import CoreGraphics
import Foundation
import StorybirdMCPKit

/// Pointer geometry used only by the privileged Storybird app target.
enum StorybirdPointerGeometry {
    /// Maps the inclusive normalized range into the last addressable point.
    ///
    /// Quartz rectangles exclude their maximum edges, so exact `1.0` values
    /// use `nextDown` instead of becoming an out-of-source event.
    static func screenPoint(
        x: Double,
        y: Double,
        frame: CGRect
    ) throws -> CGPoint {
        guard x.isFinite,
              y.isFinite,
              (0...1).contains(x),
              (0...1).contains(y),
              frame.width > 0,
              frame.height > 0
        else {
            throw StorybirdMCPError.invalidCoordinate
        }
        let point = CGPoint(
            x: x == 1
                ? frame.maxX.nextDown
                : frame.minX + frame.width * x,
            y: y == 1
                ? frame.maxY.nextDown
                : frame.minY + frame.height * y
        )
        guard frame.contains(point) else {
            throw StorybirdMCPError.invalidCoordinate
        }
        return point
    }
}
