//
//  AutoMixViews.swift
//  Trop
//

import SwiftUI
import UIKit

/// Suaviza el avance de la mezcla (empieza y acaba despacio).
private func smooth(_ t: Double) -> Double {
    let x = min(max(t, 0), 1)
    return x * x * (3 - 2 * x)
}

/// Mezcla dos colores (0 = `a`, 1 = `b`).
private func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
    var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
    var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
    UIColor(a).getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
    UIColor(b).getRed(&br, green: &bg, blue: &bb, alpha: &ba)
    let k = CGFloat(min(max(t, 0), 1))
    return Color(
        red: Double(ar + (br - ar) * k),
        green: Double(ag + (bg - ag) * k),
        blue: Double(ab + (bb - ab) * k),
        opacity: Double(aa + (ba - aa) * k)
    )
}

// MARK: - Carátula: se disuelve en su sitio

/// La carátula del reproductor grande. Fuera de una mezcla es la de siempre; durante una, la actual se disuelve
/// en su sitio hacia la siguiente, con un leve cambio de escala (como en Apple Music: sin deslizar nada).
struct MixAwareArtwork<Content: View>: View {
    let side: CGFloat
    let content: Content

    private let visuals = AutoMixVisuals.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(side: CGFloat, content: Content) {
        self.side = side
        self.content = content
    }

    var body: some View {
        if visuals.isMixing, let incoming = visuals.incomingImage {
            mixing(incoming: incoming)
        } else {
            content
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
        }
    }

    private func mixing(incoming: UIImage) -> some View {
        let e = smooth(visuals.progress)
        return ZStack {
            // La entrante, debajo y entera; la saliente, encima, se va desvaneciendo.
            Image(uiImage: incoming)
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .scaleEffect(reduceMotion ? 1 : 0.94 + 0.06 * e)

            content
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .scaleEffect(reduceMotion ? 1 : 1 + 0.05 * e)
                .opacity(1 - e)
        }
        .frame(width: side, height: side)
        .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
    }
}

// MARK: - Título: uno se va y luego entra el otro

struct MixAwareTitle: View {
    let title: String
    let artist: String
    let videoId: String?

    private let visuals = AutoMixVisuals.shared

    var body: some View {
        if visuals.isMixing, !visuals.incomingTitle.isEmpty {
            // Primero se apaga el de la saliente y despues se enciende el de la entrante: nunca se pisan.
            let p = visuals.progress
            let out = 1 - smooth((p - 0.35) / 0.15)
            let incoming = smooth((p - 0.5) / 0.15)
            ZStack(alignment: .leading) {
                block(title: title, artist: artist, videoId: videoId)
                    .opacity(out)
                block(title: visuals.incomingTitle, artist: visuals.incomingArtist, videoId: visuals.incomingVideoId)
                    .opacity(incoming)
            }
        } else {
            block(title: title, artist: artist, videoId: videoId)
        }
    }

    private func block(title: String, artist: String, videoId: String?) -> some View {
        PlayerTitleBlock(
            title: title,
            artist: artist,
            spacing: 4,
            titleFont: .title3.weight(.bold),
            titleHeight: 28,
            videoId: videoId
        )
    }
}

// MARK: - Etiqueta "AutoMix" con ondas

/// Ocupa el sitio de la linea de la letra durante una mezcla: una pastilla discreta con unas ondas que laten.
struct AutoMixPill: View {
    private let visuals = AutoMixVisuals.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 12, weight: .semibold))
            waves
            Text("AutoMix")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.white.opacity(0.18), in: Capsule())
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AutoMix")
    }

    private var waves: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let beat = visuals.pulsing ? exp(-visuals.beatPhase * 6) : 0
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { i in
                    let wave = reduceMotion ? 0.6 : 0.25 + 0.75 * abs(sin(t * 2.6 + Double(i) * 0.9))
                    Capsule()
                        .fill(.white)
                        .frame(width: 3, height: 4 + 12 * wave * (0.7 + 0.3 * beat))
                }
            }
            .frame(height: 16)
        }
    }
}

// MARK: - Resplandor de color de toda la pantalla

/// Durante una mezcla, toda la pantalla (tambien con el fondo negro) se llena del color de las dos carátulas,
/// pasando de una a otra, y late suavemente con el ritmo. Fuera de la mezcla se apaga con un fundido.
struct AutoMixGlow: View {
    private let visuals = AutoMixVisuals.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let e = smooth(visuals.progress)
        let out = visuals.outgoingColors
        let incoming = visuals.incomingColors
        let outFirst = out.first ?? Color(red: 0.15, green: 0.15, blue: 0.2)
        let outLast = out.last ?? outFirst
        let inFirst = incoming.first ?? outFirst
        let inLast = incoming.last ?? outLast
        let top = mix(outFirst, inFirst, e)
        let bottom = mix(outLast, inLast, e)
        // Entra deprisa al empezar la mezcla; el latido sube un poco la intensidad en cada pulso.
        let ramp = min(1, visuals.progress * 8)
        let beat = (visuals.pulsing && !reduceMotion) ? exp(-visuals.beatPhase * 6) : 0
        let strength = ramp * (0.78 + 0.14 * beat)

        ZStack {
            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [top.opacity(0.9), .clear], center: .top, startRadius: 0, endRadius: 560)
            // Un velo oscuro abajo mantiene legibles los controles sobre colores claros.
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .opacity(visuals.isMixing ? strength : 0)
        .animation(.easeInOut(duration: 0.9), value: visuals.isMixing)
        .allowsHitTesting(false)
    }
}

// MARK: - Fondo que se funde (estilo degradado)

/// El degradado del reproductor grande. Durante una mezcla pasa del color de una carátula al de la otra.
struct PlayerGradientBackground: View {
    let base: [Color]

    private let visuals = AutoMixVisuals.shared

    private var colors: [Color] {
        let current = [base.first ?? Color(red: 0.15, green: 0.15, blue: 0.2), base.last ?? Color(red: 0.05, green: 0.05, blue: 0.08)]
        guard visuals.isMixing, let nextFirst = visuals.incomingColors.first else { return current }
        let nextLast = visuals.incomingColors.last ?? nextFirst
        let e = smooth(visuals.progress)
        return [mix(current[0], nextFirst, e), mix(current[1], nextLast, e)]
    }

    var body: some View {
        let colors = colors
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .animation(visuals.isMixing ? nil : .easeInOut(duration: 0.8), value: colors)
            .overlay(alignment: .top) {
                // Resplandor barato (sin desenfoque): no pesa al animar ni al arrastrar.
                RadialGradient(
                    colors: [(colors.first ?? .blue).opacity(0.5), .clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 420
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
    }
}
