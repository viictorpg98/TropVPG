//
//  HomeViewModel.swift
//  Trop
//
//  Created by 686udjie on 01/07/2026.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class HomeViewModel {
    var homePage: HomePage?
    var homeSections: [HomeSection] = []
    var isLoading = true
    var isRefreshing = false
    var selectedChip: HomePage.Chip?
    /// Mientras llega la portada del chip elegido (la lista se vacia y se muestra una carga).
    var isChipLoading = false
    var error: Error?
    /// `true` si lo que se ve es la ultima portada guardada (sin conexion o con la peticion fallida).
    var isShowingCachedHome = false
    var cachedHomeDate: Date?
    @ObservationIgnored private var homeFetchFailure: Error?

    var isLoggedIn = false

    var hideExplicit = false {
        didSet { mergeSections(stable: false) }
    }

    /// Mientras carga (primera vez o al recargar) la lista no se toca: se publica una sola vez, al terminar. Antes, lo de
    /// segundo plano (secciones propias y de la cuenta) la publicaba incompleta y, al llegar la portada, se reordenaba entera.
    @ObservationIgnored private var holdMerges = false
    @ObservationIgnored private var lastPublishedIds: [String] = []
    private var isHomeDataLoaded = false
    private var isLoadingMore = false
    private var loadGeneration = 0
    private var previousHomePage: HomePage?
    private let cookieStore = CookieStore()
    private let personalization = PersonalizationService.shared

    private var cachedLocalSections: [HomeSection] = []
    private var cachedPhase2Sections: [HomeSection] = []

    private let cleanup = HomeViewModelCleanup()

    deinit {
        if let observer = cleanup.notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        cleanup.chipTask?.cancel()
    }

    init() {
        hideExplicit = SettingsStore.shared.hideExplicit
        if let existing = cleanup.notificationObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        cleanup.notificationObserver = NotificationCenter.default.addObserver(
            forName: .personalizationDataUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshLocalSections()
        }
    }

    private nonisolated func refreshLocalSections() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let settings = SettingsStore.shared
            async let qp: HomeSection = settings.showQuickPicks
                ? await personalization.buildQuickPicks(limit: settings.topListsLength)
                : .quickPicks(items: [])
            async let kl: HomeSection = await personalization.buildKeepListening()
            async let ff: HomeSection = await personalization.buildForgottenFavorites()
            let (qpResult, klResult, ffResult) = await (qp, kl, ff)
            var local: [HomeSection] = []
            if !qpResult.items.isEmpty { local.append(qpResult) }
            if !klResult.items.isEmpty { local.append(klResult) }
            if !ffResult.items.isEmpty { local.append(ffResult) }
            self.cachedLocalSections = local
            self.mergeSections()
            await self.personalization.drainEnrichments()
            let refreshed = await (
                self.personalization.buildForgottenFavorites(),
                self.personalization.buildKeepListening()
            )
            var merged = local
            merged.removeAll { section in
                switch section {
                case .forgottenFavorites, .keepListening: return true
                default: return false
                }
            }
            if !refreshed.0.items.isEmpty { merged.append(refreshed.0) }
            if !refreshed.1.items.isEmpty { merged.append(refreshed.1) }
            self.cachedLocalSections = merged
            self.mergeSections()
        }
    }

    /// Re-reads settings that affect the feed (explicit filter, quick picks).
    func syncSettings() {
        let settings = SettingsStore.shared
        hideExplicit = settings.hideExplicit
    }

    func loadHomeData() {
        guard !isHomeDataLoaded else { return }
        isHomeDataLoaded = true
        PlaybackReport.record("inicio: empieza la carga a los \(LaunchClock.ms()) ms")
        Task { await load() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Con un chip elegido se recarga lo de ese chip (antes salia la portada normal con el chip aun marcado).
        if let chip = selectedChip {
            let generation = loadGeneration
            if let page = await fetchChipPage(chip),
               !Task.isCancelled, generation == loadGeneration, selectedChip?.title == chip.title {
                applyChipPage(page, chip: chip)
            }
            return
        }
        // Las secciones de la cuenta se conservan hasta que lleguen las nuevas (la lista no se encoge mientras tanto).
        cachedLocalSections = []
        await load()
    }

    func restoreSession() async {
        let loggedIn = await cookieStore.isLoggedIn()
        isLoggedIn = loggedIn
        guard loggedIn else { return }
        await InnerTubeClient.tropShared.loadState(from: cookieStore)
    }

    func handleSessionChange(loggedIn: Bool) {
        // Si ya se sabia (al arrancar, la pantalla restaura la sesion y avisa del mismo valor), no se repite el trabajo.
        guard loggedIn != isLoggedIn else { return }
        isLoggedIn = loggedIn
        if loggedIn {
            Task {
                await InnerTubeClient.tropShared.loadState(from: cookieStore)
                await loadPhase2Sections()
            }
        } else {
            cachedPhase2Sections = []
            mergeSections(stable: false)
        }
    }

    // MARK: - Home Data Loading

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        holdMerges = true
        error = nil
        homeFetchFailure = nil

        await storeLocalSections()
        guard generation == loadGeneration else { return }

        // Lo lento (completar los datos de las canciones y las secciones de la cuenta) va en segundo plano:
        // la portada se ensena en cuanto llega, y esto se va anadiendo.
        let background = Task { await self.finishBackground(generation: generation) }

        await fetchHomePage(generation: generation)
        guard generation == loadGeneration else { return }
        await ensureQuickPicksAvailable(generation: generation)
        guard generation == loadGeneration else { return }

        // Si la portada no llego, se espera a lo demas por si hay algo que ensenar.
        if homePage == nil, homeFetchFailure != nil {
            await background.value
            guard generation == loadGeneration else { return }
        }
        // El error solo se ensena si no hay nada que ensenar: ni portada guardada ni secciones propias.
        if homePage == nil, let failure = homeFetchFailure, cachedLocalSections.isEmpty, cachedPhase2Sections.isEmpty {
            error = failure
        }
        homeFetchFailure = nil
        holdMerges = false
        mergeSections()
        isLoading = false
    }

    /// Completa los datos de las canciones propias y carga las secciones de la cuenta, y lo va poniendo en la lista.
    private func finishBackground(generation: Int) async {
        async let phase2: Void = loadPhase2Sections()
        await personalization.drainEnrichments()
        if generation == loadGeneration {
            await storeLocalSections()
            mergeSections(freshContent: true)
        }
        await phase2
    }

    private func ensureQuickPicksAvailable(generation: Int) async {
        guard SettingsStore.shared.showQuickPicks else { return }
        var attempts = 0
        while attempts < 3,
              generation == loadGeneration,
              !hasQuickPicksServerSection(),
              !isLoadingMore,
              let continuation = homePage?.continuation {
            attempts += 1
            isLoadingMore = true
            do {
                let json = try await InnerTubeClient.tropShared.browse(continuation: continuation)
                guard let (newSections, next) = await Self.parseContinuation(json) else {
                    isLoadingMore = false
                    break
                }
                homePage?.sections.append(contentsOf: newSections)
                homePage?.continuation = next
                mergeSections()
                isLoadingMore = false
            } catch {
                isLoadingMore = false
                break
            }
        }
    }

    private func hasQuickPicksServerSection() -> Bool {
        homePage?.sections.contains { section in
            if case .quickPicks = mapServerSection(section, index: 0) { return true }
            return false
        } ?? false
    }

    private func fetchHomePage(generation: Int) async {
        // Sin conexion no se espera a que la peticion falle (y reintente): directo a lo guardado.
        guard NetworkMonitor.shared.hasConnection else {
            await useCachedHome(orFail: URLError(.notConnectedToInternet), generation: generation)
            return
        }
        do {
            let json = try await InnerTubeClient.tropShared.browse(browseId: "FEmusic_home")
            guard let page = await Self.parseHome(json) else {
                await useCachedHome(orFail: InnerTubeError.decodingFailed, generation: generation)
                return
            }
            HomeCache.save(json)
            isShowingCachedHome = false
            cachedHomeDate = nil
            homePage = page
            PlaybackReport.record("inicio: portada del servidor a los \(LaunchClock.ms()) ms (\(page.sections.count) secciones)")
        } catch {
            await useCachedHome(orFail: error, generation: generation)
        }
    }

    /// Enseña la ultima portada guardada; si no hay ninguna, apunta el fallo para enseñarlo solo si no hay nada mas.
    private func useCachedHome(orFail failure: Error, generation: Int) async {
        guard generation == loadGeneration else { return }
        if let cached = HomeCache.load(), var page = await Self.parseHome(cached.json) {
            page.chips = []          // los chips piden datos nuevos a YouTube
            page.continuation = nil
            homePage = page
            isShowingCachedHome = true
            cachedHomeDate = cached.date
        } else {
            homeFetchFailure = failure
        }
    }

    private func storeLocalSections() async {
        let settings = SettingsStore.shared
        async let qp: HomeSection = settings.showQuickPicks
            ? personalization.buildQuickPicks(limit: settings.topListsLength)
            : .quickPicks(items: [])
        async let kl: HomeSection = personalization.buildKeepListening()
        async let ff: HomeSection = personalization.buildForgottenFavorites()

        let (qpResult, klResult, ffResult) = await (qp, kl, ff)

        var local: [HomeSection] = []
        if !qpResult.items.isEmpty { local.append(qpResult) }
        if !klResult.items.isEmpty { local.append(klResult) }
        if !ffResult.items.isEmpty { local.append(ffResult) }
        cachedLocalSections = local
    }

    private func loadPhase2Sections() async {
        guard isLoggedIn, NetworkMonitor.shared.hasConnection else { return }

        async let ap: HomeSection = personalization.buildAccountPlaylists()
        async let dd: HomeSection = personalization.buildDailyDiscover()
        async let ct: HomeSection = personalization.buildFromTheCommunity()
        async let sr: [HomeSection] = personalization.buildSimilarRecommendations()

        let (apResult, ddResult, ctResult, srResults) = await (ap, dd, ct, sr)
        var phase2: [HomeSection] = []
        if !apResult.items.isEmpty { phase2.append(apResult) }
        if !ddResult.items.isEmpty { phase2.append(ddResult) }
        if !ctResult.items.isEmpty { phase2.append(ctResult) }
        phase2.append(contentsOf: srResults)
        cachedPhase2Sections = phase2

        mergeSections(freshContent: true)
    }

    func toggleChip(_ chip: HomePage.Chip?) {
        cleanup.chipTask?.cancel()
        if chip == nil || chip?.title == selectedChip?.title {
            homePage = previousHomePage
            previousHomePage = nil
            selectedChip = nil
            isChipLoading = false
            mergeSections(stable: false)
            return
        }

        if selectedChip == nil {
            previousHomePage = homePage
        }

        selectedChip = chip
        // Como en YouTube Music: al elegir un chip la portada se vacia al momento y se rellena con lo
        // que YouTube devuelve para ese chip (sin las secciones propias de la app).
        isChipLoading = true
        let generation = loadGeneration
        guard let chip else { return }
        cleanup.chipTask = Task {
            let page = await fetchChipPage(chip)
            guard !Task.isCancelled, generation == loadGeneration, selectedChip?.title == chip.title else { return }
            if let page {
                applyChipPage(page, chip: chip)
            } else {
                restoreAfterChipFailure()
            }
        }
    }

    /// La portada del chip, en el idioma del dispositivo (asi los titulos de podcasts no llegan traducidos al ingles).
    private func fetchChipPage(_ chip: HomePage.Chip) async -> HomePage? {
        do {
            let json = try await InnerTubeClient.tropShared.browse(
                browseId: "FEmusic_home",
                params: chip.params,
                locale: .deviceLanguage
            )
            return await Self.parseHome(json, chipMode: true)
        } catch {
            return nil
        }
    }

    private func applyChipPage(_ page: HomePage, chip: HomePage.Chip) {
        // Para el informe: que secciones trae YouTube para este chip.
        let summary = page.sections
            .map { "\($0.title.isEmpty ? "-" : $0.title)(\($0.items.count))" }
            .joined(separator: ", ")
        PlaybackReport.record("chip \(chip.title): \(summary)")
        homePage?.sections = page.sections
        // The filtered feed carries its own continuation; reusing
        // the unfiltered one would page wrong sections in below.
        homePage?.continuation = page.continuation
        isChipLoading = false
        mergeSections(stable: false)
    }

    /// Si el chip no se puede cargar, se vuelve a la portada normal.
    private func restoreAfterChipFailure() {
        homePage = previousHomePage
        previousHomePage = nil
        selectedChip = nil
        isChipLoading = false
        mergeSections(stable: false)
    }

    func loadMoreIfNeeded(currentIndex: Int, total: Int) {
        guard total - currentIndex <= 3,
              let continuation = homePage?.continuation,
              !isLoadingMore else { return }
        isLoadingMore = true
        Task {
            defer { isLoadingMore = false }
            do {
                let json = try await InnerTubeClient.tropShared.browse(
                    continuation: continuation,
                    locale: selectedChip != nil ? YouTubeLocale.deviceLanguage : nil
                )
                if let (newSections, newContinuation) = await Self.parseContinuation(json) {
                    homePage?.sections.append(contentsOf: newSections)
                    homePage?.continuation = newContinuation
                    mergeSections()
                }
            } catch {
                Log.homeViewModel.error("Continuation error: \(error)")
            }
        }
    }

    // El JSON de la portada es grande: se interpreta fuera del hilo principal para no frenar el desplazamiento.
    nonisolated private static func parseHome(_ json: [String: Any], chipMode: Bool = false) async -> HomePage? {
        await Task.detached(priority: .userInitiated) {
            HomePageParser.parseHomePage(from: json, chipMode: chipMode)
        }.value
    }

    nonisolated private static func parseContinuation(
        _ json: [String: Any]
    ) async -> (sections: [HomePage.Section], continuation: String?)? {
        await Task.detached(priority: .userInitiated) {
            HomePageParser.parseContinuationSections(from: json)
        }.value
    }

    // MARK: - Section Management

    /// `stable: true` (por defecto): una vez mostrada la portada, lo que ya se ve conserva su orden y su
    /// contenido, y lo que llega despues (secciones de segundo plano, paginas siguientes) se anade al
    /// final. Asi nada salta ni cambia mientras se desliza. Se pone a `false` cuando el cambio es
    /// intencionado (filtros, chips, cerrar sesion).
    private func mergeSections(stable: Bool = true, freshContent: Bool = false) {
        if selectedChip != nil {
            // Con un chip elegido se muestra lo que YouTube devuelve para ese chip, en su orden y con el mismo aspecto que en
            // la portada normal (sus Selecciones rapidas, su Acceso rapido...), no las secciones propias de la app.
            var seenIds = Set<String>()
            homeSections = (homePage?.sections ?? []).enumerated().compactMap { index, section in
                let filtered = applyFilters(mapServerSection(section, index: index))
                // Dos secciones del servidor pueden caer en la misma (p. ej. dos "Acceso rapido"): una sola.
                guard !filtered.items.isEmpty, seenIds.insert(filtered.id).inserted else { return nil }
                return filtered
            }
            return
        }
        if holdMerges { return }
        let serverSections = homePage?.sections.enumerated().map { mapServerSection($1, index: $0) } ?? []
        let all = cachedLocalSections + serverSections + cachedPhase2Sections
        let merged = orderSections(all)
        homeSections = stable ? stabilized(merged, freshContent: freshContent) : merged
        let ids = homeSections.map(\.id)
        if ids != lastPublishedIds {
            lastPublishedIds = ids
            PlaybackReport.record("inicio: lista publicada a los \(LaunchClock.ms()) ms (\(ids.count) secciones)")
        }
    }

    /// `freshContent`: lo que ya se ve conserva su sitio pero toma el contenido nuevo (tras recargar o al terminar
    /// la carga en segundo plano). Sin eso, conserva tambien el contenido.
    private func stabilized(_ fresh: [HomeSection], freshContent: Bool = false) -> [HomeSection] {
        guard !isLoading, !homeSections.isEmpty else { return fresh }
        var freshById: [String: HomeSection] = [:]
        for section in fresh where freshById[section.id] == nil { freshById[section.id] = section }
        let kept = homeSections.compactMap { old -> HomeSection? in
            guard let new = freshById[old.id] else { return nil }
            return freshContent ? new : old
        }
        let keptIds = Set(kept.map(\.id))
        return kept + fresh.filter { !keptIds.contains($0.id) }
    }

    private func mapServerSection(_ section: HomePage.Section, index: Int) -> HomeSection {
        // Sin mayusculas ni acentos, y en español o en ingles (con un chip YouTube manda los titulos en el idioma del movil).
        let title = section.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if title.contains("quick pick") || title.contains("selecciones rapidas") {
            if !SettingsStore.shared.showQuickPicks {
                return .quickPicks(items: [])
            }
            return .quickPicks(items: section.items)
        }
        if title.contains("listen again") || title.contains("keep listening") || title.contains("volver a escuchar")
            || title.contains("vuelve a escuchar")
            || title.contains("acceso rapido") || title.contains("speed dial") || title.contains("quick access") {
            return .keepListening(items: section.items)
        }
        if title.contains("forgotten") || title.contains("favorite") || title.contains("favoritos olvidados") {
            return .forgottenFavorites(items: section.items)
        }
        return .homePageSection(section, index: index)
    }

    private func orderSections(_ sections: [HomeSection]) -> [HomeSection] {
        let filtered = sections.compactMap { section -> HomeSection? in
            let f = applyFilters(section)
            if case .quickPicks = f { return f }
            return f.items.isEmpty ? nil : f
        }

        var byId: [String: HomeSection] = [:]
        for section in filtered {
            if let existing = byId[section.id] {
                if section.items.count > existing.items.count {
                    byId[section.id] = section
                }
            } else {
                byId[section.id] = section
            }
        }

        return byId.values.sorted { a, b in
            sectionWeight(a) > sectionWeight(b)
        }
    }

    private func applyFilters(_ section: HomeSection) -> HomeSection {
        let disliked = LikeStore.shared.disliked
        let filteredItems = section.items.filter { item in
            if case .song(let s) = item, disliked.contains(s.videoId) { return false }
            if HiddenArtists.shared.blocks(item) { return false }
            if hideExplicit {
                switch item {
                case .song(let s) where s.isExplicit: return false
                case .album(let a) where a.isExplicit: return false
                default: break
                }
            }
            return true
        }

        switch section {
        case .quickPicks: return .quickPicks(items: filteredItems)
        case .keepListening: return .keepListening(items: filteredItems)
        case .forgottenFavorites: return .forgottenFavorites(items: filteredItems)
        case .homePageSection(let sectionData, let index):
            let filteredSectionItems = sectionData.items.filter { item in
                if case .song(let s) = item, disliked.contains(s.videoId) { return false }
                if HiddenArtists.shared.blocks(item) { return false }
                if hideExplicit {
                    switch item {
                    case .song(let s) where s.isExplicit: return false
                    case .album(let a) where a.isExplicit: return false
                    default: break
                    }
                }
                return true
            }
            var newSection = sectionData
            newSection.items = filteredSectionItems
            return .homePageSection(newSection, index: index)
        case .accountPlaylists: return .accountPlaylists(items: filteredItems)
        case .similarRecommendation(_, let t): return .similarRecommendation(items: filteredItems, title: t)
        case .dailyDiscover: return .dailyDiscover(items: filteredItems)
        case .fromTheCommunity: return .fromTheCommunity(items: filteredItems)
        case .speedDial: return .speedDial(items: filteredItems)
        case .moodAndGenres: return .moodAndGenres(items: filteredItems)
        }
    }

    private func sectionWeight(_ section: HomeSection) -> Int {
        switch section {
        case .quickPicks: return 100
        case .keepListening: return 80
        case .forgottenFavorites: return 60
        case .homePageSection(_, let index): return 40 - index
        case .dailyDiscover: return 50
        case .similarRecommendation: return 35
        case .accountPlaylists: return 30
        case .fromTheCommunity: return 25
        case .speedDial: return 20
        case .moodAndGenres: return 15
        }
    }
}

private final class HomeViewModelCleanup: @unchecked Sendable {
    var chipTask: Task<Void, Never>?
    var notificationObserver: NSObjectProtocol?
}
