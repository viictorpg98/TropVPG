//
//  ContentSettingsView.swift
//  Trop
//
//  Created by 686udjie on 20/08/2026.
//

import SwiftUI

struct ContentSettingsView: View {
    @Environment(\.settingsStore) private var settings

    private static let countries = ["US", "GB", "CA", "AU", "FR", "DE", "ES", "IT", "PT", "JP", "KR", "MX", "BR", "IN"]

    var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                SettingsToggleRow("Hide Explicit Content", icon: "eye.slash", isOn: $settings.hideExplicit)
                Picker(selection: $settings.contentCountry) {
                    ForEach(Self.countries, id: \.self) { code in
                        Text(countryName(for: code)).tag(code)
                    }
                } label: {
                    SettingsLabel(title: "Country", icon: "globe")
                }
                .tint(settings.accentColor)
            } header: {
                Text("Content")
            } footer: {
                Text("The country controls the region used for YouTube Music requests.")
            }

            Section {
                SettingsNavigationRow(
                    "Hidden Artists", icon: "eye.slash",
                    value: HiddenArtists.shared.all.isEmpty ? nil : String(HiddenArtists.shared.all.count)
                ) {
                    HiddenArtistsView()
                }
            }

            Section {
                SettingsToggleRow("Save History", icon: "clock.arrow.circlepath", isOn: $settings.saveHistory)
                SettingsToggleRow("Sync Library", icon: "arrow.triangle.2.circlepath", isOn: $settings.syncLibrary)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Save History keeps your searches and plays on this device; off, nothing is recorded. Sync Library keeps your artists, playlists, albums, podcasts and liked songs up to date with your YouTube Music account.")
            }
        }
        .sonarSettingsList()
        .navigationTitle("Privacy & Content")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
    }

    private func countryName(for code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }
}
