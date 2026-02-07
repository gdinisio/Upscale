//
//  AppState.swift
//  Upscaler
//
//  Created by Giovanni Di Nisio on 18/12/2025.
//

import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var defaultOptions: UpscaleOptions {
        didSet { persist(defaultOptions) }
    }

    init() {
        defaultOptions = Self.loadDefaults()
    }

    func resetDefaults() {
        defaultOptions = UpscaleOptions()
    }

    private func persist(_ options: UpscaleOptions) {
        let defaults = UserDefaults.standard
        defaults.set(options.scale, forKey: "defaultScale")
        defaults.set(options.outputFormat.rawValue, forKey: "defaultOutputFormat")
        defaults.set(options.outputQuality, forKey: "defaultOutputQuality")
        defaults.set(options.applySharpen, forKey: "defaultApplySharpen")
        defaults.set(options.aiQualityMode.rawValue, forKey: "defaultAIQualityMode")
    }

    private static func loadDefaults() -> UpscaleOptions {
        var options = UpscaleOptions()
        let defaults = UserDefaults.standard

        let storedScale = defaults.double(forKey: "defaultScale")
        if storedScale > 0 {
            options.scale = min(max(storedScale, 1.0), 6.0)
        }

        if let rawFormat = defaults.string(forKey: "defaultOutputFormat"),
           let format = UpscaleOptions.OutputFormat(rawValue: rawFormat) {
            options.outputFormat = format
        }

        let storedQuality = defaults.double(forKey: "defaultOutputQuality")
        if storedQuality > 0 {
            options.outputQuality = min(max(storedQuality, 0.1), 1.0)
        }

        if let sharpen = defaults.object(forKey: "defaultApplySharpen") as? Bool {
            options.applySharpen = sharpen
        }

        if let rawQualityMode = defaults.string(forKey: "defaultAIQualityMode"),
           let qualityMode = UpscaleOptions.AIQualityMode(rawValue: rawQualityMode) {
            options.aiQualityMode = qualityMode
        }

        return options
    }
}
