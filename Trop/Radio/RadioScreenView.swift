//
//  RadioScreenView.swift
//  Trop
//
//  La pestaña "Radio" (entre Inicio y Biblioteca): el boton grande de Sónar FM (pedir musica por voz / parar la radio), tus ultimas peticiones como pildoras
//  para repetirlas con un toque sin hablar, y los ajustes de uso frecuente. Los demas (clave, voces, modelos) estan en Ajustes > Radio.
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
    private let accountState = AccountSheetState.shared
    private let radio = RadioSession.shared
    @State private var recents = RadioRecents.all
    @State private var voiceBlocked = Gemini.voiceExhaustedForDay
    @AppStorage(RadioSettings.sectionsKey) private var sections = true
    @AppStorage(RadioSettings.memoryKey) private var memory = true
    @AppStorage(RadioSettings.talkEveryKey) private var talkEvery = 2
    @AppStorage(RadioSettings.cityKey) private var city = "Sabadell"

    var body: some View {
        NavigationStack(path: $router.radioPath) {
            VStack(spacing: 0) {
                TabHeaderView(
                    title: "Radio",
                    accountIsLoggedIn: accountState.isLoggedIn,
                    accountImageUrl: accountState.accountImageUrl,
                    onHistory: { router.radioPath.append(DetailRoute.history) },
                    onAccount: { router.radioPath.append(DetailRoute.settings) }
                )
                List {
                    Section {
                        startCard
                            .listRowSeparator(.hidden)
                    }

                    if !recents.isEmpty {
                        Section {
                            recentsRow
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        } header: {
                            Text("Recent Requests")
                        }
                    }

                    Section {
                        Toggle("Sections", isOn: $sections)
                        Picker("Talk", selection: $talkEvery) {
                            ForEach(1...5, id: \.self) { count in
                                Text(count == 1
                                     ? NSLocalizedString("Every song", comment: "")
                                     : String(format: NSLocalizedString("Every %d songs", comment: ""), count))
                                    .tag(count)
                            }
                        }
                        Toggle("Radio Remembers", isOn: $memory)
                        Picker("City for the Weather", selection: $city) {
                            ForEach(RadioSettings.cities, id: \.name) { place in
                                Text(verbatim: place.name).tag(place.name)
                            }
                        }
                        Text(spendText)
                            .foregroundStyle(.secondary)
                        Text(String(format: NSLocalizedString("Voice requests today: %d", comment: ""), RadioSettings.voiceRequestsToday))
                            .foregroundStyle(.secondary)
                        SettingsNavigationRow("All Radio Settings", icon: "dot.radiowaves.left.and.right") {
                            RadioSettingsView()
                        }
                    } header: {
                        Text("Quick Settings")
                    }
                }
                .sonarSettingsList()
                .miniPlayerTracksScroll()
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .toolbar(.hidden, for: .navigationBar)
            .detailRouteDestinations()
            .diagScreen("Radio")
            .onAppear { refresh() }
            .onChange(of: radio.isActive) { refresh() }
            .onChange(of: radio.isStarting) { refresh() }
        }
    }

    // MARK: - Piezas

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(LinearGradient(
                        colors: [Color.orange, Color.red], startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    if radio.isStarting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: radio.isActive ? "dot.radiowaves.left.and.right" : "mic.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .symbolEffect(.variableColor.iterative, isActive: radio.isActive)
                    }
                }
                .frame(width: 60, height: 60)

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Sónar FM")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            Button(action: tap) {
                Label(
                    LocalizedStringKey(radio.isActive ? "Stop the Radio" : "Ask for Music"),
                    systemImage: radio.isActive ? "stop.fill" : "mic.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(radio.isActive ? Color(.systemGray5) : settings.accentColor))
                .foregroundColor(radio.isActive ? .primary : settings.accentOnColor)
            }
            .buttonStyle(.plain)
            .disabled(radio.isStarting)
        }
        .padding(.vertical, 6)
    }

    private var recentsRow: some View {
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

    private func refresh() {
        recents = RadioRecents.all
        voiceBlocked = Gemini.voiceExhaustedForDay
    }

    private var statusText: String {
        if radio.isStarting { return NSLocalizedString("Getting the radio ready…", comment: "") }
        if voiceBlocked {
            return NSLocalizedString("Voice limit reached: music only until the daily reset (9:00 in Spain).", comment: "")
        }
        if radio.isActive {
            if radio.currentSummary.isEmpty { return NSLocalizedString("The radio is on. Tap to stop it.", comment: "") }
            return String(format: NSLocalizedString("On the air: %@", comment: ""), radio.currentSummary)
        }
        if !RadioSettings.isConfigured { return NSLocalizedString("Set up the radio in Settings > Radio.", comment: "") }
        return NSLocalizedString("Tell the hosts what you feel like hearing.", comment: "")
    }

    private var spendText: String {
        let cap = RadioSettings.dailyCap
        let spent = String(format: "%.3f €", RadioSettings.spentToday)
        let limit = cap > 0 ? String(format: "%.2f €", cap) : NSLocalizedString("No limit", comment: "")
        return String(format: NSLocalizedString("Estimated spend today: %@", comment: ""), spent + " / " + limit)
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
