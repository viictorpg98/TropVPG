//
//  AboutSettingsView.swift
//  Trop
//
//  Created by 686udjie on 26/08/2026.
//

import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
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
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
    }
}
