//
//  RadioScreenView.swift
//  Trop
//
//  La pestaña "Radio" (entre Inicio y Biblioteca), con el lenguaje del resto de la app (fondo del sistema, tipografia del sistema, capsulas grises, un solo color vivo: el rojo de
//  "en el aire") y una estructura de estudio en directo: la pastilla "en el aire", el dial con la frecuencia como protagonista, los dos locutores en ventanas de estudio
//  (el que habla se ilumina y el otro se apaga), los subtitulos en un bocadillo que señala a quien habla, el programa (ahora / luego), tus ultimas peticiones y, fijos encima
//  del mini reproductor, los botones para pedir musica por voz o parar la radio. El color de la portada de lo que suena tiñe la parte de arriba. El gasto del dia es un
//  indicador pequeño; los ajustes estan detras del boton de arriba a la derecha. Las animaciones solo corren con la pestaña a la vista y sin "Reducir movimiento"; el dial y
//  los medidores se mueven solo mientras alguien habla.
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

struct RadioScreenView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(MiniPlayerScrollState.self) private var miniScroll
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var router = AppRouter.shared
    private let radio = RadioSession.shared
    private let np = NowPlaying.shared
    @State private var recents = RadioRecents.all
    @State private var voiceBlocked = Gemini.voiceExhaustedForDay
    @State private var showSettings = false
    @State private var visible = false
    @ScaledMetric(relativeTo: .largeTitle) private var frequencySize: CGFloat = 46
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
                        .background(Color(.systemBackground).opacity(0.92))
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

    /// El color de la portada de lo que suena, suave, arriba (solo con la radio en el aire).
    private var background: some View {
        let tint = radio.isActive ? (np.dominantColors.first ?? Color.clear) : Color.clear
        return ZStack(alignment: .top) {
            Color(.systemBackground)
            LinearGradient(colors: [tint.opacity(0.45), Color.clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 460)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: np.videoId)
    }

    /// En el aire: la pastilla roja. Apagada: el titulo de siempre. A la derecha, el indicador de gasto y los ajustes.
    private var header: some View {
        HStack(spacing: 10) {
            if radio.isActive {
                HStack(spacing: 6) {
                    OnAirDot(pulsing: animate)
                    Text("On the Air")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.red)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.red.opacity(0.15)))
            } else {
                Text("Radio")
                    .font(.largeTitle)
                    .fontWeight(.bold)
            }
            Spacer(minLength: 8)
            RadioFuelGauge(spent: RadioSettings.spentToday, cap: RadioSettings.dailyCap, accessibility: usageText)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Radio Settings"))
        }
        .padding(.top, 4)
    }

    // MARK: - El dial: la frecuencia manda

    private var dialBlock: some View {
        VStack(spacing: 0) {
            RadioDialView(
                frequency: radio.frequency, active: radio.isActive, tuning: radio.isStarting && !reduceMotion,
                alive: animate && radio.speakingHost != nil, ink: .primary, needleColor: .red, height: 124
            )
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: frequencyText)
                    .font(.system(size: frequencySize, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(radio.isActive ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(verbatim: "FM · Sónar")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, -2)
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
                RadioRundownRow(tag: "Rundown Now", text: nowText)
                if sectionsOn, !RadioSettings.enabledSections.isEmpty {
                    RadioRundownRow(tag: "Rundown Next", text: nextText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.08)))
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
        HStack(spacing: 12) {
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
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.red.opacity(0.15)))
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)
                .disabled(radio.isStarting)
                .accessibilityLabel(Text("New Request"))
            }
        }
        .opacity(radio.isStarting ? 0.6 : 1)
    }

    /// Parar: capsula gris con el cuadrado rojo. Pedir musica (radio apagada): capsula con el color de acento de la app.
    private var mainLabel: some View {
        HStack(spacing: 10) {
            if radio.isActive {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.red)
                    .frame(width: 11, height: 11)
            } else {
                Image(systemName: "mic.fill")
            }
            Text(LocalizedStringKey(radio.isActive ? "Stop the Radio" : "Ask for Music"))
                .font(.headline)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(Capsule().fill(radio.isActive ? Color(.systemGray5) : settings.accentColor))
        .foregroundColor(radio.isActive ? .primary : settings.accentOnColor)
    }

    private var recentsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Requests")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Capsule().fill(Color(.systemGray5)))
                .contentShape(Capsule())
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

// MARK: - Piezas de la pantalla

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

/// El indicador de gasto: lo gastado hoy frente al tope diario (rojo al acercarse al tope). Sin tope, solo el gasto.
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
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if cap > 0 {
                Capsule()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 62, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(fraction > 0.85 ? Color.red : Color.primary.opacity(0.8))
                            .frame(width: 62 * fraction, height: 4)
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibility))
    }
}

/// El bocadillo de los subtitulos: una sola pieza translucida (cuerpo y cola) con una cola que apunta a quien habla.
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
                .font(.body.weight(.medium))
                .foregroundStyle(strong ? Color.primary : Color.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.25), value: text)
        }
        .padding(.horizontal, 15)
        .padding(.top, 13 + RadioBubbleShape.tailHeight)
        .padding(.bottom, 13)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(RadioBubbleShape(tail: tail).fill(Color.primary.opacity(0.1)))
    }

    private var labelRow: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
            } else if live {
                Circle().fill(Color.red).frame(width: 6, height: 6)
            }
            Text(verbatim: label)
                .textCase(.uppercase)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(live ? Color.red : Color.secondary)
    }
}

/// Cuerpo redondeado con una cola arriba que apunta a la ventana de quien habla: las ventanas miden 112 pt y van separadas 22 pt, centradas.
struct RadioBubbleShape: Shape {
    static let tailHeight: CGFloat = 9
    let tail: RadioBubble.Tail

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + Self.tailHeight, width: rect.width, height: rect.height - Self.tailHeight)
        var path = Path(roundedRect: body, cornerRadius: 18, style: .continuous)
        if tail != .none {
            let centerX = rect.midX + (tail == .leading ? -67 : 67)
            path.move(to: CGPoint(x: centerX - 10, y: body.minY + 1))
            path.addLine(to: CGPoint(x: centerX, y: rect.minY))
            path.addLine(to: CGPoint(x: centerX + 10, y: body.minY + 1))
            path.closeSubpath()
        }
        return path
    }
}

/// Una fila del programa: una etiqueta pequeña (ahora / luego) y lo que es.
struct RadioRundownRow: View {
    let tag: LocalizedStringKey
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(tag)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .leading)
            Text(verbatim: text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}
