//
//  ExportManager.swift
//  Upscaler
//
//  Created by Giovanni Di Nisio on 18/12/2025.
//

import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ExportManager {
    private let converter = ImageConverter()
    private let fileManager = FileManager.default

    func writeToTemporaryDirectory(_ image: CGImage, options: UpscaleOptions) throws -> URL {
        let data = try converter.data(from: image, format: options.outputFormat, quality: options.outputQuality)
        let url = temporaryURL(for: options.outputFormat)
        try data.write(to: url, options: .atomic)
        return url
    }

    func temporaryURL(for format: UpscaleOptions.OutputFormat) -> URL {
        let filename = "Upscaled-\(Int(Date().timeIntervalSince1970)).\(format.fileExtension)"
        return fileManager.temporaryDirectory.appendingPathComponent(filename)
    }

    #if canImport(UIKit)
    func saveToPhotoLibrary(_ image: CGImage, completion: ((Error?) -> Void)? = nil) {
        let platformImage = converter.platformImage(from: image)
        UIImageWriteToSavedPhotosAlbum(platformImage, nil, nil, nil)
        completion?(nil)
    }
    #elseif canImport(AppKit)
    func saveToPicturesFolder(_ image: CGImage, options: UpscaleOptions) throws -> URL {
        let picturesURL = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first ?? fileManager.homeDirectoryForCurrentUser
        let url = picturesURL.appendingPathComponent("Upscaled-\(Int(Date().timeIntervalSince1970)).\(options.outputFormat.fileExtension)")
        let data = try converter.data(from: image, format: options.outputFormat, quality: options.outputQuality)
        try data.write(to: url, options: .atomic)
        return url
    }
    #endif
}
