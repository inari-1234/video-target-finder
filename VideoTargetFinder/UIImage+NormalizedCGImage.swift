import UIKit

extension UIImage {
    /// UIImage.imageOrientationを反映した、Visionへ渡しやすい向き固定済みCGImageを返す。
    func normalizedCGImage(maxDimension: CGFloat = 1024) -> CGImage? {
        let sourceSize = size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return cgImage }

        let scaleDown = min(1, maxDimension / max(sourceSize.width, sourceSize.height))
        let outputSize = CGSize(
            width: max(1, floor(sourceSize.width * scaleDown)),
            height: max(1, floor(sourceSize.height * scaleDown))
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1

        let rendered = UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: outputSize))
        }
        return rendered.cgImage
    }
}
