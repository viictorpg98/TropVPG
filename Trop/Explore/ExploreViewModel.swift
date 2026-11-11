//
// ExploreViewModel.swift
// Trop
//
// Created by 686udjie on 11/09/2026.
//

import Foundation
import SwiftUI

/// Drives the Explore tab (`FEmusic_explore`): new releases, charts,
/// moods & genres.
@MainActor
@Observable
final class ExploreViewModel {

    enum Phase {
        case idle
        case loading
        case loaded
        case empty
        case failed
    }

    private(set) var phase: Phase = .idle
    private(set) var sections: [ExploreSection] = []
    private(set) var error: Error?

    private var hasLoaded = false

    // MARK: - Loading

    func load() {
        guard !hasLoaded else { return }
        Task { await fetch() }
    }

    func refresh() async {
        await fetch()
    }

    private func fetch() async {
        // Al recargar (ya hay secciones) la fase no cambia: si cambiara, la pantalla se reconstruiria y se cortaria
        // la animacion de tirar hacia abajo.
        let isRefresh = !sections.isEmpty
        let started = Date()
        defer { DiagLog.event("carga", "explorar: \(isRefresh ? "recarga" : "primera carga") en \(Int(Date().timeIntervalSince(started) * 1000)) ms", important: true) }
        if !isRefresh { phase = .loading }
        error = nil
        let region = SettingsStore.shared.contentCountry
        Log.explore.debug("Explore fetch start browseId=\(HomePageParser.exploreBrowseId)")
        // La lista de tendencias del pais se pide a la vez que la pagina (antes iba despues, una peticion tras otra).
        let trendingTask = Task { await fetchRegionalTrending(region: region) }
        do {
            let json = try await InnerTubeClient.tropShared.browse(
                browseId: HomePageParser.exploreBrowseId,
                formData: ["selectedValues": [region]]
            )
            Log.explore.debug("Explore fetch ok topKeys=\((json.keys.sorted()))")
            var parsed = HomePageParser.parseExploreSections(from: json)
            if let trending = await trendingTask.value,
               let index = parsed.firstIndex(where: { $0.title.lowercased().contains("trending") }) {
                parsed[index].items = trending.map(YTItem.song)
                parsed[index].kind = .rows
            }
            let moodCount = parsed.reduce(0) { $0 + $1.moods.count }
            Log.explore.debug(
                "Explore loaded: " +
                parsed.map { "\($0.title)(\($0.kind)):\($0.items.count)" }.joined(separator: ", ") +
                " moods=\(moodCount)"
            )
            if parsed.isEmpty, isRefresh {
                // Si al recargar no llega nada, se deja lo que habia.
                phase = .loaded
                return
            }
            sections = parsed
            phase = sections.isEmpty ? .empty : .loaded
            hasLoaded = phase == .loaded
        } catch {
            trendingTask.cancel()
            Log.explore.error("Explore fetch failed: \(error)")
            if isRefresh {
                phase = .loaded
                return
            }
            self.error = error
            phase = .failed
        }
    }

    /// The Trending shelf is swapped for the region's chart tracks. The explore
    /// carousel follows the IP/account region, which the region setting
    /// cannot move — but per-country charts can, via the country selector.
    /// Nil on any failure (explore's own items are then kept).
    private func fetchRegionalTrending(region: String) async -> [SongItem]? {
        guard let playlistId = try? await RegionalCharts.trendingPlaylistId(country: region, using: InnerTubeClient.tropShared),
              let (_, rows) = try? await SyncBridge.playlistDetail.fetchPlaylistRows(playlistId: playlistId) else { return nil }
        let songs = rows.compactMap { item -> SongItem? in
            guard let renderer = item["musicResponsiveListItemRenderer"] as? [String: Any] else { return nil }
            return SongItem.from(renderer)
        }
        return songs.isEmpty ? nil : songs
    }

    // MARK: - Paginas de los botones (Novedades, Listas de exitos, Animo y generos)

    static func loadBrowseDetail(browseId: String, params: String?) async -> [ExploreSection] {
        do {
            let json = try await InnerTubeClient.tropShared.browse(browseId: browseId, params: params)
            return HomePageParser.parseExploreSections(from: json)
        } catch {
            Log.explore.error("Explore page \(browseId) failed: \(error)")
            return []
        }
    }

    // MARK: - Moods

    /// Full category page (songs, playlists, videos, albums shelves).
    static func loadMoodDetail(_ mood: MoodItem) async -> [ExploreSection] {
        Log.explore.debug("Explore mood '\(mood.title)' fetch params=\(mood.params ?? "none")")
        do {
            let json = try await InnerTubeClient.tropShared.browse(
                browseId: HomePageParser.moodsCategoryBrowseId,
                params: mood.params
            )
            let sections = HomePageParser.parseExploreSections(from: json)
            Log.explore.debug(
                "Explore mood '\(mood.title)': " +
                sections.map { "\($0.title)(\($0.kind)):\($0.items.count)" }.joined(separator: ", ")
            )
            return sections
        } catch {
            Log.explore.error("Explore mood '\(mood.title)' failed: \(error)")
            return []
        }
    }

}
