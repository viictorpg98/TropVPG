//
//  SonarMix.swift
//  Trop
//

import Foundation
import UIKit

/// "Pon música": empieza a sonar una mezcla de lo que le gusta a la persona, sin abrir pantallas.
/// Orden de preferencia:
/// 0. Canciones descargadas (suenan al instante desde el archivo; luego sigue la mezcla guardada).
/// 1. La ultima mezcla guardada (arranca sin esperar a la red; se refresca despues).
/// 2. La primera lista de "Mezclado para ti" de YouTube Music (tu Supermix o similar).
/// 3. La radio de una cancion cualquiera de tu inicio.
/// 4. Sin red: canciones que te gustan, guardadas en el dispositivo.
///
/// La accion no termina hasta que el audio esta sonando: si devolviera el control antes, iOS podria
/// suspender la app y la musica empezaria "al rato" (y Siri diria que hubo un problema).
@MainActor
enum SonarMix {
    private static let cacheKey = "sonarMix.cachedSongs"

    /// Devuelve `true` si ha empezado a sonar algo.
    static func start() async -> Bool {
        // Mantiene la app con CPU mientras se prepara y arranca el audio.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SonarMix")
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        // 0) Lo mas rapido: canciones descargadas. Suenan desde el archivo, sin tokens ni red, asi que no
        // hay que esperar a que arranque en frio el navegador oculto que genera los tokens de YouTube
        // (cuando la app la lanza una accion en segundo plano ese arranque tarda muchisimo).
        let downloaded = await downloadedSongs()
        if !downloaded.isEmpty {
            var queue = Array(downloaded.shuffled().prefix(40))
            if let cached = cachedMix() {
                let ids = Set(queue.map(\.videoId))
                queue += cached.shuffled().filter { !ids.contains($0.videoId) }.prefix(30)
            }
            if await play(queue, context: "downloaded first") {
                // Mientras suena la descargada se calienta lo necesario para las siguientes.
                let seed = queue.last?.videoId ?? ""
                Task {
                    await warmUpTokens(videoId: seed)
                    await refreshCache()
                }
                return true
            }
        }

        // 1) Ultima mezcla guardada: sin esperar a la red.
        if let cached = cachedMix(), await play(cached.shuffled(), context: "cached mix") {
            Task { await refreshCache() }
            return true
        }

        // 2) y 3) Con red.
        await prepareSession()
        if let sections = await loadHomeSections() {
            if let songs = await mixedForYouSongs(in: sections) {
                saveCache(songs)
                if await play(songs.shuffled(), context: "mixed for you") { return true }
            }
            if await playRadioOfAnySong(in: sections) { return true }
        }

        // 4) Sin red.
        return await playLikedSongs()
    }

    // MARK: - Descargadas y calentamiento

    private static func downloadedSongs() async -> [SongItem] {
        await DownloadManager.shared.fetchAll().map { SongItem(entity: $0) }
    }

    /// Arranca el generador de tokens (navegador oculto + BotGuard) para que, cuando haga falta
    /// resolver una cancion por red, ya este listo.
    private static func warmUpTokens(videoId: String) async {
        guard !videoId.isEmpty else { return }
        _ = try? await PoTokenGenerator.shared.generate(videoId: videoId, sessionId: PlaybackManager.sessionId)
    }

    // MARK: - Reproduccion

    /// Pone la cola y espera a que la primera cancion este sonando.
    private static func play(_ songs: [SongItem], context: String) async -> Bool {
        guard let first = songs.first else { return false }
        NowPlaying.shared.setQueue(songs, startIndex: 0)
        do {
            try await PlaybackManager.shared.resolveAndPlay(videoId: first.videoId)
            return true
        } catch {
            Log.nowPlaying.error("Intent playback failed (\(context)): \(error)")
            return false
        }
    }

    // MARK: - Sesion e inicio

    private static func prepareSession() async {
        let cookieStore = CookieStore()
        if await cookieStore.isLoggedIn() {
            await InnerTubeClient.tropShared.loadState(from: cookieStore)
        }
    }

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

    // MARK: - Mezclado para ti

    private static func mixedForYouSongs(in sections: [HomePage.Section]) async -> [SongItem]? {
        guard let section = mixedForYou(in: sections) else { return nil }
        let playlists = section.items.compactMap { item -> PlaylistItem? in
            if case .playlist(let playlist) = item { return playlist }
            return nil
        }
        guard let first = playlists.first,
              let (_, rows) = try? await SyncBridge.playlistDetail.fetchPlaylistRows(playlistId: first.id) else {
            return nil
        }
        let songs = rows.compactMap { item -> SongItem? in
            guard let renderer = item["musicResponsiveListItemRenderer"] as? [String: Any] else { return nil }
            return SongItem.from(renderer)
        }
        return songs.count >= 3 ? songs : nil
    }

    /// Vuelve a pedir la mezcla y la guarda, para que la proxima vez arranque al instante.
    private static func refreshCache() async {
        await prepareSession()
        guard let sections = await loadHomeSections(),
              let songs = await mixedForYouSongs(in: sections) else { return }
        saveCache(songs)
    }

    // MARK: - Radio de una cancion del inicio

    private static func playRadioOfAnySong(in sections: [HomePage.Section]) async -> Bool {
        var songs: [SongItem] = []
        for section in sections {
            for item in section.items {
                if case .song(let song) = item { songs.append(song) }
            }
        }
        guard let pick = songs.randomElement(),
              await play([pick], context: "radio seed") else { return false }
        PlaybackQueue.startRadio(for: pick)
        return true
    }

    // MARK: - Sin red

    private static func playLikedSongs() async -> Bool {
        guard let liked = try? await DatabaseService.shared.fetchLikedSongs(), !liked.isEmpty else { return false }
        let songs = Array(liked.shuffled().prefix(40).toSongItems())
        return await play(songs, context: "liked songs")
    }

    // MARK: - Guardado de la mezcla

    private static func saveCache(_ songs: [SongItem]) {
        guard let data = try? JSONEncoder().encode(Array(songs.prefix(60))) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    private static func cachedMix() -> [SongItem]? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let songs = try? JSONDecoder().decode([SongItem].self, from: data),
              songs.count >= 3 else { return nil }
        return songs
    }
}
