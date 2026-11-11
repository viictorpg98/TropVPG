//
//  SearchView.swift
//  Trop
//
//  Created by 686udjie on 03/07/2026.
//

import SwiftUI

struct SearchView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var viewModel = SearchViewModel()
    @ObservedObject private var router = AppRouter.shared
    @FocusState private var fieldFocused: Bool

    @State private var pendingRoute: DetailRoute?
    @State private var suggestions = SearchSuggestionsModel()

    var body: some View {
        NavigationStack(path: $router.searchPath) {
            VStack(spacing: 0) {
                searchTopBar

                content
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .toolbar(.hidden, for: .navigationBar)
            .detailRouteDestinations()
            .diagScreen("Buscar")
            .onChange(of: pendingRoute) { _, route in
                if let route {
                    router.searchPath.append(route)
                    pendingRoute = nil
                }
            }
            .onAppear {
                viewModel.loadSearchHistory()
                focusIfSearchTab()
            }
            .onChange(of: router.selectedTabIndex) { _, _ in
                focusIfSearchTab()
            }
            .onChange(of: viewModel.fieldText) { _, text in
                suggestions.update(for: text)
            }
            .task(id: viewModel.results.count) {
                let urls = viewModel.results
                    .flatMap(\.items)
                    .compactMap(\.thumbnailUrl)
                    .compactMap(URL.init)
                await ImagePreloader.shared.preload(urls)
            }
        }
    }

    // MARK: - Top bar

    /// Search field + sort menu pinned above the filter chips.
    private var searchTopBar: some View {
        HStack(spacing: 10) {
            Button {
                fieldFocused = false
                router.leaveSearch()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(.systemGray5).opacity(0.6)))
            }
            .accessibilityLabel("Back")

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $viewModel.fieldText)
                    .focused($fieldFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit { submit(nil) }
                if !viewModel.fieldText.isEmpty {
                    Button {
                        viewModel.fieldText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Color(.systemGray5).opacity(0.6))
            )

            sortMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SearchSort.allCases, id: \.self) { option in
                Button {
                    viewModel.sort = option
                } label: {
                    if viewModel.sort == option {
                        Label(LocalizedStringKey(option.title), systemImage: "checkmark")
                    } else {
                        Text(LocalizedStringKey(option.title))
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(.systemGray5).opacity(0.6)))
        }
        .accessibilityLabel("Sort results")
    }

    /// Focuses the field (raising the keyboard) whenever the Search tab
    /// becomes active.
    private func focusIfSearchTab() {
        if AppRouter.shared.selectedTabIndex == 3 {
            fieldFocused = true
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            if !viewModel.fieldText.trimmingCharacters(in: .whitespaces).isEmpty {
                suggestionsView
            } else if viewModel.searchHistory.isEmpty {
                noRecentSearchesView
            } else {
                searchHistoryView
            }
        case .loading:
            loadingView
        case .results:
            searchResultsList
        case .noResults:
            noResultsView
        case .failed:
            errorView(viewModel.error)
        }
    }

    private var loadingView: some View {
        VStack {
            Spacer()
            SonarLoader(size: 64)
            Spacer()
        }
    }

    // MARK: - Submission

    private func submit(_ text: String? = nil) {
        if let text {
            viewModel.fieldText = text
        }
        fieldFocused = false
        viewModel.submit()
    }

    /// Mientras se escribe: la mejor cancion, tus busquedas recientes que coinciden y las sugerencias de YouTube Music.
    private var suggestionsView: some View {
        let typed = viewModel.fieldText.trimmingCharacters(in: .whitespaces)
        let lowered = typed.lowercased()
        let history = Array(
            viewModel.searchHistory.map(\.query)
                .filter { $0.lowercased().contains(lowered) && $0.lowercased() != lowered }
                .prefix(3)
        )
        let remote = suggestions.items.filter { candidate in
            !history.contains(candidate) && candidate.lowercased() != lowered
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let song = suggestions.topSong {
                    Text("Top result")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    SongRowView(
                        song: song,
                        onTap: {
                            fieldFocused = false
                            PlaybackQueue.playSingleWithRadio(song, log: Log.searchView)
                        },
                        onNavigate: { pendingRoute = $0 }
                    )
                    .padding(.horizontal, 16)
                    Divider().padding(.leading, 16)
                }
                ForEach(history, id: \.self) { suggestionRow($0, icon: "clock.arrow.trianglehead.counterclockwise.rotate.90") }
                ForEach(remote, id: \.self) { suggestionRow($0, icon: "magnifyingglass") }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .miniPlayerTracksScroll()
    }

    private func suggestionRow(_ text: String, icon: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    submit(text)
                } label: {
                    HStack {
                        Image(systemName: icon)
                            .foregroundColor(settings.accentColor)
                            .frame(width: 24)
                        Text(text)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.leading, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                // Pasa la frase al campo sin buscar, para seguir escribiendo a partir de ella.
                Button {
                    viewModel.fieldText = text + " "
                } label: {
                    Image(systemName: "arrow.up.left")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use suggestion")
            }
            Divider().padding(.leading, 16)
        }
    }

    private var searchHistoryView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recently searched")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Button("Clear") {
                        viewModel.clearSearchHistory()
                    }
                    .font(.subheadline)
                    .foregroundColor(settings.accentColor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                ForEach(viewModel.searchHistory, id: \.query) { entry in
                    Button {
                        submit(entry.query)
                    } label: {
                        HStack {
                            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                                .foregroundColor(settings.accentColor)
                            Text(entry.query)
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .contextMenu {
                        Button(role: .destructive) {
                            viewModel.deleteSearchHistoryEntry(entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }

                    Divider()
                        .padding(.leading, 16)
                }
            }
        }
        .scrollIndicators(.automatic)
        .miniPlayerTracksScroll()
    }

    private var searchResultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !viewModel.availableFilters.isEmpty {
                    filterChips
                }

                if let hero = viewModel.heroArtist {
                    artistHeroCard(hero, songs: viewModel.heroSongs)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                ForEach(viewModel.filteredResults) { section in
                    sectionHeader(section.title)

                    switch section.title {
                    case "Artists":
                        artistCarousel(items: section.items)
                    case "Albums":
                        albumCarousel(items: section.items)
                    default:
                        ForEach(section.items, id: \.id) { item in
                            YouTubeListItemView(item: item, onTap: {
                                handleItemTap(item)
                            }, onNavigate: { pendingRoute = $0 })
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.automatic)
        .miniPlayerTracksScroll()
    }

    /// Section title with chevron — taps drill into (or clear) the filter.
    private func sectionHeader(_ title: String) -> some View {
        Button {
            if viewModel.selectedSectionFilter == title {
                viewModel.selectedSectionFilter = nil
            } else {
                viewModel.selectedSectionFilter = title
                viewModel.isShowingLibrary = false
            }
        } label: {
            HStack(spacing: 4) {
                Text(LocalizedStringKey(title))
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    /// Artist-first hero: big circular artwork + name, then top songs.
    private func artistHeroCard(_ artist: ArtistItem, songs: [SongItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                router.searchPath.append(DetailRoute.artist(browseId: artist.browseId))
            } label: {
                HStack(spacing: 12) {
                    AsyncImageView(url: artist.thumbnailUrl)
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                    Text(artist.name)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text("•••")
                        .font(.body.weight(.black))
                        .foregroundStyle(settings.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ForEach(songs, id: \.videoId) { song in
                let item = YTItem.song(song)
                YouTubeListItemView(item: item, onTap: {
                    handleItemTap(item)
                }, onNavigate: { pendingRoute = $0 })
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGray6))
        )
    }

    private func artistCarousel(items: [YTItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(items, id: \.id) { item in
                    if case .artist(let artist) = item {
                        VStack(spacing: 8) {
                            AsyncImageView(url: artist.thumbnailUrl)
                                .frame(width: 110, height: 110)
                                .clipShape(Circle())
                            Text(artist.name)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .frame(width: 110)
                        }
                        .accessibilityAddTraits(.isButton)
                        .pressableItem(item, onTap: {
                            router.searchPath.append(DetailRoute.artist(browseId: artist.browseId))
                        }, onNavigate: { pendingRoute = $0 })
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func albumCarousel(items: [YTItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(items, id: \.id) { item in
                    if case .album(let album) = item {
                        MediaGridCell(
                            thumbnailUrl: album.thumbnailUrl,
                            title: album.title,
                            subtitle: album.artists.map(\.name).joined(separator: ", "),
                            size: 140
                        )
                        .accessibilityAddTraits(.isButton)
                        .pressableItem(item, onTap: {
                            router.searchPath.append(DetailRoute.album(browseId: album.browseId))
                        }, onNavigate: { pendingRoute = $0 })
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private var filterChips: some View {
        FilterChipBar(
            items: ["All Results"] + viewModel.availableFilters,
            id: \.self,
            title: { $0 },
            isSelected: { filter in
                if filter == "All Results" {
                    return viewModel.selectedSectionFilter == nil && !viewModel.isShowingLibrary
                }
                return filter == "Library"
                    ? viewModel.isShowingLibrary
                    : viewModel.selectedSectionFilter == filter
            },
            onTap: { filter in
                if filter == "All Results" {
                    viewModel.selectedSectionFilter = nil
                    viewModel.isShowingLibrary = false
                } else if filter == "Library" {
                    let willShow = !viewModel.isShowingLibrary
                    viewModel.isShowingLibrary = willShow
                    viewModel.selectedSectionFilter = nil
                } else {
                    viewModel.selectedSectionFilter = filter
                    viewModel.isShowingLibrary = false
                }
            }
        )
    }

    private var noResultsView: some View {
        ContentUnavailableView(
            "No Results",
            systemImage: "magnifyingglass",
            description: Text("No results found for \"\(viewModel.submittedQuery)\"")
        )
    }

    private var noRecentSearchesView: some View {
        ContentUnavailableView(
            "No Recent Searches",
            systemImage: "magnifyingglass",
            description: Text("Your recent searches will appear here.")
        )
    }

    private func errorView(_ error: Error?) -> some View {
        ContentUnavailableView(
            "Search failed",
            systemImage: "exclamationmark.triangle",
            description: Text(error?.localizedDescription ?? "Something went wrong.")
        )
    }

    private func handleItemTap(_ item: YTItem) {
        YTItemRouter.route(
            item,
            playSong: { PlaybackQueue.playSingleWithRadio($0, log: Log.searchView) },
            appendRoute: { router.searchPath.append($0) }
        )
    }
}
