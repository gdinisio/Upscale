//
//  SettingsView.swift
//  Upscale
//
//  Created by Giovanni Di Nisio on 18/12/2025.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            Form {
                Section("Default upscale settings") {
                    Slider(value: Binding(
                        get: { appState.defaultOptions.scale },
                        set: { appState.defaultOptions.scale = $0 }
                    ), in: 1...6, step: 0.5) {
                        Text("Scale")
                    }
                    Text("Will default to \(String(format: "%.1fx", appState.defaultOptions.scale)) on new sessions.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Output format", selection: Binding(
                        get: { appState.defaultOptions.outputFormat },
                        set: { appState.defaultOptions.outputFormat = $0 }
                    )) {
                        ForEach(UpscaleOptions.OutputFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }

                    if appState.defaultOptions.outputFormat.supportsQuality {
                        Slider(value: Binding(
                            get: { appState.defaultOptions.outputQuality },
                            set: { appState.defaultOptions.outputQuality = $0 }
                        ), in: 0.5...1.0) {
                            Text("Quality")
                        }
                        Text("Higher quality produces larger files.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Toggle("Sharpen after scaling", isOn: Binding(
                        get: { appState.defaultOptions.applySharpen },
                        set: { appState.defaultOptions.applySharpen = $0 }
                    ))

                    Picker("AI quality mode", selection: Binding(
                        get: { appState.defaultOptions.aiQualityMode },
                        set: { appState.defaultOptions.aiQualityMode = $0 }
                    )) {
                        ForEach(UpscaleOptions.AIQualityMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Text(appState.defaultOptions.aiQualityMode.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Button("Reset defaults") {
                        appState.resetDefaults()
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
