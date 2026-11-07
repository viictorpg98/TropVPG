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

    var body: some View {
        List {
            accountSection

            Section {
                SettingsNavigationRow("Appearance", icon: "paintpalette") {
                    AppearanceSettingsView()
                }
            } header: {
                Text("Appearance")
            }

            Section {
                SettingsNavigationRow("Player", icon: "play.circle") {
                    PlayerSettingsView()
                }
                SettingsNavigationRow("Downloads", icon: "arrow.down.circle") {
                    DownloadSettingsView()
                }
            } header: {
                Text("Playback & Offline")
            }

            Section {
                SettingsNavigationRow("Content", icon: "globe") {
                    ContentSettingsView()
                }
            } header: {
                Text("Content")
            }

            Section {
                SettingsNavigationRow("Integrations", icon: "puzzlepiece.extension") {
                    IntegrationsSettingsView()
                }
            } header: {
                Text("Integrations")
            }

            Section {
                SettingsNavigationRow("About", icon: "info.circle") {
                    AboutSettingsView()
                }
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
        .loginSheet(state: accountState)
        .task {
            await accountState.restoreSession()
            await accountState.fetchAccountInfo()
        }
    }

    private var accountSection: some View {
        Section {
            HStack(spacing: 14) {
                AccountButtonView(
                    isLoggedIn: accountState.isLoggedIn,
                    accountImageUrl: accountState.accountImageUrl,
                    onTap: {}
                )
                .scaleEffect(1.7)
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(accountState.isLoggedIn ? accountState.accountName : "Guest")
                        .font(.headline)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}
