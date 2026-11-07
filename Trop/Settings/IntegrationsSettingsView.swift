//
//  IntegrationsSettingsView.swift
//  Trop
//

import SwiftUI

struct IntegrationsSettingsView: View {
    var body: some View {
        List {
            Section {
                SettingsNavigationRow("SponsorBlock", icon: "forward.end") {
                    SponsorBlockSettingsView()
                }
            }
        }
        .navigationTitle("Integrations")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
    }
}
