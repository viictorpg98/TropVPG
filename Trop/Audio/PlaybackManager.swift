//
//  PlaybackManager.swift
//  Trop
//
//  Created by 686udjie on 29/06/2026.
//

import Foundation
import UIKit

/// Resolves streams and hands off to PlayerController, trying the client fallback chain.
actor PlaybackManager {
    static let shared = PlaybackManager()

    private var inflightResolutions: [String: Task<PlaybackResult, Error>] = [:]
    /// Canciones cuya resolucion en curso SI va a reproducirse al terminar (la lanzo `resolveAndPlay`). Las otras
    /// (`resolve`: onda de la barra, analisis de AutoMix...) solo piden la direccion y no reproducen nada.
    private var playingResolutions: Set<String> = []
    /// Canciones cuya direccion no se pudo pedir con ningun cliente (muchas UGC dan 403): quienes la piden solo para analizar
    /// o sacar la onda no vuelven a intentarlo hasta pasado un tiempo que crece con cada fallo (2, 4, 8... hasta 30 min).
    private var resolveFailures: [String: (count: Int, until: Date)] = [:]
    private static let lastClientKey = "playback.lastWorkingClient"
    /// Desde esta duracion un contenido se trata como "largo" (podcasts, directos grabados...).
    private static let longContentSeconds = 20 * 60

    private func resolutionKey(videoId: String, forDownload: Bool) -> String {
        forDownload ? "\(videoId):download" : videoId
    }

    private init() {}

    /// Resolve a video and start playback. Returns the result used, or throws.
    /// `onlyIfCurrent`: la pide quien eligio la cancion (tocar, saltar). Con poca cobertura la direccion puede tardar
    /// medio minuto; si mientras tanto se eligio otra, esta ya no se pone a sonar (antes pisaba a la nueva: la pantalla
    /// ensenaba una y sonaba otra).
    @discardableResult
    func resolveAndPlay(videoId: String, startAt: TimeInterval = 0, onlyIfCurrent: Bool = false) async throws -> PlaybackResult {
        await MainActor.run { SponsorBlockIntegration.shared.warm(for: videoId) }
        if let localPath = await DownloadManager.shared.localURL(for: videoId) {
            let song = await MainActor.run { NowPlaying.shared.queueSongs.first { $0.videoId == videoId } }
            let artists = song?.artists ?? []
            await PlayerController.shared.play(
                url: localPath.absoluteString,
                title: song?.title,
                artist: song?.artists.map(\.name).joined(separator: ", "),
                videoId: videoId,
                duration: song.map { TimeInterval($0.duration) },
                artists: artists,
                thumbnailUrl: song?.thumbnailUrl,
                startAt: startAt
            )
            await MainActor.run {
                NowPlaying.shared.updateVideoAvailability()
            }
            return PlaybackResult(
                streamUrl: localPath.absoluteString,
                itag: 0,
                mimeType: "audio/mp4",
                bitrate: 0,
                audioQuality: "local",
                videoId: videoId,
                title: song?.title,
                author: song?.artists.map(\.name).joined(separator: ", "),
                duration: song?.duration,
                expiresInSeconds: Int.max,
                clientName: "local",
                musicVideoType: nil,
                hasVideoContent: false,
                muxedStreamUrl: nil,
                loudnessDb: nil
            )
        }

        await purgeStaleLongCache(videoId)
        if let cached = await StreamCache.shared.get(videoId: videoId) {
            clientUsed[videoId] = cached.clientName
            let queueSong = await queueSong(for: videoId)
            await PlayerController.shared.play(
                url: cached.streamUrl,
                title: cached.title,
                artist: cached.author,
                videoId: videoId,
                duration: cached.duration.flatMap { $0 > 0 ? TimeInterval($0) : nil },
                artists: queueSong?.artists ?? [],
                loudnessDb: cached.loudnessDb,
                thumbnailUrl: queueSong?.thumbnailUrl,
                startAt: startAt
            )
            await publishVideoAvailability(result: cached, videoId: videoId, rowType: queueSong?.musicVideoType)
            return cached
        }

        if let existing = inflightResolutions[videoId] {
            let existingPlays = playingResolutions.contains(videoId)
            let result = try await existing.value
            if !existingPlays {
                // La resolucion en curso solo pedia la direccion (onda, analisis de AutoMix...) y no reproduce: antes se
                // devolvia sin mas y la cancion elegida no sonaba. Se reproduce aqui el resultado.
                PlaybackReport.record("reproducir \(videoId): se unio a una resolucion que no reproducia, se reproduce ahora")
                if await isNoLongerChosen(videoId, onlyIfCurrent: onlyIfCurrent) { return result }
                await playNetworkResult(result, videoId: videoId, startAt: startAt)
            }
            return result
        }

        let task = Task { [self] in
            try await resolveAndPlayFromNetwork(videoId: videoId, startAt: startAt, onlyIfCurrent: onlyIfCurrent)
        }
        inflightResolutions[videoId] = task
        playingResolutions.insert(videoId)
        defer {
            clearInflight(key: videoId)
            playingResolutions.remove(videoId)
        }
        do {
            return try await task.value
        } catch {
            await MainActor.run { NowPlaying.shared.trackLoadFinished(videoId: videoId) }
            await reportPlaybackFailure(error)
            throw error
        }
    }

    /// Avisa de que no se ha podido reproducir: antes el fallo solo quedaba en el registro y al pulsar
    /// parecia que no pasaba nada.
    private func reportPlaybackFailure(_ error: Error) async {
        if error is CancellationError { return }
        PlaybackReport.record("FALLO al resolver: \(error.localizedDescription)")
        let message: String
        if let streamError = error as? StreamError, case .unplayable(let reason) = streamError,
           reason.lowercased().contains("premiere") || reason.lowercased().contains("live") {
            message = String(format: NSLocalizedString("Can't play this yet: %@", comment: ""), reason)
        } else {
            message = NSLocalizedString("Couldn't play this. Try again.", comment: "")
        }
        await MainActor.run {
            // Si la reproduccion la lanzo un atajo o Siri (app en segundo plano) no se enseña nada.
            guard UIApplication.shared.applicationState == .active else { return }
            PlaybackNotice.shared.show(message)
        }
    }

    /// Runs the client fallback chain for playback. Only called once per
    /// videoId by `resolveAndPlay`, which owns the in-flight dedup entry.
    private func resolveAndPlayFromNetwork(
        videoId: String,
        startAt: TimeInterval = 0,
        onlyIfCurrent: Bool = false
    ) async throws -> PlaybackResult {
        var request = StreamResolveRequest.playback(videoId: videoId)
        request.options.audioQuality = SettingsStore.shared.audioQuality
        let started = Date()
        let isLong = Self.isLong(await queueSong(for: videoId)) || requireValidation.contains(videoId)
        PlaybackReport.record("pedir \(videoId) largo=\(isLong)")
        if !isLong, let last = UserDefaults.standard.string(forKey: Self.lastClientKey),
           let index = request.chain.firstIndex(where: { $0.client.clientName == last }), index > 0 {
            // Prueba primero el cliente que funciono la ultima vez: si los de delante fallan, cada fallo
            // es una peticion de red perdida antes de que suene nada.
            request.chain.insert(request.chain.remove(at: index), at: 0)
        }
        let fullChain = request.chain
        request.chain = filteredChain(request.chain)
        let result: PlaybackResult
        if isLong {
            result = try await resolveLongContent(videoId: videoId, request: request)
        } else {
            do {
                result = try await StreamFallback.resolveFirstValid(
                    request,
                    using: InnerTubeClient.tropShared,
                    providers: .tropLive
                )
            } catch {
                // Sin los clientes descartados no hubo direccion: se prueba con todos.
                guard request.chain.count != fullChain.count else { throw error }
                request.chain = fullChain
                result = try await StreamFallback.resolveFirstValid(
                    request,
                    using: InnerTubeClient.tropShared,
                    providers: .tropLive
                )
            }
        }
        PlaybackReport.record("direccion de \(videoId): cliente \(result.clientName) en \(Int(Date().timeIntervalSince(started) * 1000)) ms, \(result.mimeType)")
        // Lo que funciona para un podcast no dice nada de la musica: no se recuerda.
        if !isLong { UserDefaults.standard.set(result.clientName, forKey: Self.lastClientKey) }
        if await isNoLongerChosen(videoId, onlyIfCurrent: onlyIfCurrent) { return result }
        await playNetworkResult(result, videoId: videoId, startAt: startAt)
        return result
    }

    /// Mientras se pedia la direccion de `videoId` se eligio otra cancion: no se pone a sonar (la direccion queda guardada).
    private func isNoLongerChosen(_ videoId: String, onlyIfCurrent: Bool) async -> Bool {
        guard onlyIfCurrent else { return false }
        // La elegida es la que ocupa ahora el sitio actual de la cola (al tocar en una lista la pantalla aun ensena la anterior).
        let chosen = await MainActor.run { () -> String? in
            let np = NowPlaying.shared
            return np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex].videoId : nil
        }
        guard chosen != videoId else { return false }
        PlaybackReport.record("reproducir \(videoId): ya no es la cancion elegida (ahora \(chosen ?? "ninguna")), no se pone a sonar")
        return true
    }

    /// Podcasts y contenidos largos: se prueban los clientes en su orden de siempre, pero comprobando
    /// TODAS las direcciones antes de usarlas y apuntando en el informe que pasa con cada uno.
    /// Con la cadena normal, WEB_REMIX y iOS se dan por buenos sin comprobar, y para podcasts WEB_REMIX
    /// devuelve una direccion que el reproductor no puede cargar ("loading failed"): se tomaba por buena
    /// y no se probaban los demas clientes.
    private func resolveLongContent(videoId: String, request: StreamResolveRequest) async throws -> PlaybackResult {
        if request.policy.useCache, let cached = await StreamCache.shared.get(videoId: videoId) {
            return cached
        }
        let providers = StreamResolveProviders.tropLive
        var tokenTask: Task<PoTokenResult?, Never>?
        if request.chain.contains(where: { $0.client.useWebPoTokens }) {
            tokenTask = Task { await providers.poTokenProvider?(videoId) }
        }
        defer { tokenTask?.cancel() }

        var lastError: Error?
        for entry in request.chain {
            let started = Date()
            func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
            var options = request.options
            if entry.client.useWebPoTokens, let tokenTask {
                let minted = await tokenTask.value
                options.poToken = minted?.playerRequestPoToken ?? options.poToken
                options.streamingDataPoToken = minted?.streamingDataPoToken ?? options.streamingDataPoToken
            }
            do {
                let result = try await StreamResolver.resolve(
                    videoId: videoId,
                    client: entry.client,
                    using: InnerTubeClient.tropShared,
                    options: options,
                    providers: providers
                )
                let valid = await StreamResolver.validateStream(
                    url: result.streamUrl,
                    onStreamRejection: providers.onStreamRejection
                )
                PlaybackReport.record("\(entry.client.clientName): direccion \(valid ? "VALIDA" : "rechazada") (\(elapsed()) ms)")
                guard valid else {
                    lastError = StreamError.validationFailed(entry.client.clientName)
                    continue
                }
                if request.policy.storeInCache {
                    await StreamCache.shared.set(videoId: videoId, result: result)
                }
                return result
            } catch {
                PlaybackReport.record("\(entry.client.clientName): error \(error.localizedDescription) (\(elapsed()) ms)")
                lastError = error
            }
        }
        throw lastError ?? StreamError.allClientsFailed
    }

    private static func isLong(_ song: SongItem?) -> Bool {
        (song?.duration ?? 0) >= longContentSeconds
            || song?.musicVideoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"
    }

    /// Una direccion guardada por una version anterior para un podcast puede no funcionar: se descarta
    /// una vez por arranque para que se vuelva a resolver.
    private var purgedLongIds = Set<String>()

    /// Contenidos cuya reproduccion fallo: su siguiente resolucion usa la cadena que comprueba todo.
    private var requireValidation = Set<String>()

    func requireValidatedChain(for videoId: String) {
        requireValidation.insert(videoId)
    }

    private func purgeStaleLongCache(_ videoId: String) async {
        guard !purgedLongIds.contains(videoId) else { return }
        let song = await queueSong(for: videoId)
        guard Self.isLong(song) else { return }
        purgedLongIds.insert(videoId)
        await StreamCache.shared.remove(videoId: videoId)
    }

    private func playNetworkResult(_ result: PlaybackResult, videoId: String, startAt: TimeInterval = 0) async {
        clientUsed[videoId] = result.clientName
        resolveFailures.removeValue(forKey: videoId)
        // Para el informe: si la direccion lleva el token (&pot=) que pide YouTube a los clientes web.
        PlaybackReport.record("direccion de \(videoId): token pot \(result.streamUrl.contains("pot=") ? "si" : "NO")")
        let queueSong = await queueSong(for: videoId)
        // Para saber si lo que suena es la cancion o un video (y por que): tipo de YouTube Music y duracion.
        PlaybackReport.record(
            "cancion \(videoId): tipo \((queueSong?.musicVideoType ?? "?").replacingOccurrences(of: "MUSIC_VIDEO_TYPE_", with: "")), "
                + "\(queueSong?.duration ?? 0) s, \"\(queueSong?.title ?? "?")\""
        )
        await PlayerController.shared.play(
            url: result.streamUrl,
            title: result.title,
            artist: result.author,
            videoId: videoId,
            duration: result.duration.flatMap { $0 > 0 ? TimeInterval($0) : nil },
            artists: queueSong?.artists ?? [],
            loudnessDb: result.loudnessDb,
            thumbnailUrl: queueSong?.thumbnailUrl,
            startAt: startAt
        )
        await publishVideoAvailability(result: result, videoId: videoId, rowType: queueSong?.musicVideoType)
    }

    // MARK: - Clientes cuya direccion no abre el reproductor

    private static let avoidedKey = "playback.avoidedClients"
    /// Que cliente de YouTube dio la direccion con la que suena (o se intento sonar) cada cancion.
    private var clientUsed: [String: String] = [:]
    /// Cuando fallo la direccion de cada cliente (para no vetarlo por un fallo suelto).
    private var clientFailures: [String: [Date]] = [:]

    private func avoidedClientNames() -> Set<String> {
        let now = Date().timeIntervalSince1970
        let stored = (UserDefaults.standard.dictionary(forKey: Self.avoidedKey) as? [String: Double]) ?? [:]
        let live = stored.filter { $0.value > now }
        if live.count != stored.count { UserDefaults.standard.set(live, forKey: Self.avoidedKey) }
        return Set(live.keys)
    }

    /// La cadena sin los clientes descartados (si no quedara ninguno, la entera).
    private func filteredChain(_ chain: [FallbackClient]) -> [FallbackClient] {
        let avoided = avoidedClientNames()
        let kept = chain.filter { !avoided.contains($0.client.clientName) }
        return kept.isEmpty ? chain : kept
    }

    /// El reproductor no pudo abrir la direccion de esta cancion (403...): el cliente que la dio se deja de usar durante 3 horas
    /// y se olvidan las direcciones guardadas (pueden ser del mismo cliente).
    func noteStreamFailure(videoId: String) async {
        guard let name = clientUsed[videoId] else { return }
        // Los videos subidos por usuarios (UGC) dan 403 por ser ellos, no por el cliente: no cuentan para vetarlo (si no,
        // una sola cancion UGC dejaba sin WEB_REMIX a todas las demas durante 3 horas).
        if await queueSong(for: videoId)?.musicVideoType == "MUSIC_VIDEO_TYPE_UGC" {
            await StreamCache.shared.remove(videoId: videoId)
            PlaybackReport.record("cliente \(name): fallo de \(videoId) (UGC), no cuenta para descartar al cliente")
            return
        }
        // Un fallo suelto (un corte de red...) no veta al cliente: hace falta un segundo fallo suyo en 15 minutos. El primero
        // solo hace que se vuelva a pedir la direccion de esa cancion.
        let now = Date()
        var recent = (clientFailures[name] ?? []).filter { now.timeIntervalSince($0) < 900 }
        recent.append(now)
        clientFailures[name] = recent
        await StreamCache.shared.remove(videoId: videoId)
        guard recent.count >= 2 else {
            PlaybackReport.record("cliente \(name): primer fallo de \(videoId), todavia no se descarta")
            return
        }
        clientFailures[name] = []
        var stored = (UserDefaults.standard.dictionary(forKey: Self.avoidedKey) as? [String: Double]) ?? [:]
        stored[name] = Date().timeIntervalSince1970 + 3 * 3600
        UserDefaults.standard.set(stored, forKey: Self.avoidedKey)
        if UserDefaults.standard.string(forKey: Self.lastClientKey) == name {
            UserDefaults.standard.removeObject(forKey: Self.lastClientKey)
        }
        await StreamCache.shared.clear()
        PlaybackReport.record("cliente \(name) descartado 3 h: su direccion de \(videoId) no se pudo abrir en el reproductor")
    }

    private func clearInflight(key: String) {
        inflightResolutions.removeValue(forKey: key)
    }

    /// Queue song for resolve-time metadata (artists, artwork, video type).
    /// One MainActor hop instead of one per field, so the snapshot is
    /// consistent even if the queue changes mid-resolve.
    private func queueSong(for videoId: String) async -> SongItem? {
        await MainActor.run {
            NowPlaying.shared.queueSongs.first { $0.videoId == videoId }
        }
    }

    /// Publishes video availability for a resolve result. The row type wins
    /// (resolve responses often omit it); unknown rows fall back to an
    /// authoritative lookup inside the shared availability check.
    private func publishVideoAvailability(result: PlaybackResult, videoId: String, rowType: String?) async {
        // En Sonar no se ven los videos de las canciones (solo caratulas y caratulas en movimiento): ya no se consulta si la
        // cancion tiene video (era una peticion mas por cancion) ni se prepara por adelantado (gastaba CPU, datos y bateria).
        let type = result.musicVideoType ?? rowType
        await MainActor.run {
            NowPlaying.shared.updateVideoAvailability(musicVideoType: type, hasVideo: false)
        }
    }

    /// Resolves a playable video stream URL for video mode. Prefers a muxed
    /// (audio+video) stream; when the video offers none, falls back to an EDL
    /// that combines a DASH video-only stream with a separate audio stream.
    func resolveVideoStream(videoId: String) async throws -> String {
        var request = StreamResolveRequest(videoId: videoId)
        request.options.audioQuality = SettingsStore.shared.audioQuality
        switch try await StreamFallback.resolveVideo(
            request,
            using: InnerTubeClient.tropShared,
            providers: .tropLive
        ) {
        case .muxed(let url):
            return url
        case .split(let videoURL, let audioURL, let duration):
            return StreamFallback.combineVideoAndAudio(
                videoURL: videoURL,
                audioURL: audioURL,
                duration: duration
            )
        case .hls(let url):
            return url
        }
    }

    /// Returns the muxed/video stream URL for video mode, preferring the cached one.
    func resolveMuxedURL(videoId: String) async throws -> String {
        if let cached = await StreamCache.shared.get(videoId: videoId),
           let muxed = cached.muxedStreamUrl {
            return muxed
        }
        return try await resolveVideoStream(videoId: videoId)
    }

    func resolveVideoOnlyURL(videoId: String) async throws -> String {
        let request = StreamResolveRequest(videoId: videoId)
        switch try await StreamFallback.resolveVideo(
            request,
            using: InnerTubeClient.tropShared,
            providers: .tropLive
        ) {
        case .muxed(let url):
            return url
        case .split(let videoURL, _, _):
            return videoURL
        case .hls(let url):
            return url
        }
    }

    /// Stable per-launch session id for PoToken minting.
    static let sessionId: String = UUID().uuidString
    /// Resolve a video without playing. Useful for previews / testing.
    func resolve(videoId: String, preferredFormat: Format? = nil, forDownload: Bool = false) async throws -> PlaybackResult {
        await purgeStaleLongCache(videoId)
        if !forDownload, let cached = await StreamCache.shared.get(videoId: videoId) {
            return cached
        }

        if !forDownload, let blocked = resolveFailures[videoId], blocked.until > Date() {
            throw StreamError.allClientsFailed
        }

        let key = resolutionKey(videoId: videoId, forDownload: forDownload)
        if let existing = inflightResolutions[key] {
            return try await existing.value
        }

        let task = Task { [self] in
            try await resolveFromNetwork(videoId: videoId, preferredFormat: preferredFormat, forDownload: forDownload)
        }
        inflightResolutions[key] = task
        defer { clearInflight(key: key) }
        do {
            let result = try await task.value
            resolveFailures.removeValue(forKey: videoId)
            return result
        } catch {
            if !forDownload, !(error is CancellationError) {
                let count = (resolveFailures[videoId]?.count ?? 0) + 1
                let wait = min(1800, 120 * pow(2, Double(count - 1)))
                resolveFailures[videoId] = (count, Date().addingTimeInterval(wait))
                PlaybackReport.record(String(
                    format: "direccion de %@ no disponible: no se vuelve a pedir (analisis, onda) en %.0f min",
                    videoId, wait / 60
                ))
            }
            throw error
        }
    }

    private func resolveFromNetwork(videoId: String, preferredFormat: Format?, forDownload: Bool) async throws -> PlaybackResult {
        var request = forDownload ? StreamResolveRequest.download(videoId: videoId) : .playback(videoId: videoId)
        request.options.preferredFormat = preferredFormat
        request.options.audioQuality = SettingsStore.shared.audioQuality
        request.options.downloadQuality = SettingsStore.shared.downloadQuality
        if !forDownload { request.chain = filteredChain(request.chain) }
        if Self.isLong(await queueSong(for: videoId)) || requireValidation.contains(videoId) {
            return try await resolveLongContent(videoId: videoId, request: request)
        }
        return try await StreamFallback.resolveFirstValid(
            request,
            using: InnerTubeClient.tropShared,
            providers: .tropLive
        )
    }
}
