@preconcurrency import Vision
import CoreGraphics
import ImageIO

struct VisionTrackingFrameOutput: Sendable {
    let boundingBox: CGRect?
    let confidence: Float?
    let requestFailed: Bool
}

struct SendableCGImageSequence: @unchecked Sendable {
    let images: [CGImage]
}

enum VisionObjectTrackingEngine {
    static func track(
        images: [CGImage],
        seedRect: CGRect
    ) -> [VisionTrackingFrameOutput] {
        guard !images.isEmpty,
              seedRect.width > 0,
              seedRect.height > 0 else {
            return []
        }

        let handler = VNSequenceRequestHandler()
        var observation = VNDetectedObjectObservation(boundingBox: seedRect)
        var outputs: [VisionTrackingFrameOutput] = []
        outputs.reserveCapacity(images.count)

        var lost = false
        for image in images {
            if lost {
                outputs.append(
                    VisionTrackingFrameOutput(
                        boundingBox: nil,
                        confidence: nil,
                        requestFailed: false
                    )
                )
                continue
            }

            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .accurate
            do {
                try handler.perform([request], on: image, orientation: .up)
                guard let next = request.results?.first as? VNDetectedObjectObservation else {
                    outputs.append(
                        VisionTrackingFrameOutput(
                            boundingBox: nil,
                            confidence: nil,
                            requestFailed: false
                        )
                    )
                    lost = true
                    continue
                }
                outputs.append(
                    VisionTrackingFrameOutput(
                        boundingBox: next.boundingBox,
                        confidence: next.confidence,
                        requestFailed: false
                    )
                )
                observation = next
            } catch {
                outputs.append(
                    VisionTrackingFrameOutput(
                        boundingBox: nil,
                        confidence: nil,
                        requestFailed: true
                    )
                )
                lost = true
            }
        }

        return outputs
    }
}
