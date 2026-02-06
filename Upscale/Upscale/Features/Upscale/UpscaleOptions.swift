//
//  UpscaleOption.swift
//  Upscaler
//
//  Created by Giovanni Di Nisio on 18/12/2025.
//

import Foundation
import UniformTypeIdentifiers

struct UpscaleOptions: Equatable {
    enum OutputFormat: String, CaseIterable, Identifiable {
        case png
        case jpeg
        case heif

        var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .heif: return "heic"
            }
        }

        var utType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heif: return .heic
            }
        }

        var supportsQuality: Bool {
            switch self {
            case .png: return false
            case .jpeg, .heif: return true
            }
        }

        var displayName: String {
            switch self {
            case .png: return "PNG"
            case .jpeg: return "JPEG"
            case .heif: return "HEIF"
            }
        }
    }

    enum AIQualityMode: String, CaseIterable, Identifiable {
        case fast
        case balanced
        case ultra

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .fast: return "Fast"
            case .balanced: return "Balanced"
            case .ultra: return "Ultra"
            }
        }

        var description: String {
            switch self {
            case .fast:
                return "Single AI upscaling pass for speed."
            case .balanced:
                return "AI restoration before upscaling for cleaner detail."
            case .ultra:
                return "Restoration plus multi-view AI inference for maximum quality."
            }
        }
    }

    var scale: Double = 2.0
    var outputFormat: OutputFormat = .png
    var outputQuality: Double = 0.92
    var applySharpen: Bool = true
    var aiQualityMode: AIQualityMode = .balanced

    mutating func clampScale(minimum: Double = 1.0, maximum: Double = 6.0) {
        scale = Swift.max(minimum, Swift.min(scale, maximum))
    }
}
