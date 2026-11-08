//
//  AutoMixViews.swift
//  Trop
//

import SwiftUI
import UIKit

/// Suaviza un avance de 0 a 1 (empieza y acaba despacio).
private func smooth(_ t: Double) -> Double {
    let x = min(max(t, 0), 1)
    return x * x * (3 - 2 * x)
}

/// Sube la viveza de un color (los dominantes de una carátula suelen salir apagados): mas saturacion y nunca oscuro.
private func vivid(_ color: Color) -> Color {
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return Color(hue: Double(h), saturation: Double(min(1, s * 1.2 + 0.05)), brightness: Double(min(max(b, 0.45), 0.82)))
}

/// Colores del reproductor (arriba, abajo) a partir del color de la franja inferior de la carátula: el de arriba, el
/// mismo tono ajustado para que el texto blanco se lea, y el de abajo, mas oscuro. Asi la carátula se funde con el
/// fondo sin corte. Sin ese color, se usan los dominantes.
private func palette(edge: Color?, fallback: [Color]) -> [Color] {
    guard let edge else {
        let first = fallback.first ?? Color(red: 0.15, green: 0.15, blue: 0.2)
        let last = fallback.last ?? Color(red: 0.05, green: 0.05, blue: 0.08)
        return [vivid(first), mix(vivid(last), .black, 0.45)]
    }
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(edge).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    let top = Color(hue: Double(h), saturation: Double(min(1, s * 1.1)), brightness: Double(min(max(b, 0.30), 0.80)))
    let bottom = Color(hue: Double(h), saturation: Double(min(1, s * 1.1 + 0.05)), brightness: Double(min(max(b, 0.30), 0.80) * 0.5))
    return [top, bottom]
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

/// Lo que se ha "revelado" de la cancion nueva, de 0 a 1. Como en Apple Music, el cambio visual es corto (un par de
/// segundos) y ocurre en el centro de la mezcla; antes y despues no se mueve nada.
private func reveal(_ progress: Double) -> Double {
    smooth((progress - 0.38) / 0.24)
}

// MARK: - El borde líquido

/// Mascara con un borde que sube desde abajo, difuso y ondulado como un liquido (es lo que hace Apple Music al
/// cambiar de cancion). Lo opaco es lo que se ve de la cancion nueva.
private struct LiquidReveal: View {
    /// 0 = no se ve nada; 1 = se ve todo.
    let amount: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // El frente sube de mas abajo del borde inferior a mas arriba del superior.
            let front = h * (1.45 - 1.85 * amount)
            ZStack {
                ForEach(0..<7, id: \.self) { i in
                    let x = w * Double(i) / 6
                    let wobble = sin(amount * 7 + Double(i) * 1.7) * h * 0.07
                    let lift = (i % 2 == 0 ? 1.0 : -1.0) * h * 0.05
                    Circle()
                        .frame(width: w * 0.62, height: w * 0.62)
                        .position(x: x, y: front + wobble + lift)
                }
                // Todo lo que queda por debajo del frente ya es de la nueva.
                Rectangle()
                    .frame(width: w * 1.4, height: h * 3)
                    .position(x: w / 2, y: front + h * 1.55)
            }
            .blur(radius: min(w, h) * 0.08)
        }
    }
}

// MARK: - Carátula

/// La carátula del reproductor grande. Fuera de una mezcla es la de siempre; durante una, la nueva sube desde abajo
/// con un borde liquido y enfocandose mientras la actual se desenfoca, como en Apple Music.
struct MixAwareArtwork<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    /// De lado a lado y sin esquinas: la parte de abajo se funde con el fondo.
    let fullBleed: Bool
    let content: Content

    private let visuals = AutoMixVisuals.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(width: CGFloat, height: CGFloat, fullBleed: Bool, content: Content) {
        self.width = width
        self.height = height
        self.fullBleed = fullBleed
        self.content = content
    }

    var body: some View {
        if visuals.isMixing, let incoming = visuals.incomingImage {
            mixing(incoming: incoming)
        } else {
            framed(content)
        }
    }

    /// Recorte, sombra y (si va de lado a lado) el degradado inferior que la funde con el fondo.
    @ViewBuilder
    private func framed<V: View>(_ view: V) -> some View {
        if fullBleed {
            view
                .frame(width: width, height: height)
                .clipped()
                .overlay(alignment: .top) {
                    // Un velo suave arriba para que la hora, la isla y los iconos de estado se lean sobre la carátula.
                    LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 130)
                        .allowsHitTesting(false)
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.72),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        } else {
            view
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
        }
    }

    private func mixing(incoming: UIImage) -> some View {
        let amount = reveal(visuals.progress)
        let blur: CGFloat = reduceMotion ? 0 : 14
        let stack = ZStack {
            content
                .frame(width: width, height: height)
                .blur(radius: blur * amount)
                .scaleEffect(reduceMotion ? 1 : 1 + 0.04 * amount)

            Image(uiImage: incoming)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .blur(radius: blur * (1 - amount))
                .scaleEffect(reduceMotion ? 1 : 0.96 + 0.04 * amount)
                .mask {
                    if reduceMotion {
                        Rectangle().opacity(amount)
                    } else {
                        LiquidReveal(amount: amount).frame(width: width, height: height)
                    }
                }
        }
        return framed(stack)
    }
}

// MARK: - Título

/// El titulo y el artista se cambian a la vez que la carátula: el actual sube y se desenfoca, el nuevo llega desde abajo.
struct MixAwareTitle: View {
    let title: String
    let artist: String
    let videoId: String?

    private let visuals = AutoMixVisuals.shared

    var body: some View {
        if visuals.isMixing, !visuals.incomingTitle.isEmpty {
            let r = reveal(visuals.progress)
            let out = 1 - smooth((r - 0.45) / 0.3)
            let incoming = smooth((r - 0.6) / 0.3)
            ZStack(alignment: .leading) {
                block(title: title, artist: artist, videoId: videoId)
                    .opacity(out)
                    .blur(radius: 5 * (1 - out))
                    .offset(y: -7 * (1 - out))
                block(title: visuals.incomingTitle, artist: visuals.incomingArtist, videoId: visuals.incomingVideoId)
                    .opacity(incoming)
                    .blur(radius: 5 * (1 - incoming))
                    .offset(y: 7 * (1 - incoming))
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

// MARK: - Color de toda la pantalla

/// Durante una mezcla, toda la pantalla (tambien con el fondo negro) se llena del color de la carátula actual, con
/// manchas que se mueven despacio y laten con el ritmo; en el centro de la mezcla, el color de la nueva sube desde
/// abajo con el mismo borde liquido que la carátula. Fuera de la mezcla se apaga con un fundido.
struct AutoMixGlow: View {
    private let visuals = AutoMixVisuals.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let amount = reveal(visuals.progress)
        let outPalette = palette(edge: visuals.outgoingEdgeColor, fallback: visuals.outgoingColors)
        let inPalette = visuals.incomingColors.isEmpty && visuals.incomingEdgeColor == nil
            ? outPalette
            : palette(edge: visuals.incomingEdgeColor, fallback: visuals.incomingColors)
        let outFirst = outPalette[0]
        let outLast = outPalette[1]
        let inFirst = inPalette[0]
        let inLast = inPalette[1]
        // Entra deprisa al empezar la mezcla; el latido infla un poco las manchas en cada pulso.
        let ramp = min(1, visuals.progress * 7)
        let beat = (visuals.pulsing && !reduceMotion) ? exp(-visuals.beatPhase * 6) : 0

        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !visuals.isMixing || reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let grow = 1 + 0.07 * beat
            ZStack {
                wash(top: outFirst, bottom: outLast, accent: mix(outFirst, outLast, 0.5), time: t, grow: grow)
                wash(top: inFirst, bottom: inLast, accent: mix(inFirst, inLast, 0.5), time: t + 3, grow: grow)
                    .mask {
                        if reduceMotion {
                            Rectangle().opacity(amount)
                        } else {
                            LiquidReveal(amount: amount)
                        }
                    }
                // Un velo suave abajo mantiene legibles los controles sobre colores claros.
                LinearGradient(colors: [.clear, .black.opacity(0.22)], startPoint: .center, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .opacity(visuals.isMixing ? ramp : 0)
        .animation(.easeInOut(duration: 1.6), value: visuals.isMixing)
        .allowsHitTesting(false)
    }

    /// El color de una cancion: degradado vertical con tres manchas que se mueven despacio.
    private func wash(top: Color, bottom: Color, accent: Color, time t: Double, grow: Double) -> some View {
        ZStack {
            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
            blob(top, x: 0.22 + 0.18 * sin(t * 0.55), y: 0.18 + 0.08 * cos(t * 0.40), radius: 420 * grow)
            blob(accent, x: 0.80 + 0.14 * cos(t * 0.47), y: 0.50 + 0.12 * sin(t * 0.52), radius: 380 * grow)
            blob(bottom, x: 0.35 + 0.20 * cos(t * 0.38), y: 0.88 + 0.06 * sin(t * 0.61), radius: 460 * grow)
        }
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

// MARK: - Fondo (estilo degradado)

/// El degradado del reproductor grande. Durante una mezcla pasa del color de una carátula al de la otra.
struct PlayerGradientBackground: View {
    let base: [Color]
    /// Color de la franja inferior de la carátula (para fundirla con el fondo).
    var edge: Color?
    /// Colores adaptados al borde de la carátula, con el de abajo mas oscuro (reproductor con la carátula de lado a lado).
    var tinted = false

    private let visuals = AutoMixVisuals.shared

    /// Color de arriba y de abajo del degradado.
    private func pair(colors: [Color], edge: Color?) -> [Color] {
        guard tinted else {
            return [colors.first ?? Color(red: 0.15, green: 0.15, blue: 0.2), colors.last ?? Color(red: 0.05, green: 0.05, blue: 0.08)]
        }
        return palette(edge: edge, fallback: colors)
    }

    private var colors: [Color] {
        let current = pair(colors: base, edge: edge)
        guard visuals.isMixing, !visuals.incomingColors.isEmpty else { return current }
        let next = pair(colors: visuals.incomingColors, edge: visuals.incomingEdgeColor)
        let e = reveal(visuals.progress)
        return [mix(current[0], next[0], e), mix(current[1], next[1], e)]
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
