import CoreGraphics
import UIKit

/// Stage 7: 長時間解析で保持する画像を必要最小限のサイズへ縮小する。
enum ImageMemoryTools {
    static func thumbnail(from image: CGImage, maxDimension: CGFloat) -> UIImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return UIImage(cgImage: image) }

        let scale = min(1, maxDimension / max(width, height))
        guard scale < 0.999 else { return UIImage(cgImage: image) }

        let target = CGSize(
            width: max(1, (width * scale).rounded()),
            height: max(1, (height * scale).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: target))
        }
    }

    static func placeholder(size: CGSize = CGSize(width: 160, height: 90)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.secondarySystemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

/// CGImage自体の所有権を保ったまま、CPU解析タスクへ安全に渡すための箱。
final class SendableCGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
