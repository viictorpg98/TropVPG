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
    var isPlaying = false {
        didSet {
            // Al volver a sonar, el temporizador vuelve al ritmo normal sin esperar a su siguiente aviso.
            if isPlaying, !oldValue, timer != nil, timerInterval > 0.25 { startTimer(interval: 0.25) }
        }
    }
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
    /// Cuando se toco por ultima vez una cancion de la cola (el reproductor no cierra la cola por ese cambio).
    var lastQueueTap = Date.distantPast
    /// Cancion cuyos datos ya enseña la pantalla pero cuyo audio aun se esta cargando (tocada o saltada con poca cobertura):
    /// el reproductor enseña una rueda en vez del boton de pausa, y mientras tanto sigue sonando la anterior.
    var loadingTrackId: String?
    /// La rueda solo se ve si la carga tarda (mas de ~1 s): en un cambio normal de cancion no parpadea.
    private var loadingSpinnerShown = false
    var isLoadingTrack: Bool { loadingSpinnerShown && loadingTrackId != nil }

    /// Una lista, Inicio o Buscar pidieron sonar `videoId`: hasta que cargue su direccion la pantalla sigue con la anterior,
    /// asi que mientras tanto se ve la rueda (y, si tarda, el aviso de poca cobertura).
    func beginLoadingFeedback(videoId: String) {
        loadingTrackId = videoId
        startSlowLoadWatch(for: videoId)
    }
    private var networkRefreshTask: Task<Void, Never>?

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
    private var timerInterval: TimeInterval = 0.25
    private var tickCount = 0
    var lastManualSkipTime: Date?
    /// Cuantas canciones se estan cargando a la vez (si se salta rapido puede haber varias; la ultima es la que cuenta).
    private var resolvingCount = 0
    private var isResolvingNext: Bool { resolvingCount > 0 }
    /// Hay una cancion cargandose (AutoMix no empieza mezclas mientras tanto).
    var isBusyResolving: Bool { isResolvingNext }
    /// Timestamps of the last mid-play failure per videoId, to bound retries.
    private var lastFailureAt: [String: Date] = [:]
    /// Canciones seguidas que se han saltado por no poder reproducirse (se para a las 3 para no recorrer toda la cola).
    private var unplayableSkips = 0
    private var lastUnplayableSkip = Date.distantPast

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
        QueueChipsStore.shared.clear()
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
                // Tambien en el orden original (si hay aleatorio), para que al quitarlo la cancion se siga encontrando.
                if let position = originalQueue?.firstIndex(where: { $0.videoId == songs[index].videoId }) {
                    originalQueue?[position] = swapped
                }
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
        let smart = SettingsStore.shared.smartShuffle
        if smart { rest = Self.spreadArtists(rest, after: current) }
        queueSongs = prefix + [current] + rest
        queueIndex = prefix.count
        isShuffleOn = true
        persistQueueState()
        if smart { applyShuffleHistory() }
    }

    /// Aleatorio inteligente: lo que escuchaste en los ultimos dias pasa al final de lo que viene (con tu historial local).
    private func applyShuffleHistory() {
        let snapshot = queueSongs.map(\.videoId)
        Task { @MainActor in
            let played = await OfflineMix.lastPlayedDates()
            guard self.isShuffleOn, self.queueSongs.map(\.videoId) == snapshot,
                  self.queueSongs.indices.contains(self.queueIndex) else { return }
            let cut = Date().addingTimeInterval(-3 * 86_400)
            let head = Array(self.queueSongs.prefix(self.queueIndex + 1))
            let rest = Array(self.queueSongs.dropFirst(self.queueIndex + 1))
            let fresh = rest.filter { (played[$0.videoId] ?? .distantPast) <= cut }
            let recent = rest
                .filter { (played[$0.videoId] ?? .distantPast) > cut }
                .sorted { (played[$0.videoId] ?? .distantPast) < (played[$1.videoId] ?? .distantPast) }
            guard !recent.isEmpty else { return }
            let ordered = Self.spreadArtists(fresh, after: head.last) + Self.spreadArtists(recent, after: fresh.last)
            self.queueSongs = head + ordered
            self.persistQueueState()
        }
    }

    /// Separa las canciones del mismo artista: ninguna sigue a otra suya si mas adelante hay una de otro artista.
    static func spreadArtists(_ songs: [SongItem], after previous: SongItem?) -> [SongItem] {
        func key(_ song: SongItem?) -> String? {
            guard let artist = song?.artists.first else { return nil }
            return artist.id ?? artist.name.lowercased()
        }
        var result = songs
        var last = key(previous)
        for index in result.indices {
            if let last, key(result[index]) == last,
               let other = result.indices.dropFirst(index + 1).first(where: { key(result[$0]) != last }) {
                result.swapAt(index, other)
            }
            last = key(result[index])
        }
        return result
    }

    /// Quita lo que viene despues de la que suena.
    func clearUpcoming() {
        guard queueSongs.indices.contains(queueIndex) else { return }
        queueSongs = Array(queueSongs.prefix(queueIndex + 1))
        persistQueueState()
    }

    /// Quita las canciones repetidas (se queda la primera; la que suena no se toca). Devuelve cuantas quito.
    @discardableResult
    func removeDuplicateSongs() -> Int {
        var seen = Set<String>()
        var result: [SongItem] = []
        var newIndex = queueIndex
        for (index, song) in queueSongs.enumerated() {
            if seen.insert(song.videoId).inserted || index == queueIndex {
                result.append(song)
            }
            if index == queueIndex { newIndex = result.count - 1 }
        }
        let removed = queueSongs.count - result.count
        guard removed > 0 else { return 0 }
        queueSongs = result
        queueIndex = newIndex
        persistQueueState()
        return removed
    }

    /// Restore the original (unshuffled) queue order.
    func disableShuffle() {
        guard queueSongs.indices.contains(queueIndex) else { return }
        if let orig = originalQueue {
            let currentVideoId = queueSongs[queueIndex].videoId
            // Se concilia el orden original con lo que hay ahora: lo que se quito mientras estaba barajado no vuelve y lo
            // que se añadio (la cola infinita...) va al final.
            let currentIds = Set(queueSongs.map(\.videoId))
            let originalIds = Set(orig.map(\.videoId))
            let restored = orig.filter { currentIds.contains($0.videoId) }
                + queueSongs.filter { !originalIds.contains($0.videoId) }
            queueSongs = restored
            queueIndex = restored.firstIndex(where: { $0.videoId == currentVideoId })
                ?? min(queueIndex, max(restored.count - 1, 0))
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

    /// La cola con otro orden (arrastrando el asa de una fila). Las canciones son las mismas.
    func reorderQueue(_ songs: [SongItem]) {
        guard songs.count == queueSongs.count else { return }
        queueSongs = songs
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
        // El paso automatico espera a que termine la carga en curso; los toques del usuario no se ignoran.
        if automatic, isResolvingNext { return }
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
        // Pasados unos segundos, "anterior" vuelve al principio de la cancion (como en Apple Music y YouTube Music).
        if currentTime > 3, queueSongs.indices.contains(queueIndex) {
            PlayerController.shared.seek(to: 0)
            currentTime = 0
            PlayerController.shared.updateNowPlayingProgress()
            return
        }
        guard hasPrevious else { return }
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
            resolvingCount += 1
        }
        let song = queueSongs[queueIndex]
        update(with: song)
        loadingTrackId = song.videoId
        startSlowLoadWatch(for: song.videoId)
        persistQueueState()
        WaveformStore.shared.songStarted(
            current: song.videoId,
            upcoming: queueSongs.dropFirst(queueIndex + 1).map(\.videoId)
        )
        Task {
            var failedToPlay = false
            let requestStarted = Date()
            do {
                try await PlaybackManager.shared.resolveAndPlay(videoId: song.videoId, startAt: startAt, onlyIfCurrent: true)
            } catch {
                Log.nowPlaying.error("\(logContext) failed: \(error)")
                self.trackLoadFinished(videoId: song.videoId)
                if self.videoId == song.videoId {
                    isPlaying = false
                    // Un fallo por mala cobertura o por un cambio de red no es de la cancion: no se salta a la siguiente
                    // (fallaria igual y se recorreria la cola); se queda para volver a tocarla.
                    // Si todos los clientes de YouTube fallan por falta de cobertura el error no siempre dice "red": se
                    // cuenta tambien el tiempo (10 s o mas esperando = cobertura, no una cancion imposible).
                    let slowFailure = Date().timeIntervalSince(requestStarted) >= 10
                    let connectionProblem = !(error is CancellationError) && (self.isConnectionProblem(error) || slowFailure)
                    if connectionProblem { PlaybackReport.record("carga: \(song.videoId) fallo por la conexion, no se salta (\(error.localizedDescription))") }
                    failedToPlay = !(error is CancellationError) && logContext == "playNext" && !connectionProblem
                }
            }
            if manageResolvingFlag {
                resolvingCount = max(0, resolvingCount - 1)
            }
            afterResolve?()
            if failedToPlay {
                self.skipUnplayable(song.videoId)
                return
            }
            await self.verifyPlaybackStarted(song.videoId, startAt: startAt, logContext: logContext)
        }
    }

    // MARK: - Carga lenta y cambios de red

    /// El audio de `videoId` ya esta cargado (o fallo): se quita la rueda.
    func trackLoadFinished(videoId: String?) {
        if videoId == nil || loadingTrackId == videoId {
            loadingTrackId = nil
            loadingSpinnerShown = false
        }
    }

    /// Con poca cobertura la carga tarda: al segundo y poco sale la rueda, a los 5 s un aviso de que sigue cargando y a los 45 s
    /// se quita la rueda (nunca gira para siempre).
    private func startSlowLoadWatch(for videoId: String) {
        loadingSpinnerShown = false
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.loadingTrackId == videoId else { return }
            self.loadingSpinnerShown = true
            try? await Task.sleep(nanoseconds: 3_800_000_000)
            guard self.loadingTrackId == videoId else { return }
            PlaybackReport.record("carga lenta: \(videoId) sigue cargando tras 5 s")
            PlaybackNotice.shared.show(NSLocalizedString("Weak connection: still loading this song…", comment: ""))
            try? await Task.sleep(nanoseconds: 40_000_000_000)
            guard self.loadingTrackId == videoId else { return }
            PlaybackReport.record("carga lenta: \(videoId) sigue sin cargar tras 45 s")
            self.trackLoadFinished(videoId: videoId)
        }
    }

    /// El fallo es de la conexion (sin cobertura, corte, cambio de Wi-Fi a datos) y no de la cancion.
    private func isConnectionProblem(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if NetworkMonitor.shared.changedInterfaceRecently { return true }
        let codes: Set<Int> = [
            NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorDataNotAllowed
        ]
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && codes.contains(nsError.code)
    }

    /// Pide a iOS unos segundos mas en segundo plano para que una recuperacion tras un fallo de red pueda terminar.
    private func beginRecoveryTime(_ name: String) -> UIBackgroundTaskIdentifier {
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: name) {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        return task
    }

    private func endRecoveryTime(_ task: UIBackgroundTaskIdentifier) {
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }

    /// El telefono paso de Wi-Fi a datos (o al reves). Las direcciones guardadas de googlevideo llevan la IP publica de quien
    /// las pidio, asi que se olvidan; y la que suena se vuelve a pedir y se sigue por donde iba (si no, el audio se corta cuando
    /// se acaba lo que ya tenia cargado, a veces con el telefono bloqueado y sin que la app pueda recuperarse).
    func networkInterfaceChanged(from old: String, to new: String) {
        PlaybackReport.record("red: cambio de \(old) a \(new)")
        Task { await StreamCache.shared.clear() }
        networkRefreshTask?.cancel()
        networkRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.refreshCurrentStreamAfterNetworkChange()
        }
    }

    private func refreshCurrentStreamAfterNetworkChange() {
        // Solo si suena en streaming. Una mezcla de AutoMix suena desde un archivo local, y una descargada no necesita red.
        guard isPlaying, let current = videoId, queueSongs.indices.contains(queueIndex),
              queueSongs[queueIndex].videoId == current,
              !AutoMixEngine.shared.isActive,
              !DownloadManager.shared.isDownloaded(videoId: current),
              PlayerController.shared.currentVideoId == current,
              PlayerController.shared.gaplessStage == 0 else { return }
        let resumeAt = currentTime > 3 ? currentTime : 0
        PlaybackReport.record("red: se pide de nuevo la direccion de \(current) y se sigue en \(Int(resumeAt)) s")
        let recoveryTime = beginRecoveryTime("sonar-network-refresh")
        Task {
            defer { self.endRecoveryTime(recoveryTime) }
            await StreamCache.shared.remove(videoId: current)
            _ = try? await PlaybackManager.shared.resolveAndPlay(videoId: current, startAt: resumeAt)
        }
    }

    /// Una cancion que no se ha podido abrir con ningun cliente de YouTube: pasa a la siguiente en vez de quedarse parada
    /// (hasta 3 seguidas; sin conexion no se salta nada).
    private func skipUnplayable(_ videoId: String) {
        guard self.videoId == videoId, hasNext, NetworkMonitor.shared.hasConnection else { return }
        if NetworkMonitor.shared.changedInterfaceRecently {
            PlaybackReport.record("reproductor: \(videoId) fallo justo tras cambiar de red, no se salta a la siguiente")
            trackLoadFinished(videoId: videoId)
            PlaybackNotice.shared.show(NSLocalizedString("Couldn't play this. Try again.", comment: ""))
            return
        }
        if Date().timeIntervalSince(lastUnplayableSkip) > 90 { unplayableSkips = 0 }
        guard unplayableSkips < 3 else { return }
        unplayableSkips += 1
        lastUnplayableSkip = Date()
        PlaybackReport.record("reproductor: \(videoId) no se pudo reproducir, se pasa a la siguiente")
        PlaybackNotice.shared.show(NSLocalizedString("Couldn't play this song. Skipping to the next one.", comment: ""))
        playNext(automatic: true)
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
            // Lo ya escuchado mas alla de las ultimas 50 se quita (la cola no crece sin limite; con aleatorio no se toca).
            if !self.isShuffleOn, self.originalQueue == nil, self.queueIndex > 100 {
                let drop = self.queueIndex - 50
                self.queueSongs.removeFirst(drop)
                self.queueIndex -= drop
            }
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
            skipUnplayable(videoId)
            return
        }
        lastFailureAt[videoId] = Date()
        // Si el fallo fue a mitad de la cancion, se retoma por donde iba (con un segundo de margen).
        let resumeAt = currentTime > 5 ? currentTime - 1 : 0
        PlaybackReport.record("reproductor: \(videoId) no cargo, se pide de nuevo comprobando todas las direcciones")
        isPlaying = false
        Log.nowPlaying.notice("Stream failed mid-play, re-resolving \(videoId)")
        // Con la pantalla bloqueada el audio parado deja dormir a la app: se pide tiempo para que la recuperacion termine.
        let recoveryTime = beginRecoveryTime("sonar-recover")
        Task {
            defer { self.endRecoveryTime(recoveryTime) }
            await PlayerConfigStore.shared.notifyStreamRejection()
            await PlaybackManager.shared.noteStreamFailure(videoId: videoId)
            await StreamCache.shared.remove(videoId: videoId)
            // Si la direccion fallo, el reintento comprueba todas las direcciones antes de usar ninguna
            // (si no, podia repetir la misma direccion mala del mismo cliente).
            await PlaybackManager.shared.requireValidatedChain(for: videoId)
            do {
                try await PlaybackManager.shared.resolveAndPlay(videoId: videoId, startAt: resumeAt)
                // Success – allow future retries for this video
                _ = await MainActor.run { self.lastFailureAt.removeValue(forKey: videoId) }
            } catch {
                Log.nowPlaying.error("Mid-play recovery failed: \(error)")
                self.trackLoadFinished(videoId: videoId)
                if self.videoId == videoId {
                    isPlaying = false
                    if !(error is CancellationError) { self.skipUnplayable(videoId) }
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

    private func startTimer(interval: TimeInterval = 0.25) {
        stopTimer()
        timerInterval = interval
        // Add to `.common` so progress keeps updating while the user scrolls
        // or drags the slider (the default mode pauses the timer).
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // El temporizador ya corre en el hilo principal: no hace falta crear una tarea en cada aviso.
            MainActor.assumeIsolated { self?.timerTick() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @MainActor
    private func timerTick() {
        // Solo se asigna si cambia: cada asignacion avisa a las vistas que leen estos valores.
        // En pausa o con la app en segundo plano no hace falta mirar cuatro veces por segundo (menos despertares, menos bateria).
        // AutoMix no lo necesita: prepara la mezcla con mas de 7 s de margen y la ejecuta con su propio temporizador.
        let wanted: TimeInterval = !isPlaying ? 1.0 : (UIApplication.shared.applicationState == .active ? 0.25 : 0.5)
        if wanted != timerInterval {
            // Los contadores de abajo cuentan "cuartos de segundo": se alinean al cambiar de ritmo.
            tickCount = (tickCount + 3) & ~3
            startTimer(interval: wanted)
        }
        let position = PlayerController.shared.currentTime
        AutoMixEngine.shared.tick(position: position)
        if position != currentTime { currentTime = position }
        let length = PlayerController.shared.duration
        if length != duration { duration = length }
        tickCount &+= max(1, Int((timerInterval / 0.25).rounded()))
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

    @MainActor
    private func updateDominantColors(from uiImage: UIImage?) {
        guard let uiImage = uiImage else {
            self.dominantColors = [Color(red: 0.15, green: 0.15, blue: 0.2), Color(red: 0.05, green: 0.05, blue: 0.08)]
            self.artworkEdgeColor = nil
            return
        }
        self.dominantColors = uiImage.extractDominantColors()
        self.artworkEdgeColor = uiImage.bottomEdgeColor()
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
