//
//  UpscaleApp.swift
//  Upscaler
//
//  Created by Giovanni Di Nisio on 18/12/2025.
//

import SwiftUI

@main
struct UpscalerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }
}
