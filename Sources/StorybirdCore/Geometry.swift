import CoreGraphics

public enum AspectFit {
    public static func frame(contentSize: CGSize, in container: CGRect) -> CGRect {
        guard contentSize.width > 0,
              contentSize.height > 0,
              container.width > 0,
              container.height > 0
        else {
            return .zero
        }

        let scale = min(
            container.width / contentSize.width,
            container.height / contentSize.height
        )
        let fittedSize = CGSize(
            width: contentSize.width * scale,
            height: contentSize.height * scale
        )

        return CGRect(
            x: container.midX - fittedSize.width / 2,
            y: container.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }
}
