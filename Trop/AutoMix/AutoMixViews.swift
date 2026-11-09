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

/// Lo mismo, para otras vistas (la barra de progreso entra a la vez que la carátula).
func autoMixReveal(_ progress: Double) -> Double { reveal(progress) }

/// Los dos colores (arriba y abajo) de la cancion que suena, como los usa el reproductor grande; durante una mezcla de
/// AutoMix pasan a los de la entrante. Los usa tambien el mini reproductor, para ir a juego.
@MainActor
func playerPaletteNow(base: [Color], edge: Color?) -> [Color] {
    let visuals = AutoMixVisuals.shared
    let current = palette(edge: edge, fallback: base)
    guard visuals.isMixing, !visuals.incomingColors.isEmpty else { return current }
    let next = palette(edge: visuals.incomingEdgeColor, fallback: visuals.incomingColors)
    let amount = reveal(visuals.progress)
    return [mix(current[0], next[0], amount), mix(current[1], next[1], amount)]
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
    /// Alto de la carátula (la parte que se ve entera, por debajo de la isla dinamica).
    let height: CGFloat
    /// Lo que sube por encima de la carátula hasta el borde de la pantalla (isla dinamica y barra de estado): se rellena
    /// con la propia carátula desenfocada, asi ninguna parte de ella queda cortada ni tapada.
    let topExtension: CGFloat
    /// De lado a lado y sin esquinas: la parte de abajo se funde con el fondo.
    let fullBleed: Bool
    let content: Content

    private let visuals = AutoMixVisuals.shared
    private let np = NowPlaying.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(width: CGFloat, height: CGFloat, topExtension: CGFloat = 0, fullBleed: Bool, content: Content) {
        self.width = width
        self.height = height
        self.topExtension = topExtension
        self.fullBleed = fullBleed
        self.content = content
    }

    var body: some View {
        if visuals.isMixing, let incoming = visuals.incomingImage {
            mixing(incoming: incoming)
        } else {
            framed(content, outgoing: np.thumbnailUIImage, incoming: nil, amount: 0)
        }
    }

    /// Cuanto se solapan la carátula y el relleno de arriba para que no se note la union.
    private var overlap: CGFloat { topExtension > 0 ? 56 : 0 }

    /// Recorte, sombra y (si va de lado a lado) los degradados que la funden con el fondo por abajo y con el relleno por arriba.
    @ViewBuilder
    private func framed<V: View>(_ view: V, outgoing: UIImage?, incoming: UIImage?, amount: Double) -> some View {
        if fullBleed {
            ZStack(alignment: .top) {
                if topExtension > 0 {
                    backdrop(outgoing: outgoing, incoming: incoming, amount: amount)
                        .frame(width: width, height: topExtension + overlap)
                        .clipped()
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: topExtension / (topExtension + overlap)),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                view
                    .frame(width: width, height: height)
                    .clipped()
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: topExtension > 0 ? .clear : .black, location: 0),
                                .init(color: .black, location: topExtension > 0 ? min(overlap / height, 0.3) : 0),
                                .init(color: .black, location: 0.72),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .offset(y: topExtension)
            }
            .frame(width: width, height: height + topExtension, alignment: .top)
            .overlay(alignment: .top) {
                // Un velo suave arriba para que la hora, la isla y los iconos de estado se lean sobre la carátula.
                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 130)
                    .allowsHitTesting(false)
            }
        } else {
            view
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
        }
    }

    /// La carátula (o las dos, durante una mezcla) muy desenfocada, para rellenar la franja de arriba.
    private func backdrop(outgoing: UIImage?, incoming: UIImage?, amount: Double) -> some View {
        ZStack {
            if let outgoing {
                Image(uiImage: outgoing).resizable().scaledToFill().opacity(incoming == nil ? 1 : 1 - amount)
            }
            if let incoming {
                Image(uiImage: incoming).resizable().scaledToFill().opacity(amount)
            }
            Color.black.opacity(0.18)
        }
        .scaleEffect(1.2)
        .blur(radius: 30)
    }

    private func mixing(incoming: UIImage) -> some View {
        let amount = reveal(visuals.progress)
        let blur: CGFloat = reduceMotion ? 0 : 14
        let stack = ZStack {
            content
                .frame(width: width, height: height)
                .blur(radius: blur * amount)
                .scaleEffect(reduceMotion ? 1 : 1 + 0.04 * amount)

            ZStack {
                Image(uiImage: incoming)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                if let videoURL = visuals.incomingVideoURL {
                    IncomingArtworkVideo(url: videoURL)
                        .frame(width: width, height: height)
                }
            }
                .frame(width: width, height: height)
                .clipped()
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
        return framed(stack, outgoing: visuals.outgoingImage ?? np.thumbnailUIImage, incoming: incoming, amount: amount)
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
        content.animation(.smooth(duration: 0.45), value: videoId)
    }

    @ViewBuilder
    private var content: some View {
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
            // Al cambiar de cancion, el titulo nuevo entra desenfocandose en lugar de saltar.
            block(title: title, artist: artist, videoId: videoId)
                .id(videoId ?? title)
                .transition(.blurReplace)
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
    /// Mientras se prepara una mezcla pedida a mano: el mismo aviso, con otro texto.
    var preparing = false
    private let visuals = AutoMixVisuals.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 12, weight: .semibold))
            AutoMixWaves()
            Text(LocalizedStringKey(preparing ? "Preparing the mix…" : "AutoMix"))
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AutoMix")
    }
}

/// Las cinco barras que suben y bajan (y laten con el pulso de la mezcla): el "se esta mezclando" del reproductor.
struct AutoMixWaves: View {
    var color: Color = .white
    private let visuals = AutoMixVisuals.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let beat = visuals.pulsing ? exp(-visuals.beatPhase * 6) : 0
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { i in
                    let wave = reduceMotion ? 0.6 : 0.25 + 0.75 * abs(sin(t * 2.6 + Double(i) * 0.9))
                    Capsule()
                        .fill(color)
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let colors = colors
        Group {
            if SettingsStore.shared.liveBackground {
                // Fondo vivo: una malla de colores que se mueve despacio y late con el pulso durante una mezcla.
                LiveMeshBackground(
                    top: colors[0], bottom: colors[1],
                    paused: reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled
                )
            } else {
                LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            }
        }
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

/// Malla de 3x3 colores sacados de la carátula, con los puntos interiores moviendose despacio. El borde de arriba y el de
/// abajo conservan el color de la carátula, asi se sigue fundiendo con ella sin corte.
private struct LiveMeshBackground: View {
    let top: Color
    let bottom: Color
    let paused: Bool

    private let visuals = AutoMixVisuals.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: paused)) { timeline in
            let t = paused ? 0 : timeline.date.timeIntervalSinceReferenceDate
            // El centro se mueve un poco mas con cada pulso durante una mezcla.
            let beat = (visuals.pulsing && !paused) ? exp(-visuals.beatPhase * 6) : 0
            MeshGradient(width: 3, height: 3, points: points(t, beat: beat), colors: meshColors, smoothsColors: true)
        }
    }

    private func points(_ t: Double, beat: Double) -> [SIMD2<Float>] {
        func drift(_ speed: Double, _ phase: Double, _ amplitude: Double) -> Float {
            Float(sin(t * speed + phase) * amplitude)
        }
        let centre = 0.10 + 0.05 * beat
        return [
            SIMD2(0, 0), SIMD2(0.5 + drift(0.31, 0, 0.08), 0), SIMD2(1, 0),
            SIMD2(0, 0.5 + drift(0.23, 2, 0.08)), SIMD2(0.5 + drift(0.37, 3, centre), 0.5 + drift(0.29, 4, centre)),
            SIMD2(1, 0.5 + drift(0.33, 6, 0.08)),
            SIMD2(0, 1), SIMD2(0.5 + drift(0.25, 7, 0.08), 1), SIMD2(1, 1)
        ]
    }

    private var meshColors: [Color] {
        let accent = shifted(top)
        let middle = mix(top, bottom, 0.5)
        return [
            top, mix(top, accent, 0.45), top,
            mix(top, bottom, 0.3), mix(accent, middle, 0.5), mix(top, bottom, 0.4),
            bottom, mix(bottom, accent, 0.25), bottom
        ]
    }

    /// El mismo color con el tono un poco corrido y mas vivo, para que la malla tenga matices.
    private func shifted(_ color: Color) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(
            hue: Double((h + 0.07).truncatingRemainder(dividingBy: 1)),
            saturation: Double(min(1, s * 1.15 + 0.05)),
            brightness: Double(min(1, b * 1.2 + 0.04))
        )
    }
}
