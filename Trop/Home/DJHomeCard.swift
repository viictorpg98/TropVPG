//
//  DJHomeCard.swift
//  Trop
//
//  La tarjeta del DJ en el Inicio (como la de Spotify): un toque arranca tu mezcla con el DJ ya encendido; con el DJ en marcha, un
//  toque lo para (la musica sigue). Es una sesion: no se guarda, al abrir la app el DJ esta apagado.
//

import SwiftUI

struct DJHomeCard: View {
    private let dj = DJSettings.shared
    @State private var isStarting = false

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(LinearGradient(
                        colors: [Color.purple, Color.pink], startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    if isStarting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: dj.sessionActive ? "waveform" : "mic.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .symbolEffect(.variableColor.iterative, isActive: dj.speaking)
                    }
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text("DJ")
                        .font(.headline)
                    Text(LocalizedStringKey(
                        dj.sessionActive ? "The DJ is on. Tap to stop it." : "Your mix, with a host that introduces the songs."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                Image(systemName: dj.sessionActive ? "stop.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityLabel(Text("DJ"))
    }

    private func tap() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if dj.sessionActive {
            DJHost.shared.stop()
            PlaybackNotice.shared.show(NSLocalizedString("DJ stopped.", comment: ""))
            return
        }
        guard !isStarting else { return }
        isStarting = true
        // Se enciende ya (sin presentar lo que sonara antes) y habla al empezar la primera de la mezcla.
        DJHost.shared.start(introduceCurrent: false)
        Task {
            let started = await SonarMix.start()
            isStarting = false
            if !started {
                DJHost.shared.stop()
                PlaybackNotice.shared.show(NSLocalizedString("Couldn't start the mix.", comment: ""))
            }
        }
    }
}
