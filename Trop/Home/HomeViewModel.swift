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
        Task { await load() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        cachedLocalSections = []
        cachedPhase2Sections = []
        await load()
        isRefreshing = false
    }

    func restoreSession() async {
        let loggedIn = await cookieStore.isLoggedIn()
        isLoggedIn = loggedIn
        guard loggedIn else { return }
        await InnerTubeClient.tropShared.loadState(from: cookieStore)
    }

    func handleSessionChange(loggedIn: Bool) {
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
        error = nil
        homeFetchFailure = nil

        async let localTask: Void = storeLocalSections()
        _ = await localTask
        guard generation == loadGeneration else { return }
        await personalization.drainEnrichments()

        async let phase2Work: Void = loadPhase2Sections()

        await fetchHomePage(generation: generation)
        guard generation == loadGeneration else {
            await phase2Work
            return
        }
        await ensureQuickPicksAvailable(generation: generation)
        guard generation == loadGeneration else {
            await phase2Work
            return
        }
        await phase2Work

        guard generation == loadGeneration else { return }
        // El error solo se enseña si no hay nada que ensenar: ni portada guardada ni secciones propias.
        if homePage == nil, let failure = homeFetchFailure, cachedLocalSections.isEmpty, cachedPhase2Sections.isEmpty {
            error = failure
        }
        homeFetchFailure = nil
        mergeSections()
        isLoading = false
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

        mergeSections()
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
        cleanup.chipTask = Task {
            do {
                // En el idioma del dispositivo: asi los titulos de podcasts no llegan traducidos al ingles.
                let json = try await InnerTubeClient.tropShared.browse(
                    browseId: "FEmusic_home",
                    params: chip?.params,
                    locale: .deviceLanguage
                )
                guard !Task.isCancelled, generation == loadGeneration else { return }
                if let page = await Self.parseHome(json) {
                    homePage?.sections = page.sections
                    // The filtered feed carries its own continuation; reusing
                    // the unfiltered one would page wrong sections in below.
                    homePage?.continuation = page.continuation
                    isChipLoading = false
                    mergeSections(stable: false)
                } else {
                    restoreAfterChipFailure()
                }
            } catch {
                guard !Task.isCancelled else { return }
                guard generation == loadGeneration else { return }
                restoreAfterChipFailure()
            }
        }
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
    nonisolated private static func parseHome(_ json: [String: Any]) async -> HomePage? {
        await Task.detached(priority: .userInitiated) {
            HomePageParser.parseHomePage(from: json)
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
    private func mergeSections(stable: Bool = true) {
        if selectedChip != nil {
            // Con un chip elegido solo se muestra lo que YouTube devuelve para ese chip, en su orden:
            // nada de Acceso rapido, Volver a escuchar ni las secciones propias de la app.
            homeSections = (homePage?.sections ?? []).enumerated().compactMap { index, section in
                let filtered = applyFilters(.homePageSection(section, index: index))
                return filtered.items.isEmpty ? nil : filtered
            }
            return
        }
        let serverSections = homePage?.sections.enumerated().map { mapServerSection($1, index: $0) } ?? []
        let all = cachedLocalSections + serverSections + cachedPhase2Sections
        let merged = orderSections(all)
        homeSections = stable ? stabilized(merged) : merged
    }

    private func stabilized(_ fresh: [HomeSection]) -> [HomeSection] {
        guard !isLoading, !homeSections.isEmpty else { return fresh }
        let freshIds = Set(fresh.map(\.id))
        let kept = homeSections.filter { freshIds.contains($0.id) }
        let keptIds = Set(kept.map(\.id))
        return kept + fresh.filter { !keptIds.contains($0.id) }
    }

    private func mapServerSection(_ section: HomePage.Section, index: Int) -> HomeSection {
        let title = section.title.lowercased()
        if title == "quick picks" || title.contains("quick pick") {
            if !SettingsStore.shared.showQuickPicks {
                return .quickPicks(items: [])
            }
            return .quickPicks(items: section.items)
        }
        if title.contains("listen again") || title.contains("keep listening") {
            return .keepListening(items: section.items)
        }
        if title.contains("forgotten") || title.contains("favorite") {
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
