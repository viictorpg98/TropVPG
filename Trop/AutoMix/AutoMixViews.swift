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

/// Sube la viveza de un color (los dominantes de una carátula suelen salir apagados): mas saturacion y nunca oscuro.
private func vivid(_ color: Color) -> Color {
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return Color(hue: Double(h), saturation: Double(min(1, s * 1.2 + 0.05)), brightness: Double(max(b, 0.55)))
}

/// El cruce de carátulas y colores se concentra en la parte central de la mezcla (de 25 % a 75 %), como en Apple
/// Music: antes y despues se ve una sola.
private func dissolve(_ progress: Double) -> Double {
    smooth((progress - 0.25) / 0.5)
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
        let e = dissolve(visuals.progress)
        // Disolvencia con enfoque: la que sale se desenfoca y se desvanece mientras la que entra se enfoca. Asi no se
        // ven las dos nitidas a la vez (la doble exposicion de dos portadas cargadas queda fea).
        let blur: CGFloat = reduceMotion ? 0 : 16
        return ZStack {
            Image(uiImage: incoming)
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .blur(radius: blur * (1 - e))
                .scaleEffect(reduceMotion ? 1 : 0.95 + 0.05 * e)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            content
                .frame(width: side, height: side)
                .blur(radius: blur * e)
                .scaleEffect(reduceMotion ? 1 : 1 + 0.05 * e)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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
                    .blur(radius: 6 * (1 - out))
                block(title: visuals.incomingTitle, artist: visuals.incomingArtist, videoId: visuals.incomingVideoId)
                    .opacity(incoming)
                    .blur(radius: 6 * (1 - incoming))
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

/// Durante una mezcla, toda la pantalla (tambien con el fondo negro) se llena del color de las dos carátulas, pasando
/// de una a otra, con manchas de color que se mueven despacio y laten con el ritmo. Fuera de la mezcla se apaga con
/// un fundido.
struct AutoMixGlow: View {
    private let visuals = AutoMixVisuals.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let e = dissolve(visuals.progress)
        let out = visuals.outgoingColors
        let incoming = visuals.incomingColors
        let outFirst = vivid(out.first ?? Color(red: 0.2, green: 0.2, blue: 0.3))
        let outLast = vivid(out.last ?? out.first ?? Color(red: 0.2, green: 0.2, blue: 0.3))
        let inFirst = incoming.first.map(vivid) ?? outFirst
        let inLast = incoming.last.map(vivid) ?? outLast
        let top = mix(outFirst, inFirst, e)
        let bottom = mix(outLast, inLast, e)
        let accent = mix(outLast, inFirst, e)
        // Entra deprisa al empezar la mezcla; el latido infla un poco las manchas en cada pulso.
        let ramp = min(1, visuals.progress * 7)
        let beat = (visuals.pulsing && !reduceMotion) ? exp(-visuals.beatPhase * 6) : 0

        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !visuals.isMixing || reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let grow = 1 + 0.07 * beat
            ZStack {
                LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
                blob(top, x: 0.22 + 0.18 * sin(t * 0.55), y: 0.18 + 0.08 * cos(t * 0.40), radius: 420 * grow)
                blob(accent, x: 0.80 + 0.14 * cos(t * 0.47), y: 0.50 + 0.12 * sin(t * 0.52), radius: 380 * grow)
                blob(bottom, x: 0.35 + 0.20 * cos(t * 0.38), y: 0.88 + 0.06 * sin(t * 0.61), radius: 460 * grow)
                // Un velo suave abajo mantiene legibles los controles sobre colores claros.
                LinearGradient(colors: [.clear, .black.opacity(0.22)], startPoint: .center, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .opacity(visuals.isMixing ? ramp : 0)
        .animation(.easeInOut(duration: 1.2), value: visuals.isMixing)
        .allowsHitTesting(false)
    }

    private func blob(_ color: Color, x: Double, y: Double, radius: Double) -> some View {
        RadialGradient(
            colors: [color.opacity(0.85), color.opacity(0)],
            center: UnitPoint(x: x, y: y),
            startRadius: 0,
            endRadius: radius
        )
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
        let e = dissolve(visuals.progress)
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
