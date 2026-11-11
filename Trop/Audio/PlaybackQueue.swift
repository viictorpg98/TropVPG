//
//  PlaybackQueue.swift
//  Trop
//
// Created by 686udjie on 12/09/2026.
//

import Foundation

/// Shared queue setup + resolve-and-play flows used by every tap-to-play site.
/// Each entry sets the queue on `NowPlaying` and resolves the stream via
/// `PlaybackManager`, logging failures instead of going silent.
@MainActor
enum PlaybackQueue {
    /// Plays `songs[startIndex]` (clamped). Used by detail play-all / play-song.
    static func play(_ songs: [SongItem], startIndex: Int = 0, log: AppLogger, context: String) {
        guard !songs.isEmpty else { return }
        let index = min(max(startIndex, 0), songs.count - 1)
        let store = AudioCounterpartStore.shared
        // Un video que tiene version de audio suena como audio (como hace YouTube Music). Si aun no se ha mirado, se mira ahora,
        // con un limite de espera para no retrasar el sonido.
        if store.needsLookup(songs[index]) {
            loggedTask(log, "\(context) failed") {
                let first = await store.resolve(songs[index])
                start(songs, index: index, first: first)
                try await PlaybackManager.shared.resolveAndPlay(videoId: first.videoId)
            }
            return
        }
        let first = store.preferAudio(songs[index])
        start(songs, index: index, first: first)
        loggedTask(log, "\(context) failed") {
            try await PlaybackManager.shared.resolveAndPlay(videoId: first.videoId)
        }
    }

    /// Pone la cola con `first` en el sitio de la cancion elegida.
    private static func start(_ songs: [SongItem], index: Int, first: SongItem) {
        var list = songs
        list[index] = first
        NowPlaying.shared.setQueue(list, startIndex: index)
        AnimatedArtworkService.shared.prefetch(first)
        warmArtwork(first)
    }

    /// Empieza a cargar su miniatura para que el mini reproductor la tenga lista (y no enseñe otra mientras tanto).
    private static func warmArtwork(_ song: SongItem) {
        guard let thumbnail = song.thumbnailUrl, let url = URL(string: thumbnail) else { return }
        Task { _ = try? await ArtworkLoader.image(for: url) }
    }

    /// Shuffled variant of `play(_:startIndex:)`.
    static func playShuffled(_ songs: [SongItem], log: AppLogger, context: String) {
        guard !songs.isEmpty else { return }
        play(songs.shuffled(), log: log, context: context)
    }

    /// Plays `song`, reusing `songs` as the queue when it contains it.
    static func play(_ song: SongItem, in songs: [SongItem], log: AppLogger, context: String) {
        if let index = songs.firstIndex(where: { $0.videoId == song.videoId }) {
            play(songs, startIndex: index, log: log, context: context)
        } else {
            play([song], log: log, context: context)
        }
    }

    /// Starts a radio queue for `song`: plays it first unless already current,
    /// then replaces the queue with the fetched radio. Used by the song and
    /// player "Start Radio" menu actions.
    static func startRadio(for song: SongItem, options: RadioOptions = .default) {
        let isCurrentSong = NowPlaying.shared.videoId == song.videoId
        if !NetworkMonitor.shared.hasConnection {
            if !isCurrentSong {
                NowPlaying.shared.setQueue(offlineQueue(startingWith: song), startIndex: 0)
                NowPlaying.shared.markQueueSeededOffline()
                Task { try? await PlaybackManager.shared.resolveAndPlay(videoId: song.videoId) }
            }
            return
        }
        if !isCurrentSong {
            NowPlaying.shared.setQueue([song], startIndex: 0)
            Task { try? await PlaybackManager.shared.resolveAndPlay(videoId: song.videoId) }
        }
        Task {
            guard let radio = try? await PersonalizationService.shared.fetchRadio(videoId: song.videoId, options: options),
                  radio.songs.count > 1 else { return }
            guard NowPlaying.shared.videoId == song.videoId else { return }
            NowPlaying.shared.queueSongs = preservingArtists(radio.songs, over: NowPlaying.shared.queueSongs)
            NowPlaying.shared.queueIndex = radio.currentIndex
            NowPlaying.shared.applyAudioVersions()
            QueueChipsStore.shared.set(radio.chips)
        }
    }

    /// Plays a single song, then continues with its radio queue when available.
    /// Used by Home/Search/Explore tap-to-play.
    static func playSingleWithRadio(_ song: SongItem, log: AppLogger) {
        // Sin conexion no hay radio: la cola se rellena con tu musica descargada.
        if !NetworkMonitor.shared.hasConnection {
            NowPlaying.shared.setQueue(offlineQueue(startingWith: song), startIndex: 0)
            NowPlaying.shared.markQueueSeededOffline()
            loggedTask(log, "Offline playback failed") {
                try await PlaybackManager.shared.resolveAndPlay(videoId: song.videoId)
            }
            return
        }
        // Si es un video con version de audio, suena el audio (se mira antes si hace falta, con un limite de espera).
        let store = AudioCounterpartStore.shared
        if store.needsLookup(song) {
            Task { @MainActor in
                let resolved = await store.resolve(song)
                startSingleWithRadio(resolved, log: log)
            }
        } else {
            startSingleWithRadio(store.preferAudio(song), log: log)
        }
    }

    private static func startSingleWithRadio(_ song: SongItem, log: AppLogger) {
        NowPlaying.shared.setQueue([song], startIndex: 0)
        AnimatedArtworkService.shared.prefetch(song)
        warmArtwork(song)
        Task { @MainActor in
            do {
                try await PlaybackManager.shared.resolveAndPlay(videoId: song.videoId)
            } catch {
                log.error("Playback failed: \(error)")
                return
            }
            guard let radio = try? await PersonalizationService.shared.fetchRadio(videoId: song.videoId),
                  radio.songs.count > 1,
                  NowPlaying.shared.videoId == song.videoId else { return }
            NowPlaying.shared.queueSongs = preservingArtists(radio.songs, over: NowPlaying.shared.queueSongs)
            NowPlaying.shared.queueIndex = radio.currentIndex
            NowPlaying.shared.applyAudioVersions()
            QueueChipsStore.shared.set(radio.chips)
        }
    }

    /// La cancion elegida seguida de tu musica descargada mezclada (hasta 60), para poder seguir sin conexion.
    private static func offlineQueue(startingWith song: SongItem) -> [SongItem] {
        let others = DownloadManager.shared.tracks
            .filter { $0.id != song.videoId }
            .map { SongItem(entity: $0) }
            .shuffled()
            .prefix(60)
        return [song] + Array(others)
    }

    private static func preservingArtists(_ songs: [SongItem], over current: [SongItem]) -> [SongItem] {
        guard !current.isEmpty else { return songs }
        // Con la misma cancion dos veces en la cola, `uniqueKeysWithValues` cerraria la app: se queda con la primera.
        let existingById = Dictionary(current.map { ($0.videoId, $0) }, uniquingKeysWith: { first, _ in first })
        return songs.map { song in
            guard let old = existingById[song.videoId], old.artists.count > song.artists.count else { return song }
            var merged = song
            merged.artists = old.artists
            return merged
        }
    }
}
