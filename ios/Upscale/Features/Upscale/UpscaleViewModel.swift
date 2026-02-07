//
//  UpscaleViewModel.swift
//  Upscaler
//
//  Created by Giovanni Di Nisio on 18/12/2025.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class UpscaleViewModel: ObservableObject {
    @Published var options: UpscaleOptions
    @Published var originalImage: LoadedImage?
    @Published var upscaledImage: LoadedImage?
    @Published var lastUpscaleBackendSummary: String?
    @Published var lastAIModelSummary: String?
    @Published var lastAIInferencePassCount = 0
    @Published var usedAIOnLastUpscale = false
    @Published var isProcessing = false
    @Published var importInProgress = false
    @Published var errorMessage: String?
    @Published var lastExportURL: URL?

    private let importManager = ImportManager()
    private let exporter = ExportManager()
    private let converter = ImageConverter()

    init(options: UpscaleOptions) {
        self.options = options
    }

    convenience init() {
        self.init(options: UpscaleOptions())
    }

    var originalPreview: Image? {
        guard let cgImage = originalImage?.cgImage else { return nil }
        return converter.swiftUIImage(from: cgImage)
    }

    var upscaledPreview: Image? {
        guard let cgImage = upscaledImage?.cgImage else { return nil }
        return converter.swiftUIImage(from: cgImage)
    }

    var originalSizeLabel: String {
        guard let originalImage else { return "—" }
        return "\(originalImage.cgImage.width)x\(originalImage.cgImage.height)"
    }

    var upscaledSizeLabel: String {
        guard let upscaledImage else { return "—" }
        return "\(upscaledImage.cgImage.width)x\(upscaledImage.cgImage.height)"
    }

    func setDefaultOptions(_ defaults: UpscaleOptions) {
        options = defaults
    }

    func loadFromFileURL(_ url: URL) {
        do {
            importInProgress = true
            let loaded = try importManager.importFromURL(url)
            applyImportedImage(loaded)
        } catch {
            errorMessage = error.localizedDescription
        }
        importInProgress = false
    }

    func upscale() {
        guard let baseImage = originalImage else {
            errorMessage = "Pick an image to upscale first."
            return
        }

        var clampedOptions = options
        clampedOptions.clampScale()
        options = clampedOptions
        let cgInput = baseImage.cgImage
        isProcessing = true
        lastAIModelSummary = nil
        lastAIInferencePassCount = 0
        errorMessage = nil

        Task { @MainActor in
            do {
                let result = try await performUpscale(cgInput, options: clampedOptions)
                upscaledImage = LoadedImage(data: nil, cgImage: result.image)
                lastUpscaleBackendSummary = result.backendSummary
                lastAIModelSummary = result.aiModelSummary
                lastAIInferencePassCount = result.aiInferencePassCount
                usedAIOnLastUpscale = result.usedAIEnhancement
                isProcessing = false
            } catch {
                errorMessage = error.localizedDescription
                isProcessing = false
            }
        }
    }

    func exportUpscaledImage() async throws -> URL {
        guard let upscaledImage else { throw ImageConverterError.missingImage }
        let url = try exporter.writeToTemporaryDirectory(upscaledImage.cgImage, options: options)
        lastExportURL = url
        return url
    }

    func reset() {
        originalImage = nil
        upscaledImage = nil
        lastUpscaleBackendSummary = nil
        lastAIModelSummary = nil
        lastAIInferencePassCount = 0
        usedAIOnLastUpscale = false
        errorMessage = nil
        lastExportURL = nil
    }

    private func applyImportedImage(_ loaded: LoadedImage) {
        originalImage = loaded
        upscaledImage = nil
        lastUpscaleBackendSummary = nil
        lastAIModelSummary = nil
        lastAIInferencePassCount = 0
        usedAIOnLastUpscale = false
        errorMessage = nil
        lastExportURL = nil
    }

    private func performUpscale(_ cgImage: CGImage, options: UpscaleOptions) async throws -> UpscaleComputationResult {
        let task = Task.detached(priority: .userInitiated) {
            try await ImageUpscaler().upscale(cgImage, options: options)
        }
        return try await task.value
    }
}
