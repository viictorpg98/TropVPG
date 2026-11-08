//
//  OfflineBanner.swift
//  Trop
//

import SwiftUI

/// Aviso de "sin conexion" con un boton directo a las descargas. Va encima del mini reproductor.
struct OfflineBanner: View {
    @Environment(SettingsStore.self) private var settings
    @State private var network = NetworkMonitor.shared

    private var isVisible: Bool { !network.isOnline && !network.bannerDismissed }

    var body: some View {
        Group {
            if isVisible {
                HStack(spacing: 10) {
                    Image(systemName: "wifi.slash")
                        .font(.headline)
                        .foregroundStyle(settings.accentColor)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Offline")
                            .font(.subheadline.weight(.semibold))
                        Text("Only your downloaded music is available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    Button(action: openDownloads) {
                        Text("Go to Downloads")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(settings.accentColor))
                    }
                    .buttonStyle(PressableButtonStyle())

                    Button {
                        network.bannerDismissed = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isVisible)
    }

    private func openDownloads() {
        network.bannerDismissed = true
        AppRouter.shared.openDownloads()
    }
}
