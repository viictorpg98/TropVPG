//
//  RadioScreenView.swift
//  Trop
//
//  La pestaña "Radio" (entre Inicio y Biblioteca) como una CABINA DE RADIO PIRATA: el cartel "en el aire" en neon, el dial con la frecuencia (106.6) como protagonista, los
//  dos locutores en ventanas de estudio (el que habla se enciende con su medidor), los subtitulos en un bocadillo que señala a quien habla, el programa (ahora / luego),
//  tus ultimas peticiones y, fijos encima del mini reproductor, los botones para pedir musica por voz o parar la radio. El color de fondo sigue la portada de lo que suena.
//  El gasto del dia es un indicador de combustible pequeño; los ajustes estan detras del boton de arriba a la derecha.
//  Las animaciones solo corren con la pestaña a la vista y sin "Reducir movimiento"; el dial y los medidores se mueven solo mientras alguien habla.
//

import SwiftUI

/// Las ultimas peticiones a la radio (solo se guardan en el movil; no dependen de "La radio recuerda").
enum RadioRecents {
    private static let key = "radio.recents.v1"
    private static let limit = 8

    static var all: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var list = all.filter { $0.caseInsensitiveCompare(clean) != .orderedSame }
        list.insert(String(clean.prefix(60)), at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: key)
    }
}

/// Los colores de la cabina: berenjena de fondo, crema para el papel y las placas, ambar para lo que esta vivo y un unico rojo (el cartel "en el aire").
enum RadioPalette {
    static let base = Color(red: 0.110, green: 0.071, blue: 0.125)
    static let line = Color(red: 0.227, green: 0.153, blue: 0.251)
    static let cream = Color(red: 0.953, green: 0.890, blue: 0.765)
    static let ink = Color(red: 0.165, green: 0.106, blue: 0.180)
    static let inkSoft = Color(red: 0.290, green: 0.231, blue: 0.310)
    static let amber = Color(red: 1.000, green: 0.702, blue: 0.278)
    static let neon = Color(red: 1.000, green: 0.455, blue: 0.408)
    static let mauve = Color(red: 0.718, green: 0.608, blue: 0.725)
    static let rec = Color(red: 0.878, green: 0.224, blue: 0.169)
    static let label = Color(red: 0.612, green: 0.231, blue: 0.165)
}

struct RadioScreenView: View {
    @Environment(MiniPlayerScrollState.self) private var miniScroll
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var router = AppRouter.shared
    private let radio = RadioSession.shared
    private let np = NowPlaying.shared
    @State private var recents = RadioRecents.all
    @State private var voiceBlocked = Gemini.voiceExhaustedForDay
    @State private var showSettings = false
    @State private var visible = false
    @ScaledMetric(relativeTo: .largeTitle) private var frequencySize: CGFloat = 44
    @AppStorage(RadioSettings.sectionsKey) private var sectionsOn = true

    /// Las animaciones solo corren con la pestaña a la vista y sin "Reducir movimiento".
    private var animate: Bool { visible && !reduceMotion }

    var body: some View {
        NavigationStack(path: $router.radioPath) {
            ZStack(alignment: .top) {
                background
                ScrollView {
                    VStack(spacing: 18) {
                        header
                        dialBlock
                        hostsRow
                        bubble
                        rundown
                        if !recents.isEmpty { recentsBlock }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                }
                // El hueco del final lo deja el inset de abajo (los botones), que ya cuenta con el mini reproductor.
                .miniPlayerTracksScroll(reservesBottom: false)
                // Los botones quedan fijos justo encima del mini reproductor (que el sistema NO cuenta como zona segura: de ahi el margen).
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    controls
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 8 + miniScroll.insetHeight)
                        .background(RadioPalette.base.opacity(0.94))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .detailRouteDestinations()
            .diagScreen("Radio")
            .onAppear {
                visible = true
                refresh()
            }
            .onDisappear { visible = false }
            .onChange(of: radio.isActive) { refresh() }
            .onChange(of: radio.isStarting) { refresh() }
            .sheet(isPresented: $showSettings, onDismiss: { refresh() }, content: { RadioQuickSettingsSheet() })
        }
    }

    // MARK: - Fondo y cabecera

    /// Berenjena fija con el color de la portada de lo que suena arriba (oscurecido hacia el fondo, para que el crema y el ambar se lean con cualquier portada).
    private var background: some View {
        let tint = radio.isActive ? (np.dominantColors.first ?? RadioPalette.base) : RadioPalette.base
        let top = tint.mix(with: RadioPalette.base, by: 0.35)
        return ZStack(alignment: .top) {
            RadioPalette.base
            LinearGradient(colors: [top.opacity(0.55), RadioPalette.base.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 520)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: np.videoId)
    }

    /// En el aire: el cartel de neon. Apagada: el titulo de siempre. A la derecha, el indicador de gasto y los ajustes.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if radio.isActive {
                RadioNeonSign(animated: animate)
            } else {
                Text("Radio")
                    .font(.system(.largeTitle, design: .rounded).weight(.heavy))
                    .foregroundStyle(RadioPalette.cream)
            }
            Spacer(minLength: 8)
            RadioFuelGauge(spent: RadioSettings.spentToday, cap: RadioSettings.dailyCap, accessibility: usageText)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .foregroundStyle(RadioPalette.mauve)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Radio Settings"))
        }
    }

    // MARK: - El dial: la frecuencia manda

    private var dialBlock: some View {
        ZStack(alignment: .bottom) {
            RadioDialView(
                frequency: radio.frequency, active: radio.isActive, tuning: radio.isStarting && !reduceMotion,
                alive: animate && radio.speakingHost != nil, ink: RadioPalette.cream, needleColor: RadioPalette.neon, height: 150
            )
            VStack(spacing: 2) {
                Text(verbatim: frequencyText)
                    .font(.system(size: frequencySize, weight: .black, design: .rounded))
                    .foregroundStyle(radio.isActive ? RadioPalette.amber : RadioPalette.mauve)
                    .shadow(color: RadioPalette.amber.opacity(radio.isActive ? 0.45 : 0), radius: 12)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(verbatim: "FM · SÓNAR")
                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                    .tracking(2)
                    .foregroundStyle(RadioPalette.mauve)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: radio.isActive ? frequencyText + " FM · Sónar" : "Sónar FM"))
    }

    private var frequencyText: String {
        radio.isActive ? String(format: "%.1f", radio.frequency) : "--.-"
    }

    // MARK: - Los locutores y sus subtitulos

    private var hostsRow: some View {
        HStack(spacing: 22) {
            hostWindow(name: "Pitirre", title: "El Pitirre")
            hostWindow(name: "Chuleta", title: "La Chuleta")
        }
    }

    /// Si habla un oyente (nota de voz), los dos locutores se apagan.
    private func hostWindow(name: String, title: String) -> some View {
        RadioStudioWindow(
            name: name, title: title, speaking: radio.speakingHost == name,
            dimmed: radio.speakingHost != nil && radio.speakingHost != name, animated: animate
        )
    }

    /// Los subtitulos: lo que dice ahora quien habla (con la cola del bocadillo apuntando a su ventana). Sin voz, la ultima frase, la peticion en curso o el estado de la radio.
    private var bubble: some View {
        RadioBubble(
            label: bubbleLabel, icon: radio.speakingHost == nil ? radio.airingSection?.icon : nil, live: radio.speakingHost != nil,
            text: captionText, strong: !radio.speakingText.isEmpty, tail: bubbleTail
        )
    }

    private var bubbleTail: RadioBubble.Tail {
        if radio.speakingHost == "Pitirre" { return .leading }
        if radio.speakingHost == "Chuleta" { return .trailing }
        return .none
    }

    private var bubbleLabel: String {
        if let host = radio.speakingHost { return hostTitle(host) }
        if let kind = radio.airingSection { return NSLocalizedString(kind.displayKey, comment: "") }
        if radio.isActive, !radio.lastText.isEmpty, let host = radio.lastHost { return hostTitle(host) }
        return ""
    }

    private func hostTitle(_ host: String) -> String {
        host == "Chuleta" ? "La Chuleta" : (host == "Pitirre" ? "El Pitirre" : host)
    }

    private var captionText: String {
        if !radio.speakingText.isEmpty { return radio.speakingText }
        if radio.isActive, !radio.lastText.isEmpty { return radio.lastText }
        if radio.isActive, !radio.currentSummary.isEmpty {
            return String(format: NSLocalizedString("Request: %@", comment: ""), radio.currentSummary)
        }
        return statusText
    }

    // MARK: - El programa: ahora y luego

    @ViewBuilder private var rundown: some View {
        if radio.isActive {
            VStack(alignment: .leading, spacing: 8) {
                RadioRundownRow(tag: "Rundown Now", text: nowText, strong: true)
                if sectionsOn, !RadioSettings.enabledSections.isEmpty {
                    RadioRundownRow(tag: "Rundown Next", text: nextText, strong: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Lo que esta en el aire: la seccion o la cancion.
    private var nowText: String {
        if let kind = radio.airingSection { return NSLocalizedString(kind.displayKey, comment: "") }
        if np.title.isEmpty { return "—" }
        return np.artist.isEmpty ? np.title : np.title + " · " + np.artist
    }

    /// La proxima seccion y cuantos comentarios faltan (el orden es al azar).
    private var nextText: String {
        let name = NSLocalizedString(radio.nextSectionKind.displayKey, comment: "")
        let wait = radio.commentsUntilSection == 0
            ? NSLocalizedString("Coming up next", comment: "")
            : String(format: NSLocalizedString("In %d comments", comment: ""), radio.commentsUntilSection)
        return name + " · " + wait
    }

    // MARK: - Botones y peticiones

    private var controls: some View {
        HStack(spacing: 10) {
            Button(action: tap) { mainLabel }
                .buttonStyle(.plain)
                .disabled(radio.isStarting)
            if radio.isActive {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    guard !radio.isStarting else { return }
                    Task { await radio.begin() }
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.title3)
                        .foregroundStyle(RadioPalette.ink)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(RadioPalette.amber))
                }
                .buttonStyle(.plain)
                .disabled(radio.isStarting)
                .accessibilityLabel(Text("New Request"))
            }
        }
        .opacity(radio.isStarting ? 0.6 : 1)
    }

    private var mainLabel: some View {
        HStack(spacing: 10) {
            if radio.isActive {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(RadioPalette.rec)
                    .frame(width: 11, height: 11)
            } else {
                Image(systemName: "mic.fill")
            }
            Text(LocalizedStringKey(radio.isActive ? "Stop the Radio" : "Ask for Music"))
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .textCase(.uppercase)
                .tracking(0.5)
        }
        .foregroundStyle(RadioPalette.ink)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(radio.isActive ? RadioPalette.cream : RadioPalette.amber))
    }

    private var recentsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Requests")
                .font(.footnote)
                .foregroundStyle(RadioPalette.mauve)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(recents, id: \.self) { text in
                        recentChip(text)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recentChip(_ text: String) -> some View {
        Button {
            guard !radio.isStarting else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { await radio.begin(request: text) }
        } label: {
            Text(verbatim: text)
                .font(.system(.footnote, design: .rounded).weight(.medium))
                .foregroundStyle(RadioPalette.cream)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(RadioPalette.mauve.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Textos

    private func refresh() {
        recents = RadioRecents.all
        voiceBlocked = Gemini.voiceExhaustedForDay
    }

    private var statusText: String {
        if radio.isStarting { return NSLocalizedString("Getting the radio ready…", comment: "") }
        if voiceBlocked {
            return NSLocalizedString("Voice limit reached: music only until the daily reset (9:00 in Spain).", comment: "")
        }
        if radio.isActive { return NSLocalizedString("On the Air", comment: "") + " · Sónar FM" }
        if !RadioSettings.isConfigured { return NSLocalizedString("Set up the radio in Settings > Radio.", comment: "") }
        return NSLocalizedString("Tell the hosts what you feel like hearing.", comment: "")
    }

    /// El gasto completo, para VoiceOver (a la vista solo hay un indicador pequeño).
    private var usageText: String {
        let voice = String(format: NSLocalizedString("Voice requests today: %d", comment: ""), RadioSettings.voiceRequestsToday)
        let cap = RadioSettings.dailyCap
        let spent = String(format: "%.3f €", RadioSettings.spentToday)
        let limit = cap > 0 ? String(format: "%.2f €", cap) : NSLocalizedString("No limit", comment: "")
        return voice + " · " + String(format: NSLocalizedString("Estimated spend today: %@", comment: ""), spent + " / " + limit)
    }

    private func tap() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if radio.isActive {
            radio.stop(reason: "boton")
            PlaybackNotice.shared.show(NSLocalizedString("Radio stopped.", comment: ""))
            return
        }
        guard !radio.isStarting else { return }
        Task { await radio.begin() }
    }
}

// MARK: - Piezas de la cabina

/// El cartel de neon "en el aire": el punto late solo si hay animaciones.
struct RadioNeonSign: View {
    let animated: Bool

    var body: some View {
        HStack(spacing: 7) {
            OnAirDot(pulsing: animated, color: RadioPalette.neon)
            Text("On the Air")
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(RadioPalette.neon)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(RadioPalette.neon, lineWidth: 2))
        .shadow(color: RadioPalette.neon.opacity(0.4), radius: 8)
    }
}

/// El punto que late cuando hay animaciones.
struct OnAirDot: View {
    let pulsing: Bool
    var color: Color = .red

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !pulsing)) { timeline in
            let pulse = pulsing ? 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 4) : 1
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .opacity(pulsing ? 0.45 + 0.55 * pulse : 1)
        }
        .accessibilityHidden(true)
    }
}

/// El indicador de combustible: lo gastado hoy frente al tope diario (rojo neon al acercarse al tope). Sin tope, solo el gasto.
struct RadioFuelGauge: View {
    let spent: Double
    let cap: Double
    let accessibility: String

    private var fraction: Double { cap > 0 ? min(1, max(0, spent / cap)) : 0 }

    private var label: String {
        cap > 0 ? String(format: "%.2f / %.2f €", spent, cap) : String(format: "%.2f €", spent)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(verbatim: label)
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(RadioPalette.mauve)
            if cap > 0 {
                Capsule()
                    .fill(RadioPalette.line)
                    .frame(width: 74, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(fraction > 0.85 ? RadioPalette.neon : RadioPalette.amber)
                            .frame(width: 74 * fraction, height: 5)
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibility))
    }
}

/// El bocadillo de los subtitulos: papel crema con la tinta oscura (legible con cualquier fondo) y una cola que apunta a quien habla.
struct RadioBubble: View {
    enum Tail { case none, leading, trailing }

    let label: String
    let icon: String?
    let live: Bool
    let text: String
    let strong: Bool
    let tail: Tail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !label.isEmpty { labelRow }
            Text(verbatim: text)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(strong ? RadioPalette.ink : RadioPalette.inkSoft)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.25), value: text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(RadioPalette.cream))
        .overlay(alignment: .top) { tailRow }
    }

    private var labelRow: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
            } else if live {
                Circle().fill(RadioPalette.rec).frame(width: 6, height: 6)
            }
            Text(verbatim: label)
                .textCase(.uppercase)
        }
        .font(.system(.caption2, design: .monospaced).weight(.bold))
        .tracking(1)
        .foregroundStyle(RadioPalette.label)
    }

    /// Dos huecos del ancho de las ventanas de los locutores (mismo espacio entre ellos): la cola va en el de quien habla.
    private var tailRow: some View {
        HStack(spacing: 22) {
            tailSlot(.leading)
            tailSlot(.trailing)
        }
        .offset(y: -9)
        .accessibilityHidden(true)
    }

    private func tailSlot(_ side: Tail) -> some View {
        Color.clear
            .frame(width: 112, height: 10)
            .overlay {
                if tail == side {
                    RadioBubbleTail()
                        .fill(RadioPalette.cream)
                        .frame(width: 20, height: 10)
                }
            }
    }
}

struct RadioBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Una fila del programa: una etiqueta (ahora / luego) y lo que es, en letra de maquina de escribir.
struct RadioRundownRow: View {
    let tag: LocalizedStringKey
    let text: String
    let strong: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(tag)
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(strong ? RadioPalette.ink : RadioPalette.cream)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(strong ? RadioPalette.cream : RadioPalette.line))
            Text(verbatim: text)
                .font(.system(.footnote, design: .monospaced).weight(.medium))
                .foregroundStyle(RadioPalette.cream)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}
