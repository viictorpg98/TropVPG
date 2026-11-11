//
//  AboutSettingsView.swift
//  Trop
//
//  Created by 686udjie on 26/08/2026.
//

import SwiftUI

struct AboutSettingsView: View {
    @Environment(\.settingsStore) private var settings

    var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(version)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                NavigationLink("Playback Report") {
                    PlaybackReportView()
                }
                SettingsToggleRow("Detailed Log", icon: "waveform.path.ecg", isOn: $settings.detailedLog)
            } footer: {
                Text("Records screens, network requests, freezes, CPU, memory and battery while you use the app, and sums it up in the report. It uses a little extra battery: turn it off when you don't need it.")
            }

            Section {
                Link(destination: URL(string: "https://github.com/SwiftyMedia/Trop")!) {
                    Text("GitHub")
                }
                Link(destination: URL(string: "https://github.com/maxrave-dev/SimpMusic")!) {
                    Text("SimpMusic (AutoMix)")
                }
                Link(destination: URL(string: "https://github.com/Clash-Projects/LastWave-Native")!) {
                    Text("LastWave (AutoMix and animated artwork)")
                }
            } header: {
                Text("Links")
            } footer: {
                Text("Based on Trop by SwiftyMedia (GPL-3.0).")
            }
        }
        .sonarSettingsList()
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
    }
}
