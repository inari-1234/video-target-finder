import CoreGraphics

struct SearchRegion: Sendable {
    let label: String
    /// 0...1 の正規化座標。CGImage上で切り出すための領域。
    let normalizedRect: CGRect
}

enum FrameRegionSampler {
    static func regions(for mode: SearchSensitivity) -> [SearchRegion] {
        var result: [SearchRegion] = [
            SearchRegion(label: "画面全体", normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        ]

        // 2x2 の大きな局所領域。境界付近の対象を欠きにくいよう少し重ねる。
        let quadrantSize: CGFloat = 0.58
        let quadrantOrigins: [(CGFloat, CGFloat, String)] = [
            (0.00, 0.00, "局所A"),
            (0.42, 0.00, "局所B"),
            (0.00, 0.42, "局所C"),
            (0.42, 0.42, "局所D")
        ]
        result.append(contentsOf: quadrantOrigins.map { x, y, label in
            SearchRegion(label: label, normalizedRect: CGRect(x: x, y: y, width: quadrantSize, height: quadrantSize))
        })

        guard mode != .fast else { return result }

        // 標準では中央・左右・上下を追加。画面端や縦長/横長の対象に強くする。
        result.append(contentsOf: [
            SearchRegion(label: "中央", normalizedRect: CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60)),
            SearchRegion(label: "左帯", normalizedRect: CGRect(x: 0.00, y: 0.12, width: 0.50, height: 0.76)),
            SearchRegion(label: "右帯", normalizedRect: CGRect(x: 0.50, y: 0.12, width: 0.50, height: 0.76)),
            SearchRegion(label: "上帯", normalizedRect: CGRect(x: 0.12, y: 0.00, width: 0.76, height: 0.50)),
            SearchRegion(label: "下帯", normalizedRect: CGRect(x: 0.12, y: 0.50, width: 0.76, height: 0.50))
        ])

        guard mode == .thorough else { return result }

        // 高感度では 3x3 の中心点を持つ重なり窓を追加。
        // 1/3に完全分割せず45%幅にすることで、境界をまたぐ対象を拾いやすくする。
        let windowSize: CGFloat = 0.45
        let centers: [CGFloat] = [0.225, 0.5, 0.775]
        var index = 1
        for cy in centers {
            for cx in centers {
                let rect = CGRect(
                    x: cx - windowSize / 2,
                    y: cy - windowSize / 2,
                    width: windowSize,
                    height: windowSize
                )
                result.append(SearchRegion(label: "細分\(index)", normalizedRect: rect))
                index += 1
            }
        }

        return result
    }

    static func croppedImage(from image: CGImage, region: SearchRegion) -> CGImage? {
        croppedImage(from: image, normalizedRect: region.normalizedRect)
    }

    static func croppedImage(from image: CGImage, normalizedRect: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }

        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let normalized = normalizedRect.intersection(unit)
        guard !normalized.isNull, normalized.width > 0, normalized.height > 0 else { return nil }

        var pixelRect = CGRect(
            x: normalized.minX * width,
            y: normalized.minY * height,
            width: normalized.width * width,
            height: normalized.height * height
        ).integral

        pixelRect = pixelRect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard pixelRect.width >= 2, pixelRect.height >= 2 else { return nil }
        return image.cropping(to: pixelRect)
    }
}
