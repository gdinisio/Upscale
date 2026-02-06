//
//  UpscaleView.swift
//  Upscale
//
//  Created by Giovanni Di Nisio on 18/12/2025.
//

import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct UpscaleView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel: UpscaleViewModel
    @State private var showingFileImporter = false
    @State private var exportedURL: URL?

    @MainActor
    init() {
        _viewModel = StateObject(wrappedValue: UpscaleViewModel())
    }

    var body: some View {
            ZStack(alignment: .top) {
                Theme.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        importCard
                        previewCards
                        optionsCard
                        actionsCard
                        statusCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
        }
        .onAppear {
            viewModel.setDefaultOptions(appState.defaultOptions)
        }
        .onChange(of: appState.defaultOptions) { _, newValue in
            viewModel.setDefaultOptions(newValue)
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                viewModel.loadFromFileURL(url)
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
}

private extension UpscaleView {
    
    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Upscale")
                .font(.largeTitle)
                .fontWeight(.bold)
                .fontDesign(.rounded)
            Text("Import a file, run neural super-resolution, and export your high-res result.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var importCard: some View {
        sectionCard(title: "Import") {
            Button {
                showingFileImporter = true
            } label: {
                Label("Open Image File", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)

            if viewModel.importInProgress {
                ProgressView("Loading image…")
            }
        }
    }

    var previewCards: some View {
        sectionCard(title: "Preview") {
            HStack(alignment: .top, spacing: 12) {
                previewCard(title: "Original", image: viewModel.originalPreview, sizeLabel: viewModel.originalSizeLabel, isProcessing: false)
                previewCard(title: "Upscaled", image: viewModel.upscaledPreview, sizeLabel: viewModel.upscaledSizeLabel, isProcessing: viewModel.isProcessing)
            }
        }
    }

    func previewCard(title: String, image: Image?, sizeLabel: String, isProcessing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.bold())
                Spacer()
                Text(sizeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.05))

                if let image {
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(10)
                } else if isProcessing {
                    ProgressView()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "square.dashed")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("No image")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 200)
        }
    }

    var optionsCard: some View {
        sectionCard(title: "Options") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Scale")
                    Spacer()
                    Text("\(String(format: "%.1f", viewModel.options.scale))x")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $viewModel.options.scale, in: 1...6, step: 0.25)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("AI quality")
                    Spacer()
                    Text(viewModel.options.aiQualityMode.displayName)
                        .foregroundStyle(.secondary)
                }

                Picker("AI quality", selection: $viewModel.options.aiQualityMode) {
                    ForEach(UpscaleOptions.AIQualityMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(viewModel.options.aiQualityMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(selectedAIPipelineLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Picker("Output format", selection: $viewModel.options.outputFormat) {
                ForEach(UpscaleOptions.OutputFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.options.outputFormat.supportsQuality {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Quality")
                        Spacer()
                        Text(String(format: "%.0f%%", viewModel.options.outputQuality * 100))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $viewModel.options.outputQuality, in: 0.5...1.0)
                }
            }

            Toggle("Sharpen after scaling", isOn: $viewModel.options.applySharpen)
        }
    }

    var actionsCard: some View {
        sectionCard(title: "Actions") {
            Button {
                viewModel.upscale()
            } label: {
                Label(viewModel.isProcessing ? "Processing…" : "Upscale", systemImage: "arrow.up.right.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.glassProminent)
            .disabled(viewModel.originalImage == nil || viewModel.isProcessing)

            Button {
                exportedURL = nil
                Task {
                    do {
                        exportedURL = try await viewModel.exportUpscaledImage()
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                    }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.glass)
            .disabled(viewModel.upscaledImage == nil)

            if let exportedURL {
                ShareLink(item: exportedURL) {
                    Label("Share last export", systemImage: "square.and.arrow.up.on.square")
                }
            }
        }
    }

    var statusCard: some View {
        Group {
            if let error = viewModel.errorMessage {
                sectionCard {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            } else if viewModel.isProcessing {
                sectionCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Running AI upscaling…", systemImage: "cpu")
                            .font(.footnote)
                        Text("Mode: \(viewModel.options.aiQualityMode.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(selectedAIPipelineLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if viewModel.upscaledImage != nil {
                sectionCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Upscaled image ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)

                        if viewModel.usedAIOnLastUpscale {
                            Label("Neural super-resolution was applied", systemImage: "brain.head.profile")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }

                        if let modelSummary = viewModel.lastAIModelSummary {
                            Text(modelSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        if viewModel.lastAIInferencePassCount > 0 {
                            Text("Neural inference passes: \(viewModel.lastAIInferencePassCount)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let summary = viewModel.lastUpscaleBackendSummary {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        if !viewModel.usedAIOnLastUpscale {
                            Label("AI model was not used for this run.", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    var selectedAIPipelineLabel: String {
        switch viewModel.options.aiQualityMode {
        case .fast:
            return "Pipeline: RealESRGAN upscale (single-view inference)"
        case .balanced:
            return "Pipeline: BSRGAN restoration -> RealESRGAN upscale (multi-view inference)"
        case .ultra:
            return "Pipeline: BSRGAN restoration -> RealESRGAN upscale (deep multi-view ensemble)"
        }
    }

    @ViewBuilder
    func sectionCard<Content: View>(title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .kerning(0.5)
            }
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        )
    }
}
