//
//  RadioScreenView.swift
//  Trop
//
//  La pestaña "Radio" (entre Inicio y Biblioteca): un dial con aguja, el disco con la portada de lo que suena, los dos locutores (se iluminan cuando hablan), la
//  siguiente seccion y el boton para pedir musica por voz o parar la radio. Los ajustes estan detras del boton de arriba a la derecha. Debajo, tus ultimas
//  peticiones como pildoras para repetirlas con un toque sin hablar.
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
                    VStack(spacing: 18) {
                        header
                        dialCard
                        if radio.isActive { nowCard }
                        hostsRow
                        if radio.isActive, sectionsOn { sectionStrip }
                        controls
                        if !recents.isEmpty { recentsBlock }
                        Text(usageText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .miniPlayerTracksScroll()
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

    private var header: some View {
        HStack {
            Text("Radio")
                .font(.largeTitle)
                .fontWeight(.bold)
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

    // MARK: - Dial

    private var dialCard: some View {
        VStack(spacing: 4) {
            RadioDialView(frequency: radio.frequency, active: radio.isActive, tuning: radio.isStarting)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: radio.isActive || radio.isStarting ? String(format: "%.1f", radio.frequency) : "--.-")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                Text(verbatim: "FM")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                OnAirDot(active: radio.isActive)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(radio.isActive ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Lo que suena

    private var nowCard: some View {
        HStack(spacing: 16) {
            if let kind = radio.airingSection {
                sectionTile(kind)
            } else {
                RadioDiscView(cover: np.thumbnailUIImage, spinning: np.isPlaying)
                    .frame(width: 92, height: 92)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let kind = radio.airingSection {
                    Text(LocalizedStringKey(kind.displayKey))
                        .font(.headline)
                    RadioEqualizerView(active: true)
                } else {
                    Text("Now Playing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: np.title.isEmpty ? "—" : np.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(verbatim: np.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !radio.currentSummary.isEmpty {
                    Text(String(format: NSLocalizedString("Request: %@", comment: ""), radio.currentSummary))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func sectionTile(_ kind: RadioSectionKind) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Color.red.opacity(0.15))
            Image(systemName: kind.icon)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(Color.red)
        }
        .frame(width: 92, height: 92)
    }

    // MARK: - Locutores y seccion

    private var hostsRow: some View {
        HStack(spacing: 34) {
            RadioHostView(name: "Pitirre", title: "El Pitirre", speaking: radio.speakingHost == "Pitirre")
            RadioHostView(name: "Chuleta", title: "La Chuleta", speaking: radio.speakingHost == "Chuleta")
        }
        .padding(.vertical, 4)
    }

    private var sectionStrip: some View {
        let kinds = RadioSectionKind.allCases
        let current = kinds.firstIndex(of: radio.nextSectionKind) ?? 0
        return HStack(spacing: 12) {
            Image(systemName: radio.nextSectionKind.icon)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: NSLocalizedString("Next section: %@", comment: ""), NSLocalizedString(radio.nextSectionKind.displayKey, comment: "")))
                    .font(.subheadline)
                Text(radio.commentsUntilSection == 0
                     ? NSLocalizedString("Coming up next", comment: "")
                     : String(format: NSLocalizedString("In %d comments", comment: ""), radio.commentsUntilSection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                ForEach(0..<kinds.count, id: \.self) { index in
                    Circle()
                        .fill(index == current ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
        }
        .padding(12)
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
