//
//  UpscaleView.swift
//  Upscaler
//
//  Created by Giovanni Di Nisio on 18/12/2025.
//
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            UpscaleView()
                .tabItem {
                    Image(systemName: "arrow.up.backward.and.arrow.down.forward.rectangle")
                    Text("Upscale")
                }
            SettingsView()
                .tabItem {
                    Image(systemName: "gear")
                    Text("Settings")
                }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
