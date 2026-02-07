//
//  ImageLoader.swift
//  Upscaler
//
//  Created by Giovanni Di Nisio on 18/12/2025.
//

import Foundation
import ImageIO

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

struct LoadedImage {
    let data: Data?
    let cgImage: CGImage

    var size: CGSize {
        CGSize(width: cgImage.width, height: cgImage.height)
    }
}

enum ImageLoaderError: LocalizedError {
    case missingImageData
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .missingImageData:
            return "Unable to read any image data from the selected source."
        case .invalidImage:
            return "The selected file is not a supported image."
        }
    }
}

struct ImageLoader {
    func load(from url: URL) throws -> LoadedImage {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if FileManager.default.isUbiquitousItem(at: url) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }

        var coordinatedError: NSError?
        var coordinatedData: Data?

        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatedError) { readingURL in
            coordinatedData = try? Data(contentsOf: readingURL)
        }

        if let coordinatedError {
            throw coordinatedError
        }
        guard let coordinatedData else {
            throw ImageLoaderError.missingImageData
        }

        return try load(from: coordinatedData)
    }

    func load(from data: Data) throws -> LoadedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageLoaderError.invalidImage
        }

        return LoadedImage(data: data, cgImage: cgImage)
    }

}
