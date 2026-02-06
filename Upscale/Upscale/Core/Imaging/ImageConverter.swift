//
//  ImageConverter.swift
//  Upscaler
//
//  Created by Giovanni Di Nisio on 18/12/2025.
//

import SwiftUI
import UniformTypeIdentifiers
import ImageIO

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum ImageConverterError: LocalizedError {
    case failedToCreateDestination
    case failedToFinalize
    case missingImage

    var errorDescription: String? {
        switch self {
        case .failedToCreateDestination:
            return "Unable to prepare an image writer for the requested format."
        case .failedToFinalize:
            return "Saving the image failed. Please try exporting again."
        case .missingImage:
            return "No compatible image was found to export."
        }
    }
}

struct ImageConverter {
    func swiftUIImage(from cgImage: CGImage) -> Image {
        Image(decorative: cgImage, scale: 1.0, orientation: .up)
    }

    func platformImage(from cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: .init(width: cgImage.width, height: cgImage.height))
        #endif
    }

    func cgImage(from platformImage: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        platformImage.cgImage
        #else
        platformImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    func data(from cgImage: CGImage, format: UpscaleOptions.OutputFormat, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            throw ImageConverterError.failedToCreateDestination
        }

        var options: [CFString: Any] = [:]
        if format.supportsQuality {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }

        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageConverterError.failedToFinalize
        }

        return data as Data
    }
}
