//
//  SonarMix.swift
//  Trop
//

import Foundation

/// "Pon música": empieza a sonar una mezcla de lo que le gusta a la persona, sin abrir pantallas.
/// Orden de preferencia:
/// 1. La primera lista de "Mezclado para ti" de YouTube Music (tu Supermix o similar).
/// 2. La radio de una canción cualquiera de tu inicio.
/// 3. Sin red: canciones que te gustan, guardadas en el dispositivo.
@MainActor
enum SonarMix {
    /// Devuelve `true` si ha empezado a sonar algo.
    static func start() async -> Bool {
        let cookieStore = CookieStore()
        if await cookieStore.isLoggedIn() {
            await InnerTubeClient.tropShared.loadState(from: cookieStore)
        }

        if let sections = await loadHomeSections() {
            if await playMixedForYou(in: sections) { return true }
            if playAnySong(in: sections) { return true }
        }
        return await playLikedSongs()
    }

    // MARK: - Inicio

    /// Las secciones del inicio de YouTube Music (la primera pagina y, si hace falta, las siguientes,
    /// porque "Mezclado para ti" suele venir mas abajo).
    private static func loadHomeSections() async -> [HomePage.Section]? {
        guard let json = try? await InnerTubeClient.tropShared.browse(browseId: "FEmusic_home"),
              let page = HomePageParser.parseHomePage(from: json) else { return nil }

        var sections = page.sections
        var continuation = page.continuation
        var attempts = 0
        while attempts < 4, mixedForYou(in: sections) == nil, let token = continuation {
            attempts += 1
            guard let json = try? await InnerTubeClient.tropShared.browse(continuation: token),
                  let (more, next) = HomePageParser.parseContinuationSections(from: json) else { break }
            sections.append(contentsOf: more)
            continuation = next
        }
        return sections
    }

    private static func mixedForYou(in sections: [HomePage.Section]) -> HomePage.Section? {
        sections.first { $0.title.lowercased().contains("mixed for you") }
    }

    // MARK: - 1) Mezclado para ti

    private static func playMixedForYou(in sections: [HomePage.Section]) async -> Bool {
        guard let section = mixedForYou(in: sections) else { return false }
        let playlists = section.items.compactMap { item -> PlaylistItem? in
            if case .playlist(let playlist) = item { return playlist }
            return nil
        }
        guard let first = playlists.first,
              let (_, rows) = try? await SyncBridge.playlistDetail.fetchPlaylistRows(playlistId: first.id) else {
            return false
        }
        let songs = rows.compactMap { item -> SongItem? in
            guard let renderer = item["musicResponsiveListItemRenderer"] as? [String: Any] else { return nil }
            return SongItem.from(renderer)
        }
        guard songs.count >= 3 else { return false }
        PlaybackQueue.play(songs, log: Log.nowPlaying, context: "Intent: mixed for you")
        return true
    }

    // MARK: - 2) Radio de una cancion del inicio

    private static func playAnySong(in sections: [HomePage.Section]) -> Bool {
        var songs: [SongItem] = []
        for section in sections {
            for item in section.items {
                if case .song(let song) = item { songs.append(song) }
            }
        }
        guard let pick = songs.randomElement() else { return false }
        PlaybackQueue.playSingleWithRadio(pick, log: Log.nowPlaying)
        return true
    }

    // MARK: - 3) Sin red

    private static func playLikedSongs() async -> Bool {
        guard let liked = try? await DatabaseService.shared.fetchLikedSongs(), !liked.isEmpty else { return false }
        let songs = liked.shuffled().prefix(40).toSongItems()
        guard !songs.isEmpty else { return false }
        PlaybackQueue.play(Array(songs), log: Log.nowPlaying, context: "Intent: liked songs")
        return true
    }
}
