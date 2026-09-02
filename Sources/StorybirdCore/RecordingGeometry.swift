import CoreGraphics

public enum RecordingGeometry {
    public static func normalizedCaptureClick(
        capturePoint: CGPoint,
        captureFrame: CGRect
    ) -> CGPoint? {
        guard captureFrame.width > 0,
              captureFrame.height > 0,
              captureFrame.contains(capturePoint)
        else {
            return nil
        }

        return CGPoint(
            x: min(
                max(
                    (capturePoint.x - captureFrame.minX) / captureFrame.width,
                    0
                ),
                1
            ),
            y: min(
                max(
                    (capturePoint.y - captureFrame.minY) / captureFrame.height,
                    0
                ),
                1
            )
        )
    }

    public static func normalizedClick(
        screenPoint: CGPoint,
        screenFrame: CGRect
    ) -> CGPoint? {
        guard screenFrame.width > 0,
              screenFrame.height > 0,
              screenFrame.contains(screenPoint)
        else {
            return nil
        }

        let x = (screenPoint.x - screenFrame.minX) / screenFrame.width
        let yFromBottom = (screenPoint.y - screenFrame.minY) / screenFrame.height
        return CGPoint(
            x: min(max(x, 0), 1),
            y: min(max(1 - yFromBottom, 0), 1)
        )
    }
}
