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

// MARK: - 1 y 5: carátulas que se cruzan y latido al ritmo

/// La carátula del reproductor grande. Fuera de una mezcla es la de siempre; durante una, la actual se desliza
/// y se encoge hacia un lado mientras la siguiente sube desde atrás, y todo late al compas.
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
            plain
        }
    }

    private var plain: some View {
        content
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
    }

    private func mixing(incoming: UIImage) -> some View {
        let e = smooth(visuals.progress)
        // Latido: un golpe en cada pulso que se desvanece hasta el siguiente.
        let beat = (visuals.pulsing && !reduceMotion) ? exp(-visuals.beatPhase * 7) : 0
        let slide = reduceMotion ? 0 : side * 0.22
        return ZStack {
            Image(uiImage: incoming)
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
                .scaleEffect(reduceMotion ? 1 : 0.74 + 0.26 * e)
                .offset(x: (1 - e) * slide, y: reduceMotion ? 0 : (1 - e) * side * 0.03)
                .opacity(reduceMotion ? e : 0.35 + 0.65 * e)
                .zIndex(e > 0.5 ? 1 : 0)

            content
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
                .scaleEffect(reduceMotion ? 1 : 1 - 0.26 * e)
                .offset(x: -e * slide)
                .opacity(1 - e * e)
        }
        .frame(width: side, height: side)
        .scaleEffect(1 + 0.035 * beat)
    }
}

// MARK: - Título que cambia a mitad de la mezcla

struct MixAwareTitle: View {
    let title: String
    let artist: String
    let videoId: String?

    private let visuals = AutoMixVisuals.shared

    var body: some View {
        if visuals.isMixing, !visuals.incomingTitle.isEmpty {
            // Se cruzan hacia la mitad de la mezcla, cuando las dos suenan igual de fuerte.
            let k = smooth((visuals.progress - 0.35) / 0.3)
            ZStack(alignment: .leading) {
                block(title: title, artist: artist, videoId: videoId)
                    .opacity(1 - k)
                block(title: visuals.incomingTitle, artist: visuals.incomingArtist, videoId: visuals.incomingVideoId)
                    .opacity(k)
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

// MARK: - 2: crossfader de DJ

/// Sustituye a la linea de la letra durante una mezcla: un mando que va de la canción que sale a la que entra.
struct AutoMixCrossfader: View {
    private let visuals = AutoMixVisuals.shared

    var body: some View {
        let progress = min(max(visuals.progress, 0), 1)
        let from = visuals.outgoingImage
        let colors = [
            NowPlaying.shared.dominantColors.first ?? .white,
            visuals.incomingColors.first ?? .white
        ]
        HStack(spacing: 10) {
            thumbnail(from)
                .opacity(1 - 0.5 * progress)
            GeometryReader { geo in
                let knob: CGFloat = 22
                let travel = max(geo.size.width - knob, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16)).frame(height: 6)
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: knob / 2 + travel * progress, height: 6)
                    Circle()
                        .fill(.white)
                        .frame(width: knob, height: knob)
                        .overlay {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.black.opacity(0.75))
                        }
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                        .offset(x: travel * progress)
                }
                .frame(height: geo.size.height)
            }
            .frame(height: 26)
            thumbnail(visuals.incomingImage)
                .opacity(0.5 + 0.5 * progress)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AutoMix")
    }

    @ViewBuilder
    private func thumbnail(_ image: UIImage?) -> some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.15)
            }
        }
        .frame(width: 26, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - 3: fondo que se funde

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
