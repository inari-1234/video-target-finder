@preconcurrency import Vision
import CoreImage
import CoreGraphics
import Foundation

struct TrackingSeedInstanceResult: Sendable {
    let localTopLeftRect: CGRect?
    let featureDistance: Float?
    let instanceIndex: Int?
    let instanceCount: Int
    let touchesMaskEdge: Bool
    let requestFailed: Bool
    let unsupportedMaskFormat: Bool
}

enum VisionMaskDiagnosticEngine {
    private struct GeneratedVariants {
        let allInstances: CGImage?
        let singleInstances: [CGImage]
        let instanceCount: Int
        let evaluatedSingleCount: Int
    }

    private static let maxSingleInstances = 8

    static func bestForegroundTrackingSeed(
        image: CGImage,
        matcher: FeaturePrintMatcher
    ) -> TrackingSeedInstanceResult {
        do {
            let ciContext = CIContext()
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            let request = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([request])
            guard let observation = request.results?.first else {
                return TrackingSeedInstanceResult(
                    localTopLeftRect: nil, featureDistance: nil, instanceIndex: nil,
                    instanceCount: 0, touchesMaskEdge: false,
                    requestFailed: false, unsupportedMaskFormat: false
                )
            }

            let instances = observation.allInstances
            guard !instances.isEmpty else {
                return TrackingSeedInstanceResult(
                    localTopLeftRect: nil, featureDistance: nil, instanceIndex: nil,
                    instanceCount: 0, touchesMaskEdge: false,
                    requestFailed: false, unsupportedMaskFormat: false
                )
            }

            guard let grid = instanceLabelGrid(from: observation.instanceMask) else {
                return TrackingSeedInstanceResult(
                    localTopLeftRect: nil, featureDistance: nil, instanceIndex: nil,
                    instanceCount: instances.count, touchesMaskEdge: false,
                    requestFailed: false, unsupportedMaskFormat: true
                )
            }
            let boxes = TrackingSeedBoxAnalyzer.tightBoxes(
                grid: grid,
                instances: IndexSet(instances.prefix(maxSingleInstances))
            )
            var best: (box: InstanceTightBox, distance: Float)?

            for box in boxes {
                let buffer = try observation.generateMaskedImage(
                    ofInstances: IndexSet(integer: box.instanceIndex),
                    from: handler,
                    croppedToInstancesExtent: false
                )
                guard let masked = flattenedCGImage(from: buffer, ciContext: ciContext) else { continue }
                let distance = try matcher.diagnosticPositiveDistance(for: masked)
                if best == nil || distance < best!.distance {
                    best = (box, distance)
                }
            }

            guard let best else {
                return TrackingSeedInstanceResult(
                    localTopLeftRect: nil, featureDistance: nil, instanceIndex: nil,
                    instanceCount: instances.count, touchesMaskEdge: false,
                    requestFailed: false, unsupportedMaskFormat: false
                )
            }
            return TrackingSeedInstanceResult(
                localTopLeftRect: best.box.localTopLeftRect,
                featureDistance: best.distance,
                instanceIndex: best.box.instanceIndex,
                instanceCount: instances.count,
                touchesMaskEdge: best.box.touchesMaskEdge,
                requestFailed: false,
                unsupportedMaskFormat: false
            )
        } catch {
            return TrackingSeedInstanceResult(
                localTopLeftRect: nil, featureDistance: nil, instanceIndex: nil,
                instanceCount: 0, touchesMaskEdge: false,
                requestFailed: true, unsupportedMaskFormat: false
            )
        }
    }

    private static func instanceLabelGrid(from pixelBuffer: CVPixelBuffer) -> InstanceMaskLabelGrid? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0, CVPixelBufferGetPlaneCount(pixelBuffer) == 0 else {
            return nil
        }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_OneComponent8 ||
              format == kCVPixelFormatType_OneComponent16 else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var labels = Array(repeating: UInt16(0), count: width * height)

        if format == kCVPixelFormatType_OneComponent8 {
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    labels[y * width + x] = UInt16(row[x])
                }
            }
        } else {
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
                for x in 0..<width {
                    labels[y * width + x] = row[x]
                }
            }
        }

        return InstanceMaskLabelGrid(width: width, height: height, labels: labels)
    }

    static func foregroundUnionDistance(
        image: CGImage,
        matcher: FeaturePrintMatcher
    ) -> (distance: Float?, instanceCount: Int, requestFailed: Bool) {
        do {
            let ciContext = CIContext()
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            let request = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([request])
            guard let observation = request.results?.first else {
                return (nil, 0, false)
            }
            let instances = observation.allInstances
            guard !instances.isEmpty else {
                return (nil, 0, false)
            }
            let buffer = try observation.generateMaskedImage(
                ofInstances: instances,
                from: handler,
                croppedToInstancesExtent: false
            )
            guard let masked = flattenedCGImage(from: buffer, ciContext: ciContext) else {
                return (nil, instances.count, false)
            }
            return (
                try matcher.diagnosticPositiveDistance(for: masked),
                instances.count,
                false
            )
        } catch {
            return (nil, 0, true)
        }
    }

    static func evaluate(
        image: CGImage,
        matcher: FeaturePrintMatcher
    ) throws -> CandidateMaskDiagnosticScores {
        let baseline = try matcher.diagnosticPositiveDistance(for: image)
        let ciContext = CIContext()

        let foreground = evaluateStrategy {
            try foregroundVariants(from: image, ciContext: ciContext)
        } matcher: { masked in
            try matcher.diagnosticPositiveDistance(for: masked)
        }

        let person = evaluateStrategy {
            try personVariants(from: image, ciContext: ciContext)
        } matcher: { masked in
            try matcher.diagnosticPositiveDistance(for: masked)
        }

        return CandidateMaskDiagnosticScores(
            baselineDistance: baseline,
            foreground: foreground,
            person: person
        )
    }

    private static func evaluateStrategy(
        _ producer: () throws -> GeneratedVariants,
        matcher: (CGImage) throws -> Float
    ) -> MaskStrategyCandidateResult {
        do {
            let generated = try producer()
            let allDistance = generated.allInstances.flatMap { try? matcher($0) }
            let singleDistances = generated.singleInstances.compactMap { try? matcher($0) }
            return MaskStrategyCandidateResult(
                allInstancesDistance: allDistance,
                bestSingleDistance: singleDistances.min(),
                instanceCount: generated.instanceCount,
                evaluatedSingleCount: generated.evaluatedSingleCount,
                requestFailed: false
            )
        } catch {
            return MaskStrategyCandidateResult(
                allInstancesDistance: nil,
                bestSingleDistance: nil,
                instanceCount: 0,
                evaluatedSingleCount: 0,
                requestFailed: true
            )
        }
    }

    private static func foregroundVariants(from image: CGImage, ciContext: CIContext) throws -> GeneratedVariants {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first else {
            return GeneratedVariants(allInstances: nil, singleInstances: [], instanceCount: 0, evaluatedSingleCount: 0)
        }
        return try generatedVariants(observation: observation, handler: handler, ciContext: ciContext)
    }

    private static func personVariants(from image: CGImage, ciContext: CIContext) throws -> GeneratedVariants {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let request = VNGeneratePersonInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first else {
            return GeneratedVariants(allInstances: nil, singleInstances: [], instanceCount: 0, evaluatedSingleCount: 0)
        }
        return try generatedVariants(observation: observation, handler: handler, ciContext: ciContext)
    }

    private static func generatedVariants(
        observation: VNInstanceMaskObservation,
        handler: VNImageRequestHandler,
        ciContext: CIContext
    ) throws -> GeneratedVariants {
        let instances = observation.allInstances
        guard !instances.isEmpty else {
            return GeneratedVariants(allInstances: nil, singleInstances: [], instanceCount: 0, evaluatedSingleCount: 0)
        }

        let allBuffer = try observation.generateMaskedImage(
            ofInstances: instances,
            from: handler,
            croppedToInstancesExtent: false
        )
        let allImage = flattenedCGImage(from: allBuffer, ciContext: ciContext)

        let selectedIndices = Array(instances.prefix(maxSingleInstances))
        var singles: [CGImage] = []
        singles.reserveCapacity(selectedIndices.count)
        for index in selectedIndices {
            let buffer = try observation.generateMaskedImage(
                ofInstances: IndexSet(integer: index),
                from: handler,
                croppedToInstancesExtent: false
            )
            if let cgImage = flattenedCGImage(from: buffer, ciContext: ciContext) {
                singles.append(cgImage)
            }
        }

        return GeneratedVariants(
            allInstances: allImage,
            singleInstances: singles,
            instanceCount: instances.count,
            evaluatedSingleCount: selectedIndices.count
        )
    }

    private static func flattenedCGImage(from pixelBuffer: CVPixelBuffer, ciContext: CIContext) -> CGImage? {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = source.extent.integral
        guard !extent.isEmpty, !extent.isInfinite else { return nil }

        // 元matchThumbnailと同じ画角/対象サイズを保ったまま、透過領域だけ中間グレーへflattenする。
        // instance外接矩形へのcropは行わず、再構図・拡大効果をA/Bへ混ぜない。
        let background = CIImage(
            color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
        ).cropped(to: extent)
        let flattened = source.composited(over: background)
        return ciContext.createCGImage(flattened, from: extent)
    }
}
