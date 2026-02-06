//
//  ImageUpscaler.swift
//  Upscaler
//
//  Created by Giovanni Di Nisio on 18/12/2025.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import CoreVideo
import Foundation
import Vision
#if canImport(VideoToolbox)
import VideoToolbox
#endif

struct UpscaleComputationResult {
    let image: CGImage
    let backendSummary: String
    let usedAIEnhancement: Bool
    let aiModelSummary: String?
    let aiInferencePassCount: Int
}

enum ImageUpscalerError: LocalizedError {
    case failedToProduceImage
    case failedToCreatePixelBuffer
    case failedToCreateFrame
    case failedToStartProcessingSession
    case unsupportedPixelFormat
    case coreMLOutputNotImage

    var errorDescription: String? {
        switch self {
        case .failedToProduceImage:
            return "Upscaling failed. Please try again with a different scale."
        case .failedToCreatePixelBuffer:
            return "Unable to prepare buffers for super-resolution."
        case .failedToCreateFrame:
            return "Unable to build processing frames for super-resolution."
        case .failedToStartProcessingSession:
            return "Unable to start the super-resolution processor."
        case .unsupportedPixelFormat:
            return "No compatible pixel format was available for super-resolution."
        case .coreMLOutputNotImage:
            return "The AI model did not return an image output."
        }
    }
}

private struct CoreMLModelDescriptor {
    let name: String
    let visionModel: VNCoreMLModel
    let preferredTileSize: CGSize?
    let nominalScale: Double
}

private struct CoreMLPassResult {
    let image: CGImage
    let scaleX: Double
    let scaleY: Double
}

private struct CoreMLPipelineResult {
    let image: CGImage
    let remainingScale: Double
    let modelSummary: String
    let inferencePassCount: Int
}

private struct CoreMLStrategy {
    let restorationModel: CoreMLModelDescriptor?
    let upscaleModel: CoreMLModelDescriptor
}

private enum InferenceAugmentation: CaseIterable {
    case identity
    case flipHorizontal
    case flipVertical
    case rotate180
}

struct ImageUpscaler {
    private let videoToolboxTileOverlap = 32
    private let coreMLTileOverlap = 24

    private let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .useSoftwareRenderer: false
        ]
        return CIContext(options: options)
    }()

    func upscale(_ cgImage: CGImage, options: UpscaleOptions) async throws -> UpscaleComputationResult {
        var currentImage = cgImage
        let requestedScale = max(options.scale, 1.0)
        var remainingScale = requestedScale
        var backends: [String] = []
        var usedAI = false
        var aiModelSummary: String?
        var aiInferencePassCount = 0

        if remainingScale > 1.01 {
            do {
                if let coreMLResult = try await upscaleWithBundledCoreMLModel(
                    currentImage,
                    requestedScale: remainingScale,
                    qualityMode: options.aiQualityMode
                ) {
                    currentImage = coreMLResult.image
                    remainingScale = coreMLResult.remainingScale
                    backends.append("Core ML \(coreMLResult.modelSummary)")
                    aiModelSummary = coreMLResult.modelSummary
                    aiInferencePassCount += coreMLResult.inferencePassCount
                    usedAI = true
                }
            } catch {
                // Keep full app functionality by allowing fallback backends.
            }
        }

        #if canImport(VideoToolbox) && !targetEnvironment(simulator)
        if #available(macOS 26.0, iOS 26.0, *), remainingScale > 1.01 {
            while let factor = bestSuperResolutionFactor(for: remainingScale) {
                do {
                    currentImage = try await upscaleWithSuperResolution(currentImage, scaleFactor: factor)
                    remainingScale /= Double(factor)
                    backends.append("VideoToolbox SR x\(factor)")
                    usedAI = true
                } catch {
                    break
                }

                if remainingScale < 1.01 {
                    break
                }
            }
        }
        #endif

        if remainingScale > 1.01 {
            currentImage = try lanczosUpscale(currentImage, scale: max(remainingScale, 1.0))
            backends.append(String(format: "Lanczos x%.2f", remainingScale))
        }

        let targetWidth = max(1, Int(round(Double(cgImage.width) * requestedScale)))
        let targetHeight = max(1, Int(round(Double(cgImage.height) * requestedScale)))
        if currentImage.width != targetWidth || currentImage.height != targetHeight {
            let normalizeScaleX = Double(targetWidth) / Double(max(currentImage.width, 1))
            let normalizeScaleY = Double(targetHeight) / Double(max(currentImage.height, 1))
            currentImage = try lanczosResample(
                currentImage,
                scaleX: normalizeScaleX,
                scaleY: normalizeScaleY
            )
            backends.append("Normalize to \(targetWidth)x\(targetHeight)")
        }

        if options.applySharpen {
            currentImage = try applySharpen(to: currentImage)
            backends.append("Sharpen")
        }

        if backends.isEmpty {
            backends.append("No processing")
        } else if !usedAI, requestedScale > 1.01 {
            backends.append("No AI model used")
        }

        return UpscaleComputationResult(
            image: currentImage,
            backendSummary: backends.joined(separator: " -> "),
            usedAIEnhancement: usedAI,
            aiModelSummary: aiModelSummary,
            aiInferencePassCount: aiInferencePassCount
        )
    }

    private func lanczosUpscale(_ cgImage: CGImage, scale: Double) throws -> CGImage {
        try lanczosResample(cgImage, scaleX: scale, scaleY: scale)
    }

    private func lanczosResample(_ cgImage: CGImage, scaleX: Double, scaleY: Double) throws -> CGImage {
        guard scaleX > 0, scaleY > 0 else { return cgImage }
        if abs(scaleX - 1.0) < 0.001, abs(scaleY - 1.0) < 0.001 {
            return cgImage
        }

        let input = CIImage(cgImage: cgImage)
        let scaleFilter = CIFilter.lanczosScaleTransform()
        scaleFilter.inputImage = input
        scaleFilter.scale = Float(scaleX)
        scaleFilter.aspectRatio = Float(scaleY / scaleX)

        let output = scaleFilter.outputImage ?? input
        let extent = output.extent.integral
        guard let cgOutput = context.createCGImage(output, from: extent) else {
            throw ImageUpscalerError.failedToProduceImage
        }
        return cgOutput
    }

    private func applySharpen(to cgImage: CGImage) throws -> CGImage {
        let input = CIImage(cgImage: cgImage)
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = input
        sharpen.sharpness = 0.35
        sharpen.radius = 1.2

        let output = sharpen.outputImage ?? input
        let extent = output.extent.integral
        guard let cgOutput = context.createCGImage(output, from: extent) else {
            throw ImageUpscalerError.failedToProduceImage
        }
        return cgOutput
    }

    private func upscaleWithBundledCoreMLModel(
        _ cgImage: CGImage,
        requestedScale: Double,
        qualityMode: UpscaleOptions.AIQualityMode
    ) async throws -> CoreMLPipelineResult? {
        guard requestedScale > 1.01 else { return nil }

        let models = try loadBundledCoreMLModels()
        guard !models.isEmpty else { return nil }
        guard let strategy = selectCoreMLStrategy(for: qualityMode, from: models) else { return nil }

        var currentImage = cgImage
        var remainingScale = requestedScale
        var passCount = 0
        var inferencePassCount = 0
        let maxPasses = 4
        let augmentations = augmentations(for: qualityMode)
        var stageLabels: [String] = []

        if let restorationModel = strategy.restorationModel {
            let restorationPass = try runCoreMLPassWithAugmentations(
                on: currentImage,
                model: restorationModel,
                augmentations: augmentations
            )
            let restoreTargetWidth = currentImage.width
            let restoreTargetHeight = currentImage.height
            if restorationPass.image.width == restoreTargetWidth && restorationPass.image.height == restoreTargetHeight {
                currentImage = restorationPass.image
            } else {
                currentImage = try lanczosResample(
                    restorationPass.image,
                    scaleX: Double(restoreTargetWidth) / Double(max(restorationPass.image.width, 1)),
                    scaleY: Double(restoreTargetHeight) / Double(max(restorationPass.image.height, 1))
                )
            }
            inferencePassCount += augmentations.count
            stageLabels.append("\(restorationModel.name) restore")
        }

        while remainingScale > 1.01, passCount < maxPasses {
            let pass = try runCoreMLPassWithAugmentations(
                on: currentImage,
                model: strategy.upscaleModel,
                augmentations: augmentations
            )
            let effectiveScale = min(pass.scaleX, pass.scaleY)
            guard effectiveScale > 1.01 else { break }

            let normalizedWidth = max(1, Int(round(Double(currentImage.width) * effectiveScale)))
            let normalizedHeight = max(1, Int(round(Double(currentImage.height) * effectiveScale)))

            if pass.image.width != normalizedWidth || pass.image.height != normalizedHeight {
                let correctionScaleX = Double(normalizedWidth) / Double(max(pass.image.width, 1))
                let correctionScaleY = Double(normalizedHeight) / Double(max(pass.image.height, 1))
                currentImage = try lanczosResample(
                    pass.image,
                    scaleX: correctionScaleX,
                    scaleY: correctionScaleY
                )
            } else {
                currentImage = pass.image
            }

            remainingScale /= effectiveScale
            passCount += 1
            inferencePassCount += augmentations.count

            let hint = max(strategy.upscaleModel.nominalScale, 1.0)
            if hint > 1.01, remainingScale < (hint - 0.05) {
                break
            }
        }

        guard passCount > 0 else { return nil }
        stageLabels.append(strategy.upscaleModel.name)

        let summary = "mode \(qualityMode.displayName), pipeline \(stageLabels.joined(separator: " + ")), TTA x\(augmentations.count)"

        return CoreMLPipelineResult(
            image: currentImage,
            remainingScale: remainingScale,
            modelSummary: summary,
            inferencePassCount: inferencePassCount
        )
    }

    private func runCoreMLPass(on cgImage: CGImage, model: CoreMLModelDescriptor) throws -> CoreMLPassResult {
        let canRunFullImageDirectly: Bool
        if let fixedInput = model.preferredTileSize {
            canRunFullImageDirectly = Int(fixedInput.width) == cgImage.width && Int(fixedInput.height) == cgImage.height
        } else {
            canRunFullImageDirectly = true
        }

        if canRunFullImageDirectly {
            if let fullOutput = try? runCoreMLModel(model.visionModel, on: cgImage),
               fullOutput.width > cgImage.width,
               fullOutput.height > cgImage.height {
                return CoreMLPassResult(
                    image: fullOutput,
                    scaleX: Double(fullOutput.width) / Double(cgImage.width),
                    scaleY: Double(fullOutput.height) / Double(cgImage.height)
                )
            }
        }

        return try runCoreMLPassWithTiling(on: cgImage, model: model)
    }

    private func selectCoreMLStrategy(
        for qualityMode: UpscaleOptions.AIQualityMode,
        from models: [CoreMLModelDescriptor]
    ) -> CoreMLStrategy? {
        let upscalers = models.filter { $0.nominalScale > 1.01 }
        guard let upscaleModel = preferredUpscaleModel(from: upscalers) else {
            return nil
        }

        guard qualityMode != .fast else {
            return CoreMLStrategy(restorationModel: nil, upscaleModel: upscaleModel)
        }

        let restorers = models.filter { $0.nominalScale <= 1.01 && $0.name != upscaleModel.name }
        let restorationModel = preferredRestorationModel(from: restorers)
        return CoreMLStrategy(restorationModel: restorationModel, upscaleModel: upscaleModel)
    }

    private func preferredUpscaleModel(from candidates: [CoreMLModelDescriptor]) -> CoreMLModelDescriptor? {
        guard !candidates.isEmpty else { return nil }

        let preferredNames = [
            "RealESRGAN",
            "RealESRGAN_x4",
            "RealESRGANx4",
            "RealESRGAN_x2",
            "RealESRGANx2"
        ]

        for preferredName in preferredNames {
            if let match = candidates.first(where: { $0.name.caseInsensitiveCompare(preferredName) == .orderedSame }) {
                return match
            }
        }

        if let realesrgan = candidates.first(where: { $0.name.lowercased().contains("realesrgan") }) {
            return realesrgan
        }

        return candidates.max(by: { $0.nominalScale < $1.nominalScale })
    }

    private func preferredRestorationModel(from candidates: [CoreMLModelDescriptor]) -> CoreMLModelDescriptor? {
        if let bsrgan = candidates.first(where: { $0.name.lowercased().contains("bsrgan") }) {
            return bsrgan
        }
        return candidates.first
    }

    private func augmentations(for qualityMode: UpscaleOptions.AIQualityMode) -> [InferenceAugmentation] {
        switch qualityMode {
        case .fast:
            return [.identity]
        case .balanced:
            return [.identity, .flipHorizontal]
        case .ultra:
            return [.identity, .flipHorizontal, .flipVertical, .rotate180]
        }
    }

    private func runCoreMLPassWithAugmentations(
        on cgImage: CGImage,
        model: CoreMLModelDescriptor,
        augmentations: [InferenceAugmentation]
    ) throws -> CoreMLPassResult {
        guard augmentations.count > 1 else {
            return try runCoreMLPass(on: cgImage, model: model)
        }

        var outputs: [CGImage] = []
        var scalesX: [Double] = []
        var scalesY: [Double] = []

        for augmentation in augmentations {
            let transformedInput = try applying(augmentation, to: cgImage)
            let pass = try runCoreMLPass(on: transformedInput, model: model)
            let restoredOutput = try applying(augmentation, to: pass.image)

            outputs.append(restoredOutput)
            scalesX.append(Double(restoredOutput.width) / Double(max(cgImage.width, 1)))
            scalesY.append(Double(restoredOutput.height) / Double(max(cgImage.height, 1)))
        }

        let merged = try mergeAugmentedOutputs(outputs)
        let averageScaleX = scalesX.reduce(0, +) / Double(max(scalesX.count, 1))
        let averageScaleY = scalesY.reduce(0, +) / Double(max(scalesY.count, 1))

        return CoreMLPassResult(image: merged, scaleX: averageScaleX, scaleY: averageScaleY)
    }

    private func applying(_ augmentation: InferenceAugmentation, to cgImage: CGImage) throws -> CGImage {
        guard augmentation != .identity else { return cgImage }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let input = CIImage(cgImage: cgImage)

        let transform: CGAffineTransform
        switch augmentation {
        case .identity:
            transform = .identity
        case .flipHorizontal:
            transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
        case .flipVertical:
            transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        case .rotate180:
            transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        }

        let transformed = input.transformed(by: transform).cropped(to: extent)
        guard let output = context.createCGImage(transformed, from: extent) else {
            throw ImageUpscalerError.failedToProduceImage
        }
        return output
    }

    private func mergeAugmentedOutputs(_ images: [CGImage]) throws -> CGImage {
        guard let first = images.first else {
            throw ImageUpscalerError.failedToProduceImage
        }
        if images.count == 1 {
            return first
        }

        let targetWidth = first.width
        let targetHeight = first.height
        let extent = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        var merged = CIImage(cgImage: first)

        for (index, image) in images.enumerated().dropFirst() {
            let alignedImage: CGImage
            if image.width == targetWidth, image.height == targetHeight {
                alignedImage = image
            } else {
                alignedImage = try lanczosResample(
                    image,
                    scaleX: Double(targetWidth) / Double(max(image.width, 1)),
                    scaleY: Double(targetHeight) / Double(max(image.height, 1))
                )
            }

            let blendFactor = Float(1.0 / Double(index + 1))
            let dissolve = CIFilter.dissolveTransition()
            dissolve.inputImage = CIImage(cgImage: alignedImage)
            dissolve.targetImage = merged
            dissolve.time = blendFactor
            merged = dissolve.outputImage ?? merged
        }

        guard let output = context.createCGImage(merged, from: extent) else {
            throw ImageUpscalerError.failedToProduceImage
        }
        return output
    }

    private func runCoreMLPassWithTiling(on cgImage: CGImage, model: CoreMLModelDescriptor) throws -> CoreMLPassResult {
        let preferredTileWidth = Int(model.preferredTileSize?.width ?? 768)
        let preferredTileHeight = Int(model.preferredTileSize?.height ?? 768)
        let hasFixedInputSize = model.preferredTileSize != nil
        let tileWidth = hasFixedInputSize
            ? max(64, preferredTileWidth)
            : min(cgImage.width, max(64, preferredTileWidth))
        let tileHeight = hasFixedInputSize
            ? max(64, preferredTileHeight)
            : min(cgImage.height, max(64, preferredTileHeight))
        let workingWidth = max(cgImage.width, tileWidth)
        let workingHeight = max(cgImage.height, tileHeight)
        let sourceRect = CGRect(x: 0, y: 0, width: workingWidth, height: workingHeight)

        let source: CIImage = {
            let base = CIImage(cgImage: cgImage)
            if workingWidth == cgImage.width && workingHeight == cgImage.height {
                return base
            }
            return base.clampedToExtent().cropped(to: sourceRect)
        }()

        let overlap = min(coreMLTileOverlap, max(0, min(tileWidth, tileHeight) / 4))
        let stepX = max(1, tileWidth - overlap)
        let stepY = max(1, tileHeight - overlap)

        let xOrigins = tileOrigins(total: workingWidth, tile: tileWidth, step: stepX)
        let yOrigins = tileOrigins(total: workingHeight, tile: tileHeight, step: stepY)

        var inferredScaleX: Double?
        var inferredScaleY: Double?
        var outputRect = CGRect.zero
        var stitchedImage: CIImage?

        for y in yOrigins {
            for x in xOrigins {
                let sourceRect = CGRect(
                    x: x,
                    y: y,
                    width: min(tileWidth, workingWidth - x),
                    height: min(tileHeight, workingHeight - y)
                )

                guard let tileCG = context.createCGImage(source, from: sourceRect) else {
                    throw ImageUpscalerError.failedToProduceImage
                }

                let tileOutput = try runCoreMLModel(model.visionModel, on: tileCG)

                let tileScaleX = Double(tileOutput.width) / Double(max(tileCG.width, 1))
                let tileScaleY = Double(tileOutput.height) / Double(max(tileCG.height, 1))

                if inferredScaleX == nil || inferredScaleY == nil {
                    inferredScaleX = tileScaleX
                    inferredScaleY = tileScaleY
                    outputRect = CGRect(
                        x: 0,
                        y: 0,
                        width: Double(workingWidth) * tileScaleX,
                        height: Double(workingHeight) * tileScaleY
                    )
                    stitchedImage = CIImage(color: .clear).cropped(to: outputRect)
                }

                guard let scaleX = inferredScaleX,
                      let scaleY = inferredScaleY,
                      let currentStitched = stitchedImage else {
                    throw ImageUpscalerError.failedToProduceImage
                }

                let trimLeft = x == 0 ? 0 : overlap / 2
                let trimBottom = y == 0 ? 0 : overlap / 2
                let trimRight = (x + Int(sourceRect.width)) >= workingWidth ? 0 : overlap / 2
                let trimTop = (y + Int(sourceRect.height)) >= workingHeight ? 0 : overlap / 2

                let trimLeftOutput = Int(round(Double(trimLeft) * scaleX))
                let trimBottomOutput = Int(round(Double(trimBottom) * scaleY))
                let trimRightOutput = Int(round(Double(trimRight) * scaleX))
                let trimTopOutput = Int(round(Double(trimTop) * scaleY))

                let cropRect = CGRect(
                    x: trimLeftOutput,
                    y: trimBottomOutput,
                    width: max(1, tileOutput.width - trimLeftOutput - trimRightOutput),
                    height: max(1, tileOutput.height - trimBottomOutput - trimTopOutput)
                )

                let placeRect = CGRect(
                    x: CGFloat(Double(x + trimLeft) * scaleX),
                    y: CGFloat(Double(y + trimBottom) * scaleY),
                    width: cropRect.width,
                    height: cropRect.height
                )

                let trimmedTile = CIImage(cgImage: tileOutput)
                    .cropped(to: cropRect)
                    .transformed(
                        by: CGAffineTransform(
                            translationX: placeRect.origin.x - cropRect.origin.x,
                            y: placeRect.origin.y - cropRect.origin.y
                        )
                    )

                stitchedImage = trimmedTile.composited(over: currentStitched)
            }
        }

        guard let finalImage = stitchedImage,
              let scaleX = inferredScaleX,
              let scaleY = inferredScaleY,
              var output = context.createCGImage(finalImage, from: outputRect) else {
            throw ImageUpscalerError.failedToProduceImage
        }

        if workingWidth != cgImage.width || workingHeight != cgImage.height {
            let targetRect = CGRect(
                x: 0,
                y: 0,
                width: Double(cgImage.width) * scaleX,
                height: Double(cgImage.height) * scaleY
            ).integral

            guard let cropped = context.createCGImage(CIImage(cgImage: output), from: targetRect) else {
                throw ImageUpscalerError.failedToProduceImage
            }
            output = cropped
        }

        return CoreMLPassResult(image: output, scaleX: scaleX, scaleY: scaleY)
    }

    private func runCoreMLModel(_ model: VNCoreMLModel, on cgImage: CGImage) throws -> CGImage {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let results = request.results else {
            throw ImageUpscalerError.failedToProduceImage
        }

        if let pixelObservation = results.compactMap({ $0 as? VNPixelBufferObservation }).first {
            return try cgImageFromPixelBuffer(pixelObservation.pixelBuffer)
        }

        if let featureObservation = results.compactMap({ $0 as? VNCoreMLFeatureValueObservation }).first,
           let imageBuffer = featureObservation.featureValue.imageBufferValue {
            return try cgImageFromPixelBuffer(imageBuffer)
        }

        throw ImageUpscalerError.coreMLOutputNotImage
    }

    private func cgImageFromPixelBuffer(_ pixelBuffer: CVPixelBuffer) throws -> CGImage {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        guard let cgImage = context.createCGImage(image, from: rect) else {
            throw ImageUpscalerError.failedToProduceImage
        }

        return cgImage
    }

    private func loadBundledCoreMLModels() throws -> [CoreMLModelDescriptor] {
        var descriptors: [CoreMLModelDescriptor] = []

        for modelURL in coreMLModelURLs() {
            do {
                let model = try MLModel(contentsOf: modelURL)
                let inputDescriptions = model.modelDescription.inputDescriptionsByName
                let outputDescriptions = model.modelDescription.outputDescriptionsByName

                guard let inputDescription = inputDescriptions.values.first(where: { $0.type == .image }),
                      let outputDescription = outputDescriptions.values.first(where: { $0.type == .image }) else {
                    continue
                }

                let visionModel = try VNCoreMLModel(for: model)
                let modelName = modelURL.deletingPathExtension().lastPathComponent
                let tileSize = preferredTileSize(from: inputDescription.imageConstraint)
                let nominalScale = nominalScale(
                    inputConstraint: inputDescription.imageConstraint,
                    outputConstraint: outputDescription.imageConstraint,
                    modelName: modelName
                )

                descriptors.append(
                    CoreMLModelDescriptor(
                        name: modelName,
                        visionModel: visionModel,
                        preferredTileSize: tileSize,
                        nominalScale: nominalScale
                    )
                )
            } catch {
                continue
            }
        }

        return descriptors
    }

    private func preferredTileSize(from constraint: MLImageConstraint?) -> CGSize? {
        guard let constraint,
              constraint.pixelsWide > 0,
              constraint.pixelsHigh > 0 else {
            return nil
        }

        return CGSize(width: constraint.pixelsWide, height: constraint.pixelsHigh)
    }

    private func coreMLModelURLs() -> [URL] {
        let preferredModelNames = [
            "RealESRGAN",
            "RealESRGAN_x4",
            "RealESRGANx4",
            "RealESRGAN_x2",
            "RealESRGANx2",
            "BSRGAN",
            "bsrgan",
            "SwinIR_x2",
            "BSRGAN_x2",
            "SuperResolution_x2"
        ]

        var urls: [URL] = []
        for modelName in preferredModelNames {
            if let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") {
                urls.append(url)
            }
        }

        for directory in [nil, "Models"] {
            if let discovered = Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: directory) {
                for url in discovered where !urls.contains(url) {
                    urls.append(url)
                }
            }
        }

        return urls
    }

    private func nominalScale(
        inputConstraint: MLImageConstraint?,
        outputConstraint: MLImageConstraint?,
        modelName: String
    ) -> Double {
        if let inputConstraint,
           let outputConstraint,
           inputConstraint.pixelsWide > 0,
           inputConstraint.pixelsHigh > 0,
           outputConstraint.pixelsWide > 0,
           outputConstraint.pixelsHigh > 0 {
            let scaleX = Double(outputConstraint.pixelsWide) / Double(inputConstraint.pixelsWide)
            let scaleY = Double(outputConstraint.pixelsHigh) / Double(inputConstraint.pixelsHigh)
            let normalized = min(scaleX, scaleY)
            if normalized.isFinite, normalized > 0 {
                return normalized
            }
        }

        return scaleHint(from: modelName) ?? 1.0
    }

    private func scaleHint(from modelName: String) -> Double? {
        let normalized = modelName.lowercased()
        if normalized.contains("x4") || normalized.contains("4x") {
            return 4.0
        }
        if normalized.contains("realesrgan") {
            return 4.0
        }
        if normalized.contains("x3") || normalized.contains("3x") {
            return 3.0
        }
        if normalized.contains("x2") || normalized.contains("2x") {
            return 2.0
        }
        if normalized.contains("bsrgan") {
            return 1.0
        }
        return nil
    }

    private func tileOrigins(total: Int, tile: Int, step: Int) -> [Int] {
        guard total > tile else { return [0] }

        var origins: [Int] = []
        var current = 0
        while current < (total - tile) {
            origins.append(current)
            current += step
        }

        let finalOrigin = max(0, total - tile)
        if origins.last != finalOrigin {
            origins.append(finalOrigin)
        }

        return origins
    }

    #if canImport(VideoToolbox) && !targetEnvironment(simulator)
    @available(macOS 26.0, iOS 26.0, *)
    private func bestSuperResolutionFactor(for scale: Double) -> Int? {
        guard VTSuperResolutionScalerConfiguration.isSupported else { return nil }

        let supportedFactors = VTSuperResolutionScalerConfiguration.supportedScaleFactors
            .compactMap(resolveScaleFactor)
            .filter { $0 > 1 }
            .sorted(by: >)

        return supportedFactors.first { Double($0) <= scale + 0.001 }
    }

    @available(macOS 26.0, iOS 26.0, *)
    private func upscaleWithSuperResolution(_ cgImage: CGImage, scaleFactor: Int) async throws -> CGImage {
        if requiresSuperResolutionTiling(for: cgImage) {
            return try await upscaleWithSuperResolutionTiling(cgImage, scaleFactor: scaleFactor)
        }
        return try await upscaleSingleFrameWithSuperResolution(cgImage, scaleFactor: scaleFactor)
    }

    @available(macOS 26.0, iOS 26.0, *)
    private func upscaleSingleFrameWithSuperResolution(_ cgImage: CGImage, scaleFactor: Int) async throws -> CGImage {
        guard let configuration = VTSuperResolutionScalerConfiguration(
            frameWidth: cgImage.width,
            frameHeight: cgImage.height,
            scaleFactor: scaleFactor,
            inputType: .image,
            usePrecomputedFlow: false,
            qualityPrioritization: .normal,
            revision: VTSuperResolutionScalerConfiguration.defaultRevision
        ) else {
            throw ImageUpscalerError.failedToProduceImage
        }

        if configuration.configurationModelStatus != .ready {
            try await configuration.downloadConfigurationModel()
        }

        guard configuration.configurationModelStatus == .ready else {
            throw ImageUpscalerError.failedToProduceImage
        }

        let pixelFormat = try preferredPixelFormat(from: configuration.supportedPixelFormats)
        let sourceBuffer = try makePixelBuffer(
            width: cgImage.width,
            height: cgImage.height,
            pixelFormat: pixelFormat,
            baseAttributes: configuration.sourcePixelBufferAttributes
        )

        let destinationBuffer = try makePixelBuffer(
            width: cgImage.width * scaleFactor,
            height: cgImage.height * scaleFactor,
            pixelFormat: pixelFormat,
            baseAttributes: configuration.destinationPixelBufferAttributes
        )

        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        context.render(
            CIImage(cgImage: cgImage),
            to: sourceBuffer,
            bounds: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height),
            colorSpace: colorSpace
        )

        guard let sourceFrame = VTFrameProcessorFrame(buffer: sourceBuffer, presentationTimeStamp: .zero),
              let destinationFrame = VTFrameProcessorFrame(buffer: destinationBuffer, presentationTimeStamp: .zero),
              let parameters = VTSuperResolutionScalerParameters(
                sourceFrame: sourceFrame,
                previousFrame: nil,
                previousOutputFrame: nil,
                opticalFlow: nil,
                submissionMode: .random,
                destinationFrame: destinationFrame
              ) else {
            throw ImageUpscalerError.failedToCreateFrame
        }

        let processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: configuration)
        } catch {
            throw ImageUpscalerError.failedToStartProcessingSession
        }
        defer { processor.endSession() }

        let processed = try await processor.process(parameters: parameters)
        guard let outputFrame = processed.destinationFrame else {
            throw ImageUpscalerError.failedToProduceImage
        }

        return try cgImageFromPixelBuffer(outputFrame.buffer)
    }

    @available(macOS 26.0, iOS 26.0, *)
    private func upscaleWithSuperResolutionTiling(_ cgImage: CGImage, scaleFactor: Int) async throws -> CGImage {
        let source = CIImage(cgImage: cgImage)
        let outputWidth = cgImage.width * scaleFactor
        let outputHeight = cgImage.height * scaleFactor

        let outputRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        var stitched = CIImage(color: .clear).cropped(to: outputRect)

        let maxTileWidth = superResolutionMaxInputWidth
        let maxTileHeight = superResolutionMaxInputHeight
        let stepX = max(1, maxTileWidth - videoToolboxTileOverlap)
        let stepY = max(1, maxTileHeight - videoToolboxTileOverlap)

        var y = 0
        while y < cgImage.height {
            var x = 0
            while x < cgImage.width {
                let tileWidth = min(maxTileWidth, cgImage.width - x)
                let tileHeight = min(maxTileHeight, cgImage.height - y)
                let tileSourceRect = CGRect(x: x, y: y, width: tileWidth, height: tileHeight)

                guard let tileCG = context.createCGImage(source, from: tileSourceRect) else {
                    throw ImageUpscalerError.failedToProduceImage
                }

                let tileUpscaled = try await upscaleSingleFrameWithSuperResolution(tileCG, scaleFactor: scaleFactor)

                let trimLeft = x == 0 ? 0 : videoToolboxTileOverlap / 2
                let trimBottom = y == 0 ? 0 : videoToolboxTileOverlap / 2
                let trimRight = (x + tileWidth) >= cgImage.width ? 0 : videoToolboxTileOverlap / 2
                let trimTop = (y + tileHeight) >= cgImage.height ? 0 : videoToolboxTileOverlap / 2

                let trimmedSourceRect = CGRect(
                    x: trimLeft * scaleFactor,
                    y: trimBottom * scaleFactor,
                    width: max(1, tileUpscaled.width - (trimLeft + trimRight) * scaleFactor),
                    height: max(1, tileUpscaled.height - (trimBottom + trimTop) * scaleFactor)
                )

                let placedRect = CGRect(
                    x: CGFloat((x + trimLeft) * scaleFactor),
                    y: CGFloat((y + trimBottom) * scaleFactor),
                    width: trimmedSourceRect.width,
                    height: trimmedSourceRect.height
                )

                let trimmedTile = CIImage(cgImage: tileUpscaled)
                    .cropped(to: trimmedSourceRect)
                    .transformed(
                        by: CGAffineTransform(
                            translationX: placedRect.origin.x - trimmedSourceRect.origin.x,
                            y: placedRect.origin.y - trimmedSourceRect.origin.y
                        )
                    )

                stitched = trimmedTile.composited(over: stitched)
                x += stepX
            }
            y += stepY
        }

        guard let output = context.createCGImage(stitched, from: outputRect) else {
            throw ImageUpscalerError.failedToProduceImage
        }
        return output
    }

    @available(macOS 26.0, iOS 26.0, *)
    private func preferredPixelFormat(from formats: [OSType]) throws -> OSType {
        let preferred: [OSType] = [
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_32ARGB
        ]

        if let selected = preferred.first(where: { formats.contains($0) }) {
            return selected
        }
        if let fallback = formats.first {
            return fallback
        }
        throw ImageUpscalerError.unsupportedPixelFormat
    }

    @available(macOS 26.0, iOS 26.0, *)
    private func resolveScaleFactor(_ factor: Any) -> Int? {
        if let intValue = factor as? Int {
            return intValue
        }
        if let number = factor as? NSNumber {
            return number.intValue
        }
        return nil
    }

    @available(macOS 26.0, iOS 26.0, *)
    private func requiresSuperResolutionTiling(for image: CGImage) -> Bool {
        image.width > superResolutionMaxInputWidth || image.height > superResolutionMaxInputHeight
    }

    private var superResolutionMaxInputWidth: Int {
        1920
    }

    private var superResolutionMaxInputHeight: Int {
        #if os(iOS)
        1080
        #else
        1920
        #endif
    }

    @available(macOS 26.0, iOS 26.0, *)
    private func makePixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        baseAttributes: [String: Any]
    ) throws -> CVPixelBuffer {
        var attributes = baseAttributes
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = pixelFormat
        attributes[kCVPixelBufferWidthKey as String] = width
        attributes[kCVPixelBufferHeightKey as String] = height
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:] as [String: Any]
        attributes[kCVPixelBufferCGImageCompatibilityKey as String] = true
        attributes[kCVPixelBufferCGBitmapContextCompatibilityKey as String] = true

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw ImageUpscalerError.failedToCreatePixelBuffer
        }
        return pixelBuffer
    }
    #endif
}
