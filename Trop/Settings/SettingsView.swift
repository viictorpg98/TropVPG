//
//  SettingsView.swift
//  Trop
//
//  Created by 686udjie on 16/07/2026.
//

import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Bindable private var accountState = AccountSheetState.shared

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        List {
            hero
                .listRowSeparator(.hidden)

            SettingsNavigationRow("Playback", icon: "play.circle", value: settings.audioQuality.displayName) {
                PlayerSettingsView()
            }
            SettingsNavigationRow("Appearance", icon: "paintpalette", value: settings.themeMode.displayName) {
                AppearanceSettingsView()
            }
            SettingsNavigationRow("Downloads", icon: "arrow.down.circle", value: settings.downloadQuality.displayName) {
                DownloadSettingsView()
            }
            SettingsNavigationRow("Privacy & Content", icon: "lock", value: settings.saveHistory ? "History on" : "History off") {
                ContentSettingsView()
            }
            SettingsNavigationRow("About", icon: "info.circle", value: version) {
                AboutSettingsView()
            }
        }
        .sonarSettingsList()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
        .loginSheet(state: accountState)
        .diagScreen("Ajustes")
        .task {
            await accountState.restoreSession()
            await accountState.fetchAccountInfo()
        }
    }

    /// El logo, y la cuenta (o "Invitado") con su boton.
    private var hero: some View {
        HStack(spacing: 14) {
            SonarLogoMark(size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Sonar")
                    .font(.title2.weight(.bold))
                Text(accountState.isLoggedIn ? accountState.accountName : "Guest")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if accountState.isLoggedIn {
                Button("Logout", action: accountState.signOut)
                    .buttonStyle(.bordered)
                    .tint(settings.accentColor)
            } else {
                Button("Login") { accountState.isLoginSheetPresented = true }
                    .buttonStyle(.borderedProminent)
                    .tint(settings.accentColor)
            }
        }
        .padding(.vertical, 10)
    }
}
