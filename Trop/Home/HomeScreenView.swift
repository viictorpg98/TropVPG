//
//  HomeScreenView.swift
//  Trop
//
//  Created by 686udjie on 01/07/2026.
//

import SwiftUI

struct HomeScreenView: View {
    @Environment(SettingsStore.self) private var settings
    @ObservedObject private var router = AppRouter.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var network = NetworkMonitor.shared
    @State private var viewModel = HomeViewModel()
    private let accountState = AccountSheetState.shared

    @State private var pendingRoute: DetailRoute?
    @State private var speedDialEntries: [SpeedDialEntry] = []

    var body: some View {
        NavigationStack(path: $router.homePath) {
            VStack(spacing: 0) {
                TabHeaderView(
                    title: "Home",
                    accountIsLoggedIn: accountState.isLoggedIn,
                    accountImageUrl: accountState.accountImageUrl,
                    onHistory: { router.homePath.append(DetailRoute.history) },
                    onAccount: { router.homePath.append(DetailRoute.settings) }
                )

                // El logo solo la primera vez: al recargar tirando hacia abajo la lista se queda (si se quitara, la recarga se
                // cancelaria y saldria "sin conexion").
                if viewModel.isLoading, viewModel.homeSections.isEmpty {
                    Spacer()
                    SonarLoader(size: 64)
                    Spacer()
                } else if let error = viewModel.error {
                    errorView(error)
                } else {
                    homescreenContent
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .toolbar(.hidden, for: .navigationBar)
            .detailRouteDestinations()
            .onChange(of: pendingRoute) { _, route in
                if let route {
                    router.homePath.append(route)
                    pendingRoute = nil
                }
            }
            .onChange(of: accountState.isLoggedIn) { _, loggedIn in
                viewModel.handleSessionChange(loggedIn: loggedIn)
            }
            // Al salir de la app los chips (Podcasts, Dormir...) se desmarcan: al volver se ve la portada normal.
            .onChange(of: scenePhase) { _, phase in
                if phase == .background, viewModel.selectedChip != nil {
                    viewModel.toggleChip(nil)
                }
            }
            // Si la portada fallo por falta de conexion, se recarga sola al volver.
            .onChange(of: network.isOnline) { _, online in
                if online, viewModel.error != nil || viewModel.isShowingCachedHome {
                    Task { await viewModel.refresh() }
                }
            }
            .task {
                await viewModel.restoreSession()
                await accountState.restoreSession()
                await accountState.fetchAccountInfo()
                viewModel.loadHomeData()
                await reloadSpeedDial()
                // Trigger library sync in background
                Task {
                    await SyncBridge.checkAndSyncIfStale()
                }
            }
            .task(id: viewModel.homeSections.count) {
                let urls = viewModel.homeSections
                    .flatMap(\.items)
                    .compactMap(\.thumbnailUrl)
                    .compactMap(URL.init)
                await ImagePreloader.shared.preload(urls)
            }
        }
    }

    private var homescreenContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if viewModel.isShowingCachedHome, let date = viewModel.cachedHomeDate {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.slash")
                        Text(String(
                            format: NSLocalizedString("Offline: showing what was last saved (%@)", comment: ""),
                            date.formatted(date: .abbreviated, time: .shortened)
                        ))
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let chips = viewModel.homePage?.chips, !chips.isEmpty {
                    ChipsRowView(
                        chips: chips,
                        selectedChip: viewModel.selectedChip,
                        onChipTap: { viewModel.toggleChip($0) }
                    )
                }

                if viewModel.isChipLoading {
                    chipLoadingPlaceholder
                } else {
                    // Se recorre una copia de las secciones (no se indexa el array en vivo): si la lista
                    // cambia de tamano mientras se pintan las filas no se sale de rango.
                    ForEach(Array(viewModel.homeSections.enumerated()), id: \.offset) { _, section in
                        sectionView(for: section)
                    }
                }

                GeometryReader { _ in
                    Color.clear
                        .onAppear {
                            let total = viewModel.homeSections.count
                            if total > 0 {
                                viewModel.loadMoreIfNeeded(
                                    currentIndex: total - 1,
                                    total: total
                                )
                            }
                        }
                }
                .frame(height: 1)
            }
        }
        .scrollIndicators(.automatic)
        .miniPlayerTracksScroll()
        .sonarRefreshable {
            await viewModel.refresh()
            await reloadSpeedDial()
            // La sincronizacion de la biblioteca sigue en segundo plano: no se espera.
            Task { await SyncBridge.checkAndSyncIfStale() }
        }
        .onChange(of: settings.hideExplicit) { _, _ in
            viewModel.syncSettings()
        }
        .onChange(of: settings.showQuickPicks) { _, _ in
            viewModel.syncSettings()
            Task { await viewModel.refresh() }
        }
        .onChange(of: settings.topListsLength) { _, _ in
            Task { await viewModel.refresh() }
        }
        .onChange(of: settings.contentCountry) { _, _ in
            Task { await viewModel.refresh() }
        }
    }

    /// Mientras llega la portada del chip: el logo animado, sin esqueletos.
    private var chipLoadingPlaceholder: some View {
        SonarLoader(size: 56)
            .frame(maxWidth: .infinity)
            .padding(.top, 90)
            .padding(.bottom, 220)
    }

    @ViewBuilder
    private func sectionView(for section: HomeSection) -> some View {
        switch section {
        case .quickPicks:
            quickPicksSection(section)
        case .keepListening:
            speedDialSection(section)
        case .forgottenFavorites:
            songsSection(section)
        case .homePageSection(let sectionData, _):
            if sectionData.isSongsOnly {
                songsSection(section)
            } else {
                mixedSection(section)
            }
        default:
            mixedSection(section)
        }
    }

    @ViewBuilder
    private func quickPicksSection(_ section: HomeSection) -> some View {
        let pinnedSongs = speedDialEntries.map { $0.toSongItem() }
        let pinnedIds = Set(speedDialEntries.map(\.videoId))
        let visibleItems = section.items.filter { item in
            if case .song(let s) = item { return !pinnedIds.contains(s.videoId) }
            return true
        }
        let quickSongs = visibleItems.compactMap { if case .song(let s) = $0 { return s } else { return nil } }
        let combinedQueue = pinnedSongs + quickSongs

        if combinedQueue.isEmpty {
            EmptyView()
        } else {
            HorizontalSection(title: section.displayTitle, vSpacing: 8, contentVerticalPadding: 0, snapsToColumns: true) {
                SongColumnsGrid {
                    ForEach(speedDialEntries, id: \.videoId) { entry in
                        let song = entry.toSongItem()
                        YouTubeListItemView(
                            item: .song(song),
                            onTap: { handleSongTap(song, in: combinedQueue) },
                            onNavigate: { pendingRoute = $0 }, detailed: true
                        )
                        .songColumnWidth()
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(settings.accentColor)
                                .padding(6)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task {
                                    try? await DatabaseService.shared.removeFromSpeedDial(videoId: entry.videoId)
                                    await reloadSpeedDial()
                                }
                            } label: {
                                Label("Unpin", systemImage: "pin.slash")
                            }
                        }
                    }

                    ForEach(visibleItems.indices, id: \.self) { i in
                        let item = visibleItems[i]
                        if case .song(let s) = item {
                            YouTubeListItemView(
                                item: item,
                                onTap: { handleSongTap(s, in: combinedQueue) },
                                onNavigate: { pendingRoute = $0 }, detailed: true
                            )
                                .songColumnWidth()
                        } else {
                            YouTubeListItemView(item: item, onTap: { handleItemTap(item) }, onNavigate: { pendingRoute = $0 }, detailed: true)
                                .songColumnWidth()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func speedDialSection(_ section: HomeSection) -> some View {
        let items = Array(section.items.prefix(27))
        let queue = items.compactMap { item -> SongItem? in
            if case .song(let s) = item { return s } else { return nil }
        }
        if items.isEmpty {
            EmptyView()
        } else {
            SpeedDialSectionView(
                items: items,
                onTap: { item in
                    if case .song(let s) = item {
                        handleSongTap(s, in: queue)
                    } else {
                        handleItemTap(item)
                    }
                },
                onDice: { playRandomPick() },
                onNavigate: { pendingRoute = $0 }
            )
        }
    }

    /// El dado: elige una canción al azar entre todo lo que hay en el inicio y arranca su radio.
    private func playRandomPick() {
        var songs: [SongItem] = []
        var seen = Set<String>()
        for section in viewModel.homeSections {
            for item in section.items {
                if case .song(let s) = item, seen.insert(s.videoId).inserted {
                    songs.append(s)
                }
            }
        }
        for entry in speedDialEntries {
            let song = entry.toSongItem()
            if seen.insert(song.videoId).inserted {
                songs.append(song)
            }
        }
        if let pick = songs.randomElement() {
            PlaybackQueue.playSingleWithRadio(pick, log: Log.homeScreenView)
        }
    }

    private func songsSection(_ section: HomeSection) -> some View {
        let queue = section.items.compactMap { if case .song(let s) = $0 { return s } else { return nil } }
        return HorizontalSection(title: section.displayTitle, vSpacing: 8, contentVerticalPadding: 0, snapsToColumns: true, onTitleTap: titleAction(for: section)) {
            SongColumnsGrid {
                ForEach(section.items.indices, id: \.self) { i in
                    let item = section.items[i]
                    if case .song(let s) = item {
                        YouTubeListItemView(item: item, onTap: { handleSongTap(s, in: queue) }, onNavigate: { pendingRoute = $0 }, detailed: true)
                            .songColumnWidth()
                    } else {
                        YouTubeListItemView(item: item, onTap: { handleItemTap(item) }, onNavigate: { pendingRoute = $0 }, detailed: true)
                            .songColumnWidth()
                    }
                }
            }
        }
    }

    private func mixedSection(_ section: HomeSection) -> some View {
        let queue = section.items.compactMap { if case .song(let s) = $0 { return s } else { return nil } }
        return HorizontalSection(title: section.displayTitle, vSpacing: 8, contentVerticalPadding: 0, onTitleTap: titleAction(for: section)) {
            HStack(spacing: 12) {
                ForEach(section.items.indices, id: \.self) { i in
                    let item = section.items[i]
                    if case .song(let s) = item, !queue.isEmpty {
                        YouTubeGridItemView(item: item, onTap: { handleSongTap(s, in: queue) }, onNavigate: { pendingRoute = $0 })
                    } else {
                        YouTubeGridItemView(item: item, onTap: { handleItemTap(item) }, onNavigate: { pendingRoute = $0 })
                    }
                }
            }
        }.padding(.top, 8)
    }

    // MARK: - Quick Picks (pinned)

    private func reloadSpeedDial() async {
        speedDialEntries = (try? await DatabaseService.shared.fetchSpeedDial()) ?? []
    }

    // MARK: - Flecha de las secciones

    private enum SectionDestination {
        case detail(DetailRoute)
        case libraryPodcasts
    }

    /// La flecha junto al titulo ("Tus nuevos episodios >", "Tus programas >"): solo si se sabe a donde llevar.
    private func titleAction(for section: HomeSection) -> (() -> Void)? {
        guard case .homePageSection(let data, _) = section, let destination = sectionDestination(for: data) else { return nil }
        return {
            switch destination {
            case .detail(let route):
                router.homePath.append(route)
            case .libraryPodcasts:
                router.libraryFilterRequest = "podcasts"
                router.tabRequest = 1
            }
        }
    }

    private func sectionDestination(for data: HomePage.Section) -> SectionDestination? {
        // Por nombre, porque el boton "mas" de estas secciones puede apuntar a una pagina que la app no tiene.
        let title = data.title.lowercased()
        if title.contains("nuevos episodios") || title.contains("new episodes") {
            return .detail(.playlist(playlistId: "VLRDPN"))
        }
        if title.contains("más tarde") || title.contains("for later") {
            return .detail(.playlist(playlistId: "VLSE"))
        }
        if title.contains("tus programas") || title.contains("your shows") {
            return .libraryPodcasts
        }
        guard let id = data.moreBrowseId else { return nil }
        if id == "FEmusic_library_non_music_audio_list" { return .libraryPodcasts }
        if id.hasPrefix("VL") { return .detail(.playlist(playlistId: id)) }
        if id.hasPrefix("MPSP") { return .detail(.podcast(browseId: id)) }
        if id.hasPrefix("MPRE") { return .detail(.album(browseId: id)) }
        if id.hasPrefix("UC") { return .detail(.artist(browseId: id)) }
        return nil
    }

    private func handleSongTap(_ song: SongItem, in queue: [SongItem]) {
        Log.homeScreenView.debug("Tapped song in queue: \(song.title) queueCount=\(queue.count)")
        PlaybackQueue.playSingleWithRadio(song, log: Log.homeScreenView)
    }

    private func handleItemTap(_ item: YTItem) {
        Log.homeScreenView.debug("Tapped item: \(item.title) type=\(typeName(item))")
        YTItemRouter.route(
            item,
            playSong: { PlaybackQueue.playSingleWithRadio($0, log: Log.homeScreenView) },
            appendRoute: { router.homePath.append($0) }
        )
    }

    private func typeName(_ item: YTItem) -> String {
        switch item {
        case .song: return "song"
        case .album: return "album"
        case .artist: return "artist"
        case .playlist: return "playlist"
        case .podcast: return "podcast"
        case .episode: return "episode"
        }
    }

    private func errorView(_ error: Error) -> some View {
        ContentUnavailableView {
            Label(
                LocalizedStringKey(network.isOnline ? "Couldn't load your homescreen" : "Offline"),
                systemImage: "wifi.slash"
            )
        } description: {
            if network.isOnline {
                Text(verbatim: error.localizedDescription)
            } else {
                Text("Only your downloaded music is available.")
            }
        } actions: {
            Button("Retry") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.bordered)
            Button("Go to Downloads") {
                AppRouter.shared.openDownloads()
            }
            .buttonStyle(.borderedProminent)
            .tint(settings.accentColor)
        }
    }
}

#Preview {
    HomeScreenView()
}
