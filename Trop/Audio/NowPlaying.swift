//
//  NowPlaying.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import AVFoundation
import Foundation
import Observation
import Nuke
import SwiftUI

@Observable
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()

    var title = ""
    var artist = ""
    var albumTitle = ""
    var videoId: String?
    var artists: [YTArtist] = []
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var progress: Float {
        duration > 0 ? Float(currentTime / duration) : 0
    }
    var thumbnailImage: Image?
    var thumbnailUIImage: UIImage?
    var thumbnailVersion = 0
    var dominantColors: [Color] = [Color(red: 0.15, green: 0.15, blue: 0.2), Color(red: 0.05, green: 0.05, blue: 0.08)]
    /// Color de la franja inferior de la carátula: el reproductor lo usa de fondo para fundirla con el resto.
    var artworkEdgeColor: Color?

    var accentColor: Color? {
        guard videoId != nil, let primary = dominantColors.first else { return nil }
        return primary
    }

    var queueSongs: [SongItem] = []
    var queueIndex = 0
    /// Cuando se cambio de cancion por si sola (AutoMix o paso automatico a la siguiente), para no cerrar la cola ni la letra.
    var lastAutomaticChange = Date.distantPast

    var isShuffleOn = false
    var isRepeatOn = false

    var hasVideo: Bool = false
    var isVideoMode: Bool = false
    var isVideoReady: Bool = false
    var musicVideoType: String?

    private var originalQueue: [SongItem]?

    var hasNext: Bool {
        queueIndex + 1 < queueSongs.count
    }

    var hasPrevious: Bool {
        queueIndex > 0
    }

    var isBarPresented: Bool {
        videoId != nil
    }

    private var timer: Timer?
    private var tickCount = 0
    var lastManualSkipTime: Date?
    private var isResolvingNext = false
    /// Hay una cancion cargandose (AutoMix no empieza mezclas mientras tanto).
    var isBusyResolving: Bool { isResolvingNext }
    /// Timestamps of the last mid-play failure per videoId, to bound retries.
    private var lastFailureAt: [String: Date] = [:]

    private static let queueKey = "nowPlaying.queue"
    private static let queueIndexKey = "nowPlaying.queueIndex"
    private static let shuffleKey = "nowPlaying.shuffle"
    private static let repeatKey = "nowPlaying.repeat"

    private init() {
        restoreQueueIfNeeded()
    }

    deinit {
        Task { @MainActor [weak self] in self?.stopTimer() }
    }

    // MARK: - Persistent queue

    private func restoreQueueIfNeeded() {
        guard SettingsStore.shared.persistQueue,
              let data = UserDefaults.standard.data(forKey: Self.queueKey),
              let songs = try? JSONDecoder().decode([SongItem].self, from: data),
              !songs.isEmpty else { return }
        queueSongs = songs
        // integer(forKey:) returns 0 even when key missing – distinguish via object(forKey:)
        let storedIndex: Int
        if UserDefaults.standard.object(forKey: Self.queueIndexKey) != nil {
            storedIndex = UserDefaults.standard.integer(forKey: Self.queueIndexKey)
        } else {
            storedIndex = 0
        }
        queueIndex = min(max(storedIndex, 0), songs.count - 1)
        isShuffleOn = UserDefaults.standard.bool(forKey: Self.shuffleKey)
        isRepeatOn = UserDefaults.standard.bool(forKey: Self.repeatKey)
        queueIndex = max(0, queueIndex)
    }

    private static let persistQueueQueue = DispatchQueue(label: "com.sonar.persistQueue", qos: .utility)

    func persistQueueState() {
        guard SettingsStore.shared.persistQueue else { return }
        let songs = queueSongs
        let index = queueIndex
        let shuffle = isShuffleOn
        let repeatOn = isRepeatOn
        let keys = (Self.queueKey, Self.queueIndexKey, Self.shuffleKey, Self.repeatKey)
        // Codificar una cola de cientos de canciones lleva tiempo: se hace fuera del hilo principal.
        Self.persistQueueQueue.async {
            let defaults = UserDefaults.standard
            if songs.isEmpty {
                for key in [keys.0, keys.1, keys.2, keys.3] { defaults.removeObject(forKey: key) }
                return
            }
            if let data = try? JSONEncoder().encode(songs) { defaults.set(data, forKey: keys.0) }
            defaults.set(index, forKey: keys.1)
            defaults.set(shuffle, forKey: keys.2)
            defaults.set(repeatOn, forKey: keys.3)
        }
    }

    func setQueue(_ songs: [SongItem], startIndex: Int) {
        resetOfflineState()
        queueSongs = songs
        queueIndex = min(max(startIndex, 0), max(songs.count - 1, 0))
        originalQueue = nil
        isShuffleOn = false
        persistQueueState()
        applyAudioVersions()
    }

    /// En lo que queda por sonar, cambia los videos que tienen version de audio por esa version (como hace YouTube Music por
    /// defecto) y pide la de los que aun no se han mirado; cuando llegue, se vuelve a aplicar. La que suena no se toca.
    func applyAudioVersions() {
        guard !queueSongs.isEmpty else { return }
        let store = AudioCounterpartStore.shared
        let start = min(queueIndex + 1, queueSongs.count)
        var songs = queueSongs
        var changed = false
        for index in start..<songs.count {
            let swapped = store.preferAudio(songs[index])
            if swapped.videoId != songs[index].videoId {
                songs[index] = swapped
                changed = true
            }
        }
        store.prefetch(Array(songs[start...]))
        if changed {
            queueSongs = songs
            persistQueueState()
        }
    }

    /// Ensures `queueIndex` points at a valid entry
    func repairQueueIndex() {
        if queueSongs.isEmpty {
            queueIndex = 0
            return
        }
        if let videoId, let idx = queueSongs.firstIndex(where: { $0.videoId == videoId }) {
            queueIndex = idx
        } else {
            queueIndex = min(max(queueIndex, 0), queueSongs.count - 1)
        }
    }

    func upcomingSongs(prefixLimit: Int? = nil) -> [SongItem] {
        let next = queueIndex + 1
        guard queueSongs.indices.contains(next) else { return [] }
        let rest = Array(queueSongs[next...])
        guard let prefixLimit else { return rest }
        return Array(rest.prefix(prefixLimit))
    }

    /// Shuffles upcoming songs, keeping the current one; tapping again re-shuffles.
    func shuffleQueue() {
        guard queueSongs.count > 1 else {
            isShuffleOn = true
            return
        }
        if originalQueue == nil {
            originalQueue = queueSongs
        }
        let prefix = queueIndex > 0 ? Array(queueSongs[0..<queueIndex]) : []
        let current = queueSongs[queueIndex]
        var rest = queueIndex + 1 < queueSongs.count ? Array(queueSongs[(queueIndex + 1)...]) : []
        rest.shuffle()
        queueSongs = prefix + [current] + rest
        queueIndex = prefix.count
        isShuffleOn = true
        persistQueueState()
    }

    /// Restore the original (unshuffled) queue order.
    func disableShuffle() {
        guard queueSongs.indices.contains(queueIndex) else { return }
        if let orig = originalQueue {
            let currentVideoId = queueSongs[queueIndex].videoId
            queueSongs = orig
            // The shuffled index is meaningless against the original array
            // (radio appends, deletes and reorders change lengths).
            let restored = orig.firstIndex(where: { $0.videoId == currentVideoId }) ?? queueIndex
            queueIndex = min(restored, max(orig.count - 1, 0))
        }
        originalQueue = nil
        isShuffleOn = false
        persistQueueState()
    }

    func moveQueueSongs(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty, queueSongs.indices.contains(source.first ?? -1) else { return }
        queueSongs.move(fromOffsets: source, toOffset: destination)
        repairQueueIndex()
        persistQueueState()
    }

    func repeatCurrent() {
        guard queueSongs.indices.contains(queueIndex) else { return }
        playCurrentSong(logContext: "repeatCurrent") {
            self.isRepeatOn = false
        }
    }

    func playNext(automatic: Bool = false) {
        guard hasNext else { return }
        guard !isResolvingNext else { return }
        var target = queueIndex + 1
        if !NetworkMonitor.shared.hasConnection {
            // Sin conexion solo se pueden reproducir las descargadas: se salta a la siguiente que lo este y, si
            // no queda ninguna en la cola, se sigue con la musica descargada.
            let downloads = DownloadManager.shared
            if let found = (target..<queueSongs.count).first(where: {
                downloads.isDownloaded(videoId: queueSongs[$0].videoId)
            }) {
                // Las que se saltan se guardan para devolverlas a la cola al recuperar la conexion.
                if found > target, !offlineFallbackActive {
                    // La descargada encontrada pasa a ocupar el sitio de `target`.
                    offlineHeldBack += queueSongs[target..<found]
                    queueSongs.removeSubrange(target..<found)
                    offlineQueueActive = true
                } else {
                    target = found
                }
            } else {
                continueWithDownloadedMusic()
                return
            }
        }
        if !automatic { lastManualSkipTime = Date() }
        if automatic { lastAutomaticChange = Date() }
        queueIndex = target
        playCurrentSong(logContext: "playNext")
    }

    /// AutoMix: mpv ya suena la entrante (encadenada sin pausa tras la mezcla); la cola y los datos de la cancion pasan a ella.
    /// No carga nada: solo pone al dia lo que la app muestra y recuerda.
    func adoptGaplessIncoming(videoId: String, position: TimeInterval, artwork: UIImage?) -> Bool {
        guard queueIndex + 1 < queueSongs.count, queueSongs[queueIndex + 1].videoId == videoId else { return false }
        lastAutomaticChange = Date()
        queueIndex += 1
        let song = queueSongs[queueIndex]
        update(with: song)
        // `update` pone la posicion y la duracion a cero y deja la carátula de la saliente hasta que carga la nueva: aqui
        // la cancion ya esta sonando, asi que se ponen los valores reales y la carátula que ya se veia en la mezcla, y
        // la pantalla no da un salto ("refresco") al acabar.
        SponsorBlockIntegration.shared.ignore(videoId: videoId)
        currentTime = position
        if song.duration > 0 { duration = TimeInterval(song.duration) }
        if let artwork { publishArtwork(artwork) }
        persistQueueState()
        updateVideoAvailability()
        // Tras un relevo de AutoMix tambien se adelanta la onda de las proximas.
        WaveformStore.shared.songStarted(
            current: videoId,
            upcoming: queueSongs.dropFirst(queueIndex + 1).map(\.videoId)
        )
        Task {
            await PlaybackStateService.shared.stopTracking()
            await PlaybackStateService.shared.startTracking(videoId: videoId)
        }
        return true
    }

    func playPrevious() {
        guard hasPrevious else { return }
        guard !isResolvingNext else { return }
        lastManualSkipTime = Date()
        queueIndex -= 1
        playCurrentSong(logContext: "playPrevious")
    }

    /// Starts the song at `queueIndex`: pushes metadata, persists the queue,
    /// and resolves the stream, clearing `isResolvingNext` afterwards.
    /// Shared by repeatCurrent/playNext/playPrevious and QueueView playback.
    func playCurrentSong(
        logContext: String,
        manageResolvingFlag: Bool = true,
        startAt: TimeInterval = 0,
        afterResolve: (() -> Void)? = nil
    ) {
        guard queueSongs.indices.contains(queueIndex) else { return }
        AutoMixEngine.shared.songChanged()
        if manageResolvingFlag {
            isResolvingNext = true
        }
        let song = queueSongs[queueIndex]
        update(with: song)
        persistQueueState()
        WaveformStore.shared.songStarted(
            current: song.videoId,
            upcoming: queueSongs.dropFirst(queueIndex + 1).map(\.videoId)
        )
        Task {
            do {
                try await PlaybackManager.shared.resolveAndPlay(videoId: song.videoId, startAt: startAt)
            } catch {
                Log.nowPlaying.error("\(logContext) failed: \(error)")
                if self.videoId == song.videoId {
                    isPlaying = false
                }
            }
            if manageResolvingFlag {
                isResolvingNext = false
            }
            afterResolve?()
            await self.verifyPlaybackStarted(song.videoId, startAt: startAt, logContext: logContext)
        }
    }

    /// Red de seguridad: si tras pedir una cancion el reproductor ni la ha cargado ni la tiene en camino (seguia sonando
    /// la anterior), se vuelve a pedir una vez y queda apuntado en el informe.
    private func verifyPlaybackStarted(_ videoId: String, startAt: TimeInterval, logContext: String) async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard self.videoId == videoId, isPlaying else { return }
        let controller = PlayerController.shared
        guard controller.currentVideoId != videoId, controller.pendingVideoId != videoId,
              controller.gaplessStage == 0 else { return }
        PlaybackReport.record("cola: \(videoId) no llego a sonar tras \(logContext) (suena \(controller.currentVideoId ?? "nada")), se reintenta")
        _ = try? await PlaybackManager.shared.resolveAndPlay(videoId: videoId, startAt: startAt)
    }

    func update(title: String, artist: String?, videoId: String, album: String? = nil, artists: [YTArtist] = [], thumbnailUrl: String? = nil) {
        self.isPlaying = true
        self.title = title
        self.artists = artists
        self.artist = cleanArtistDisplay(artist ?? "")
        self.albumTitle = album ?? ""
        self.currentTime = 0
        self.duration = 0
        self.videoId = videoId
        self.hasVideo = false
        self.isVideoMode = false
        self.isVideoReady = false
        startTimer()
        loadThumbnail(videoId: videoId, thumbnailUrl: thumbnailUrl)
        preloadNextTrack()
    }

    /// Convenience pushing a `SongItem`'s metadata into the player state.
    func update(with song: SongItem) {
        update(
            title: song.title,
            artist: song.artists.map(\.name).joined(separator: ", "),
            videoId: song.videoId,
            album: song.album,
            artists: song.artists,
            thumbnailUrl: song.thumbnailUrl
        )
    }

    /// Records video availability: the watchable-video verdict comes from
    /// the shared availability check (row type preferred, authoritative
    /// lookup as fallback); this only stores it alongside the type and
    /// pre-warms when there is one to show.
    func updateVideoAvailability(musicVideoType: String? = nil, hasVideo: Bool = false) {
        if let musicVideoType {
            self.musicVideoType = musicVideoType
        }
        self.hasVideo = hasVideo
        if hasVideo {
            PlayerController.shared.preloadVideoURL()
        }
        PlayerController.shared.refreshRemoteCommandState()
    }

    /// Pre-warms artwork for the previous and upcoming songs so swiping the
    /// mini player bar shows their art instantly.
    func preloadNeighborArtwork() {
        var urls = upcomingSongs(prefixLimit: 3)
            .compactMap(\.thumbnailUrl)
            .compactMap { URL(string: ArtworkURLs.highRes($0) ?? $0) }
        let neighborIds = queueSongs.indices.compactMap { index -> String? in
            guard index == queueIndex - 1 || (index > queueIndex && index <= queueIndex + 3) else { return nil }
            return queueSongs[index].videoId
        }
        urls.append(contentsOf: neighborIds.compactMap { URL(string: Self.artworkURL(for: $0)) })
        guard !urls.isEmpty else { return }
        Task { await ImagePreloader.shared.append(urls) }
    }

    /// Artist string from `artists`, falling back to `artist`.
    var displayArtist: String {
        let fromArray = artistDisplayString(from: artists)
        if !fromArray.isEmpty { return fromArray }
        return artist
    }

    func stopped(videoId: String?, isEof: Bool = true) {
        guard self.videoId == videoId else { return }
        // Un error es de esta cancion (el fin de la anterior no llega como error): antes, si llegaba a menos de 2 s de un
        // salto manual, se descartaba y la cancion se quedaba sin cargar sin reintentarlo.
        if isEof, let skipTime = lastManualSkipTime, Date().timeIntervalSince(skipTime) < 2, isResolvingNext {
            return
        }
        guard isEof else {
            recoverFromPlaybackFailure(videoId: videoId)
            return
        }
        currentTime = duration
        if let finishedId = videoId,
           duration >= 600 || musicVideoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" {
            Task { await EpisodePlaybackStore.shared.markPlayed(videoId: finishedId) }
        }
        if isRepeatOn {
            repeatCurrent()
            return
        }
        if !hasNext, !NetworkMonitor.shared.hasConnection {
            // Se acabo la cola y no hay red: no se puede pedir "parecidas"; se sigue con lo descargado.
            continueWithDownloadedMusic()
            return
        }
        if hasNext {
            playNext(automatic: true)
        } else if SettingsStore.shared.autoplaySimilar, let endedVideoId = videoId {
            autoplaySimilar(from: endedVideoId)
        } else {
            // End of queue, pause but keep the last song shown in the player.
            isPlaying = false
            stopTimer()
            PlayerController.shared.updateNowPlayingProgress()
            Task { await PlaybackStateService.shared.stopTracking() }
        }
    }

    private var isExtendingQueue = false
    private var lastExtendAttempt = Date.distantPast

    /// La cola no se acaba: cuando quedan pocas canciones por sonar, se anaden mas de la radio de la que suena (como YouTube
    /// Music). Asi no hay que esperar al final para pedirlas, y AutoMix siempre tiene una siguiente.
    func extendQueueIfNeeded() {
        guard SettingsStore.shared.autoplaySimilar, !isRepeatOn, !isExtendingQueue,
              !offlineQueueActive, !offlineFallbackActive, NetworkMonitor.shared.hasConnection,
              queueSongs.indices.contains(queueIndex),
              queueSongs.count - queueIndex - 1 <= 4,
              Date().timeIntervalSince(lastExtendAttempt) > 20 else { return }
        lastExtendAttempt = Date()
        isExtendingQueue = true
        let current = queueSongs[queueIndex].videoId
        let last = queueSongs[queueSongs.count - 1].videoId
        Task {
            var added: [SongItem] = []
            var seeds = [current]
            if last != current { seeds.append(last) }
            for seed in seeds {
                guard let radio = try? await PersonalizationService.shared.fetchRadio(videoId: seed) else { continue }
                let known = Set(self.queueSongs.map(\.videoId))
                added = radio.songs.filter { !known.contains($0.videoId) }
                if !added.isEmpty { break }
            }
            self.isExtendingQueue = false
            guard !added.isEmpty, self.queueSongs.indices.contains(self.queueIndex) else {
                PlaybackReport.record("cola: no se pudo ampliar (la radio de \(current) no trajo canciones nuevas)")
                return
            }
            self.queueSongs += added
            self.applyAudioVersions()
            self.persistQueueState()
            PlaybackReport.record("cola: ampliada con \(added.count) canciones de la radio de \(current)")
        }
    }

    /// Continues playback with a radio queue built from the last song when the
    /// queue runs out and "Autoplay Similar" is enabled.
    private func autoplaySimilar(from videoId: String) {
        Task {
            do {
                let radio = try await PersonalizationService.shared.fetchRadio(videoId: videoId)
                let songs = radio.songs
                guard !songs.isEmpty else {
                    isPlaying = false
                    return
                }
                self.queueSongs = songs
                self.queueIndex = 0
                self.isShuffleOn = false
                self.applyAudioVersions()
                let first = songs[0]
                update(with: first)
                try await PlaybackManager.shared.resolveAndPlay(videoId: first.videoId)
                self.persistQueueState()
            } catch {
                Log.nowPlaying.error("Autoplay similar failed: \(error)")
                isPlaying = false
            }
        }
    }

    /// Sin conexion y sin mas descargadas en la cola: sigue con tus canciones descargadas (mezcladas), conservando
    /// lo ya escuchado. Si no hay ninguna descargada, avisa.
    private func continueWithDownloadedMusic() {
        // Lo que quedaba de la cola normal se guarda para volver a ella al recuperar la conexion.
        if !offlineFallbackActive, queueSongs.indices.contains(queueIndex) {
            offlineHeldBack += queueSongs[(queueIndex + 1)...]
        }
        let currentId = queueSongs.indices.contains(queueIndex) ? queueSongs[queueIndex].videoId : nil
        let candidates = DownloadManager.shared.tracks
            .filter { $0.id != currentId }
            .map { SongItem(entity: $0) }
            .shuffled()
            .prefix(60)
        guard !candidates.isEmpty else {
            isPlaying = false
            PlaybackNotice.shared.show(NSLocalizedString("No connection and no downloaded songs.", comment: ""))
            return
        }
        PlaybackNotice.shared.show(NSLocalizedString("No connection: continuing with your downloaded music.", comment: ""))
        let played = queueSongs.indices.contains(queueIndex) ? Array(queueSongs[0...queueIndex]) : []
        queueSongs = played + Array(candidates)
        queueIndex = played.count
        offlineQueueActive = true
        offlineFallbackActive = true
        playCurrentSong(logContext: "offlineFallback")
    }

    // MARK: - Volver a la cola normal al recuperar la conexion

    /// La cola se ha modificado por falta de conexion (se saltaron canciones o se rellenó con descargadas).
    private var offlineQueueActive = false
    /// La cola de después de la actual es música descargada de relleno (no la cola normal).
    private var offlineFallbackActive = false
    /// Canciones de la cola normal apartadas mientras no había conexion.
    private var offlineHeldBack: [SongItem] = []
    /// La cola se creó sin conexion a partir de una sola canción (no hay cola normal: se pide su radio al volver).
    private var offlineSeededQueue = false

    private func resetOfflineState() {
        offlineQueueActive = false
        offlineFallbackActive = false
        offlineHeldBack = []
        offlineSeededQueue = false
    }

    /// Para una cola creada sin conexion con una cancion y descargadas de relleno (ver `PlaybackQueue`).
    func markQueueSeededOffline() {
        offlineSeededQueue = true
    }

    /// Vuelve la conexion: se recupera la cola normal (o la radio de la cancion actual) sin cortar lo que suena.
    func connectionRestored() {
        guard offlineQueueActive || offlineSeededQueue else { return }
        Task { @MainActor in
            // Se espera un poco por si es un corte breve.
            try? await Task.sleep(for: .seconds(2))
            guard NetworkMonitor.shared.hasConnection else { return }
            self.restoreOnlineQueue()
        }
    }

    private func restoreOnlineQueue() {
        if offlineSeededQueue {
            offlineSeededQueue = false
            guard let seedId = videoId else { return }
            Task { @MainActor in
                guard let radio = try? await PersonalizationService.shared.fetchRadio(videoId: seedId),
                      radio.songs.count > 1, self.videoId == seedId else { return }
                self.queueSongs = radio.songs
                self.queueIndex = radio.currentIndex
                self.originalQueue = nil
                self.isShuffleOn = false
                self.persistQueueState()
                PlaybackNotice.shared.show(NSLocalizedString("Connection restored: back to your normal queue.", comment: ""))
            }
            return
        }
        guard offlineQueueActive, queueSongs.indices.contains(queueIndex) else {
            resetOfflineState()
            return
        }
        let played = Array(queueSongs[0...queueIndex])
        let rest = offlineFallbackActive ? [] : Array(queueSongs[(queueIndex + 1)...])
        let restored = played + offlineHeldBack + rest
        resetOfflineState()
        guard restored.count > played.count else { return }
        queueSongs = restored
        persistQueueState()
        PlaybackNotice.shared.show(NSLocalizedString("Connection restored: back to your normal queue.", comment: ""))
    }

    /// A stream that died mid-play (not EOF, not a manual skip): drop the
    /// possibly-expired cached URL and re-resolve once. Repeated failures for
    /// the same video are only retried after a cooldown to avoid a loop.
    private func recoverFromPlaybackFailure(videoId: String?) {
        guard let videoId else {
            isPlaying = false
            return
        }
        PlayerController.shared.handleVideoStreamFailure()
        // Sin conexion no hay nada que volver a resolver: se pasa a lo siguiente que se pueda oir.
        if !NetworkMonitor.shared.hasConnection, !DownloadManager.shared.isDownloaded(videoId: videoId) {
            isPlaying = false
            if hasNext { playNext(automatic: true) } else { continueWithDownloadedMusic() }
            return
        }
        if let last = lastFailureAt[videoId], Date().timeIntervalSince(last) < 30 {
            PlaybackReport.record("reproductor: \(videoId) fallo otra vez en menos de 30 s, no se reintenta")
            isPlaying = false
            return
        }
        lastFailureAt[videoId] = Date()
        PlaybackReport.record("reproductor: \(videoId) no cargo, se pide de nuevo comprobando todas las direcciones")
        isPlaying = false
        Log.nowPlaying.notice("Stream failed mid-play, re-resolving \(videoId)")
        Task {
            await PlayerConfigStore.shared.notifyStreamRejection()
            await PlaybackManager.shared.noteStreamFailure(videoId: videoId)
            await StreamCache.shared.remove(videoId: videoId)
            // Si la direccion fallo, el reintento comprueba todas las direcciones antes de usar ninguna
            // (si no, podia repetir la misma direccion mala del mismo cliente).
            await PlaybackManager.shared.requireValidatedChain(for: videoId)
            do {
                try await PlaybackManager.shared.resolveAndPlay(videoId: videoId)
                // Success – allow future retries for this video
                _ = await MainActor.run { self.lastFailureAt.removeValue(forKey: videoId) }
            } catch {
                Log.nowPlaying.error("Mid-play recovery failed: \(error)")
                if self.videoId == videoId {
                    isPlaying = false
                }
            }
        }
    }

    static func artworkURL(for videoId: String) -> String {
        ArtworkURLs.fallback(for: videoId)
    }

    private var lastLoadedVideoId: String?
    /// Cancion cuya caratula ya es la de alta calidad de Apple Music / TIDAL: las demas fuentes no la pisan.
    private var highQualityCoverFor: String?

    /// Busca la caratula oficial de la cancion (Apple Music, luego TIDAL) y, si coincide, sustituye a la de YouTube.
    @discardableResult
    private func fetchHighQualityCover(videoId: String) -> Task<Void, Never>? {
        guard SettingsStore.shared.preferAppleCovers else { return nil }
        return Task {
            guard let song = await MainActor.run(body: { self.queueSongs.first { $0.videoId == videoId } }) else { return }
            // Solo si la que tiene es mala (fotograma de video...): si ya trae su caratula de album, se queda con ella.
            guard AudioCounterpartStore.hasPoorCover(song) else { return }
            // La oficial de Apple Music / TIDAL; si no hay, y la cancion es un video, la de su version de audio.
            var coverURL = await AnimatedArtworkService.shared.info(for: song)?.cover
            if coverURL == nil, AudioCounterpartStore.isVideoType(song) || song.isVideo == true {
                coverURL = await AudioCounterpartStore.shared.coverURL(for: song.videoId)
            }
            guard let coverURL, let image = try? await ArtworkLoader.image(for: coverURL) else { return }
            await MainActor.run {
                guard self.lastLoadedVideoId == videoId else { return }
                self.highQualityCoverFor = videoId
                self.publishArtwork(image, highQuality: true)
            }
        }
    }

    private func loadThumbnail(videoId: String, thumbnailUrl: String? = nil) {
        guard videoId != lastLoadedVideoId else { return }
        lastLoadedVideoId = videoId
        highQualityCoverFor = nil
        let highQuality = fetchHighQualityCover(videoId: videoId)
        // Si la carátula buena ya se conoce (de otra vez), se pinta ella sola: no se ve primero la de YouTube y luego la otra.
        let queued = queueSongs.first { $0.videoId == videoId }
        let knownHighQuality = SettingsStore.shared.preferAppleCovers
            && (queued.map(AudioCounterpartStore.hasPoorCover) ?? false)
            && (AnimatedArtworkService.shared.cachedInfo(forVideoId: videoId)?.cover != nil)
        // Safety net: callers that resolve without song metadata pass nil.
        // The queue usually still knows this track's artwork — use it rather
        // than falling back to the low-res ytimg default.
        var thumb = thumbnailUrl
        if thumb == nil {
            thumb = queueSongs.first { $0.videoId == videoId }?.thumbnailUrl
        }

        Task {
            if knownHighQuality, let highQuality {
                await highQuality.value
                guard self.lastLoadedVideoId == videoId, self.highQualityCoverFor != videoId else { return }
            }
            // For downloaded songs, try to extract embedded artwork from the local file first.
            if let localURL = await DownloadManager.shared.localURL(for: videoId) {
                loadArtworkFromLocalFile(localURL, videoId: videoId, thumbnailUrl: thumb)
                return
            }
            loadThumbnailFromCDN(videoId: videoId, thumbnailUrl: thumb)
        }
    }

    private func loadArtworkFromLocalFile(_ fileURL: URL, videoId: String, thumbnailUrl: String? = nil) {
        Task {
            let asset = AVURLAsset(url: fileURL)
            let metadata = try? await asset.load(.metadata)
            var artworkImage: UIImage?
            if let metadata {
                for item in metadata {
                    if let data = try? await item.load(.dataValue),
                       let image = UIImage(data: data) {
                        artworkImage = image
                        break
                    }
                }
            }

            await MainActor.run {
                guard lastLoadedVideoId == videoId else { return }
                if let artworkImage {
                    publishArtwork(artworkImage)
                    // La imagen incrustada al descargar suele ser pequena: si lo es, se pide la buena
                    // por encima, sin quitar la actual (y sin red se queda la incrustada).
                    let side = min(artworkImage.size.width, artworkImage.size.height) * artworkImage.scale
                    if side < 900 {
                        loadThumbnailFromCDN(videoId: videoId, thumbnailUrl: thumbnailUrl, upgradeOnly: true)
                    }
                } else {
                    loadThumbnailFromCDN(videoId: videoId, thumbnailUrl: thumbnailUrl)
                }
            }
        }
    }

    /// Publishes a loaded image as the current artwork (cropped square).
    private func publishArtwork(_ image: UIImage, highQuality: Bool = false) {
        if !highQuality, let id = highQualityCoverFor, id == lastLoadedVideoId { return }
        let cropped = image.centerCroppedSquare()
        thumbnailUIImage = cropped
        thumbnailImage = Image(uiImage: cropped)
        thumbnailVersion &+= 1
        updateDominantColors(from: cropped)
        PlayerController.shared.updateNowPlayingArtwork()
    }

    private func loadThumbnailFromCDN(videoId: String, thumbnailUrl: String? = nil, upgradeOnly: Bool = false) {
        // Best source first: the track's own artwork upgraded to full
        // resolution, then ytimg step-downs, then the guaranteed hqdefault.
        var candidates: [String] = []
        if let upgraded = ArtworkURLs.highRes(thumbnailUrl) {
            if let maxRes = ArtworkURLs.maxResVariant(upgraded) {
                candidates.append(maxRes)
            }
            if let standard = ArtworkURLs.sdVariant(upgraded) {
                candidates.append(standard)
            }
            candidates.append(upgraded)
        }
        let fallback = Self.artworkURL(for: videoId)
        if !candidates.contains(fallback) {
            candidates.append(fallback)
        }
        let urls = candidates.compactMap(URL.init(string:))
        guard !urls.isEmpty else {
            thumbnailUIImage = nil
            thumbnailImage = Image(systemName: "music.note")
            thumbnailVersion &+= 1
            updateDominantColors(from: nil)
            return
        }

        // Phase 1: instant paint from the best cached candidate. A lesser
        // cached variant must not shadow a better one — Phase 2 upgrades.
        var paintedIndex: Int?
        if !upgradeOnly {
            for (index, url) in urls.enumerated() {
                if let cached = ArtworkLoader.cachedImage(for: url) {
                    publishArtwork(cached)
                    paintedIndex = index
                    break
                }
            }
        }

        // Phase 2: fetch candidates better than the painted one (or all of
        // them when nothing was painted). First success wins and swaps in.
        let fetchCount = paintedIndex ?? urls.count
        if fetchCount == 0 {
            return
        }
        if paintedIndex == nil, !upgradeOnly {
            thumbnailImage = nil
        }
        Task {
            for url in urls.prefix(fetchCount) {
                guard lastLoadedVideoId == videoId else { return }
                do {
                    let platformImage = try await ArtworkLoader.image(for: url)
                    await MainActor.run {
                        guard self.lastLoadedVideoId == videoId else { return }
                        self.publishArtwork(platformImage)
                    }
                    return
                } catch {
                    continue
                }
            }
            if paintedIndex == nil, !upgradeOnly {
                await MainActor.run {
                    guard self.lastLoadedVideoId == videoId else { return }
                    thumbnailImage = Image(systemName: "music.note")
                    thumbnailVersion &+= 1
                    updateDominantColors(from: nil)
                }
            }
        }
    }

    private func preloadNextTrack() {
        guard hasNext else { return }
        let nextId = queueSongs[queueIndex + 1].videoId
        SponsorBlockIntegration.shared.warm(for: nextId)
        loggedTask(Log.nowPlaying, "Pre-resolve failed") {
            _ = try await PlaybackManager.shared.resolve(videoId: nextId)
            Log.nowPlaying.debug("Pre-resolved next track: \(nextId)")
        }
    }

    private func startTimer() {
        stopTimer()
        // Add to `.common` so progress keeps updating while the user scrolls
        // or drags the slider (the default mode pauses the timer).
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.timerTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @MainActor
    private func timerTick() {
        // Solo se asigna si cambia: cada asignacion avisa a las vistas que leen estos valores.
        let position = PlayerController.shared.currentTime
        AutoMixEngine.shared.tick(position: position)
        if position != currentTime { currentTime = position }
        let length = PlayerController.shared.duration
        if length != duration { duration = length }
        tickCount &+= 1
        // El sistema extrapola la posicion con la velocidad: basta con avisarle una vez por segundo.
        PlayerController.shared.updateNowPlayingProgress(publishToSystem: tickCount % 4 == 0)
        SponsorBlockIntegration.shared.tick()
        if tickCount % 20 == 0 { extendQueueIfNeeded() }
        // Cada 2 s basta (el almacen ya limita las escrituras): evita crear una tarea cuatro veces por segundo.
        if tickCount % 8 == 0, let videoId, duration >= 600 || musicVideoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" {
            let vid = videoId
            let pos = currentTime
            let dur = duration
            Task {
                await EpisodePlaybackStore.shared.savePosition(videoId: vid, position: pos, duration: dur)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Un color vivo y claro con el tono de la carátula, para usarlo de acento sobre el fondo oscuro de la app (con texto
    /// blanco encima). Si la carátula es casi gris o blanca y negra no hay tono que seguir: `nil` (se usa el elegido).
    static func accentFrom(_ colors: [Color]) -> Color? {
        guard let first = colors.first else { return nil }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(first).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation > 0.22 else { return nil }
        let vividSaturation = min(1, max(saturation * 1.1, 0.5))
        let lightBrightness = min(0.95, max(brightness, 0.78))
        return Color(hue: Double(hue), saturation: Double(vividSaturation), brightness: Double(lightBrightness))
    }

    @MainActor
    private func updateDominantColors(from uiImage: UIImage?) {
        guard let uiImage = uiImage else {
            self.dominantColors = [Color(red: 0.15, green: 0.15, blue: 0.2), Color(red: 0.05, green: 0.05, blue: 0.08)]
            self.artworkEdgeColor = nil
            SettingsStore.shared.setDynamicAccent(nil)
            return
        }
        self.dominantColors = uiImage.extractDominantColors()
        self.artworkEdgeColor = uiImage.bottomEdgeColor()
        SettingsStore.shared.setDynamicAccent(Self.accentFrom(self.dominantColors))
    }
}

// MARK: - Module-level artist name cleaner

/// Builds a clean, comma-separated artist string from an artist array, dropping
/// names that clean down to empty (junk/blank entries) so no dangling separator
/// is left behind.
func artistDisplayString(from artists: [YTArtist]) -> String {
    artists
        .map { cleanArtistDisplay($0.name) }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
}

func cleanArtistDisplay(_ name: String) -> String {
    var tempName = name

    // Strip " - Topic"
    for suffix in [" - Topic", " - topic", " - TOPIC"] where tempName.lowercased().hasSuffix(suffix.lowercased()) {
        tempName = String(tempName.dropLast(suffix.count))
    }

    // Strip trailing year "(2025)" / "[2025]"
    if let r = try? NSRegularExpression(pattern: "\\s*[\\(\\[]\\d{4}[\\)\\]]\\s*$") {
        tempName = r.stringByReplacingMatches(
            in: tempName,
            range: NSRange(tempName.startIndex..., in: tempName),
            withTemplate: ""
        )
    }

    // Split on commas, ampersands, and bullet separators (•, ·, |) then drop junk segments
    let separatorSet = CharacterSet(charactersIn: ",&•·|")
    let parts = tempName
        .components(separatedBy: separatorSet)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    let cleanParts = parts.filter { !_isJunkArtistSegment($0) }
    if cleanParts.isEmpty {
        return ""
    }
    return cleanParts.joined(separator: ", ")
}

private func _isJunkArtistSegment(_ segment: String) -> Bool {
    let lower = segment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if lower.isEmpty || lower == "•" || lower == "·" { return true }

    let junkLabels: Set<String> = [
        "song", "video", "track", "music", "podcast", "episode",
        "album", "playlist", "released", "year", "plays", "views",
        "downloads", "listeners", "subscribers", "watchers", "likes"
    ]
    if junkLabels.contains(lower) { return true }

    let patterns = [
        // Number optionally followed by K/M/B/T and an optional metric word
        "^[\\d,\\.]+[KMBT]?\\s*(views|downloads|listeners|subscribers|plays|watchers|likes?)?$",
        "^\\d{4}$",              // bare year
        "^[\\d,\\.\\s]+[KMBT]?$" // purely numeric / abbreviated counts
    ]
    for pattern in patterns where lower.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
        return true
    }
    return false
}
