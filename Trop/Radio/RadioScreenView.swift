//
//  RadioScreenView.swift
//  Trop
//
//  La pestaña "Radio" (entre Inicio y Biblioteca), como un estudio en directo: la pastilla "en el aire" con la frecuencia, los dos locutores grandes (el que habla
//  se ilumina y el otro se apaga), los subtitulos de lo que dicen, lo que suena, la siguiente seccion y, fijos encima del mini reproductor, los botones para
//  pedir musica por voz o parar la radio. Los ajustes estan detras del boton de arriba a la derecha. Debajo, tus ultimas peticiones para repetirlas con un toque.
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
    @ObservedObject private var router = AppRouter.shared
    private let radio = RadioSession.shared
    private let np = NowPlaying.shared
    @State private var recents = RadioRecents.all
    @State private var voiceBlocked = Gemini.voiceExhaustedForDay
    @State private var showSettings = false
    @AppStorage(RadioSettings.sectionsKey) private var sectionsOn = true

    var body: some View {
        NavigationStack(path: $router.radioPath) {
            ZStack(alignment: .top) {
                background
                ScrollView {
                    VStack(spacing: 16) {
                        header
                        studio
                        if radio.isActive { nowRow }
                        if radio.isActive, sectionsOn { sectionStrip }
                        if !recents.isEmpty { recentsBlock }
                        Text(usageText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 16)
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
            .onAppear { refresh() }
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

    /// En el aire: la pastilla roja y la frecuencia. Apagada: el titulo de siempre.
    private var header: some View {
        HStack(spacing: 10) {
            if radio.isActive {
                HStack(spacing: 6) {
                    OnAirDot(active: true)
                    Text("On the Air")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.red)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.red.opacity(0.15)))
                Text(verbatim: String(format: "%.1f FM", radio.frequency))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Radio")
                    .font(.largeTitle)
                    .fontWeight(.bold)
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Radio Settings"))
        }
        .padding(.top, 8)
    }

    // MARK: - El estudio: locutores y subtitulos

    private var studio: some View {
        VStack(spacing: 14) {
            HStack(spacing: 30) {
                RadioHostView(name: "Pitirre", title: "El Pitirre", speaking: radio.speakingHost == "Pitirre", size: 92,
                              dimmed: radio.speakingHost == "Chuleta")
                RadioHostView(name: "Chuleta", title: "La Chuleta", speaking: radio.speakingHost == "Chuleta", size: 92,
                              dimmed: radio.speakingHost == "Pitirre")
            }
            .padding(.top, 6)
            captionCard
            if radio.isActive {
                RadioEqualizerView(active: np.isPlaying || radio.speakingHost != nil)
            }
        }
    }

    /// Los subtitulos: lo que dice ahora quien habla. Sin voz, la peticion en curso o el estado de la radio.
    private var captionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if radio.speakingHost != nil || radio.airingSection != nil {
                HStack(spacing: 6) {
                    if let kind = radio.airingSection {
                        Image(systemName: kind.icon)
                            .font(.caption)
                    }
                    if let host = radio.speakingHost {
                        Text(verbatim: host == "Chuleta" ? "La Chuleta" : (host == "Pitirre" ? "El Pitirre" : host))
                            .font(.caption.weight(.semibold))
                    } else if let kind = radio.airingSection {
                        Text(LocalizedStringKey(kind.displayKey))
                            .font(.caption.weight(.semibold))
                    }
                }
                .foregroundStyle(Color.red)
            }
            Text(verbatim: captionText)
                .font(.body)
                .foregroundStyle(radio.speakingText.isEmpty ? Color.secondary : Color.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.25), value: captionText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var captionText: String {
        if !radio.speakingText.isEmpty { return radio.speakingText }
        if radio.isActive, !radio.currentSummary.isEmpty {
            return String(format: NSLocalizedString("Request: %@", comment: ""), radio.currentSummary)
        }
        return statusText
    }

    // MARK: - Lo que suena

    private var nowRow: some View {
        HStack(spacing: 12) {
            if let kind = radio.airingSection {
                sectionTile(kind)
            } else {
                RadioDiscView(cover: np.thumbnailUIImage, spinning: np.isPlaying)
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let kind = radio.airingSection {
                    Text(LocalizedStringKey(kind.displayKey))
                        .font(.subheadline.weight(.semibold))
                } else {
                    Text(verbatim: np.title.isEmpty ? "—" : np.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(verbatim: np.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func sectionTile(_ kind: RadioSectionKind) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.15))
            Image(systemName: kind.icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.red)
        }
        .frame(width: 44, height: 44)
    }

    /// Una sola linea con la proxima seccion (el orden es al azar, asi que sin puntos de progreso).
    private var sectionStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: radio.nextSectionKind.icon)
                .font(.body)
                .frame(width: 24)
            Text(String(format: NSLocalizedString("Next section: %@", comment: ""), NSLocalizedString(radio.nextSectionKind.displayKey, comment: "")))
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(radio.commentsUntilSection == 0
                 ? NSLocalizedString("Coming up next", comment: "")
                 : String(format: NSLocalizedString("In %d comments", comment: ""), radio.commentsUntilSection))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Botones y peticiones

    private var controls: some View {
        HStack(spacing: 12) {
            Button(action: tap) {
                Label(
                    LocalizedStringKey(radio.isActive ? "Stop the Radio" : "Ask for Music"),
                    systemImage: radio.isActive ? "stop.fill" : "mic.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule().fill(radio.isActive ? Color(.systemGray5) : settings.accentColor))
                .foregroundColor(radio.isActive ? .primary : settings.accentOnColor)
            }
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
    }

    private var recentsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Requests")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(recents, id: \.self) { text in
                        Button {
                            guard !radio.isStarting else { return }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            Task { await radio.begin(request: text) }
                        } label: {
                            Text(verbatim: text)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color(.systemGray5)))
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// El punto rojo que late cuando la radio esta en el aire.
struct OnAirDot: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !active)) { timeline in
            let pulse = active ? 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 4) : 0
            Circle()
                .fill(active ? Color.red : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
                .opacity(active ? 0.45 + 0.55 * pulse : 1)
        }
    }
}
