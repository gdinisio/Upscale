//
//  ImageManager.swift
//  Upscaler
//
//  Created by Giovanni Di Nisio on 18/12/2025.
//

import Foundation

struct ImportManager {
    private let loader = ImageLoader()

    func importFromURL(_ url: URL) throws -> LoadedImage {
        try loader.load(from: url)
    }

    func importFromData(_ data: Data) throws -> LoadedImage {
        try loader.load(from: data)
    }
}
