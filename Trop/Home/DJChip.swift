//
//  DJChip.swift
//  Trop
//
//  El DJ en el Inicio, como una pildora mas de la fila (Podcasts, Dormir...): un toque arranca tu mezcla con el DJ ya encendido (ordena la cola y mezcla las
//  canciones solo); con el DJ en marcha, un toque lo para (la musica sigue). Es una sesion: no se guarda, al abrir la app esta apagado. Se marca con el color
//  de acento mientras esta encendido.
//

import SwiftUI

struct DJChip: View {
    @Environment(SettingsStore.self) private var settings
    private let dj = DJSettings.shared
    @State private var isStarting = false

    var body: some View {
        Button(action: tap) {
            Text(verbatim: "DJ")
                .font(.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(dj.sessionActive ? settings.accentColor : Color(.systemGray5)))
                .foregroundColor(dj.sessionActive ? settings.accentOnColor : .primary)
                .opacity(isStarting ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "DJ"))
    }

    private func tap() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if dj.sessionActive {
            DJSession.shared.stop()
            PlaybackNotice.shared.show(NSLocalizedString("DJ stopped.", comment: ""))
            return
        }
        guard !isStarting else { return }
        isStarting = true
        // Se enciende ya y empieza a ordenar y mezclar en cuanto la mezcla tiene canciones.
        DJSession.shared.start()
        Task {
            let started = await SonarMix.start()
            isStarting = false
            if !started {
                DJSession.shared.stop()
                PlaybackNotice.shared.show(NSLocalizedString("Couldn't start the mix.", comment: ""))
            }
        }
    }
}
