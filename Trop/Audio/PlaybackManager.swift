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
    /// Cuantas veces se ha reiniciado la carga de cada cancion (`restartResolution`). Un intento de antes, que sigue colgado en la
    /// red vieja, no puede ponerse a sonar cuando por fin acabe encima del reinicio (cancelar la peticion no esta garantizado).
    private var restartGeneration: [String: Int] = [:]
    /// Canciones cuya resolucion en curso SI va a reproducirse al terminar (la lanzo `resolveAndPlay`). Las otras
    /// (`resolve`: onda de la barra, analisis de AutoMix...) solo piden la direccion y no reproducen nada.
    private var playingResolutions: Set<String> = []
    /// Canciones cuya direccion no se pudo pedir con ningun cliente (muchas UGC dan 403): quienes la piden solo para analizar
    /// o sacar la onda no vuelven a intentarlo hasta pasado un tiempo que crece con cada fallo (2, 4, 8... hasta 30 min).
    private var resolveFailures: [String: (count: Int, until: Date)] = [:]
    private static let lastClientKey = "playback.lastWorkingClient"
    /// Clientes cuya direccion de esta cancion fallo (al abrirse en el reproductor o con un error de entorno): el reintento de ESA cancion no
    /// los vuelve a pedir durante 2 minutos (como Metrolist, que excluye el perfil fallido 120 s).
    private var songExclusions: [String: [String: Date]] = [:]
    /// Clientes con un error de entorno ("not a bot", "no longer supported", sin direccion ni cifrado...) en varias canciones: no se piden
    /// durante 10 minutos (pasado el tiempo se vuelve a probar, y un solo fallo mas los enfria otra vez).
    private var clientCooldowns: [String: Date] = [:]
    private var environmentStrikes: [String: (count: Int, videos: Set<String>)] = [:]
    private var lastCooldownProbe = Date.distantPast
    /// Clientes que dieron alguna direccion (aunque no pasara la comprobacion) en la ultima resolucion de cada cancion: la pasada de DESCARGA
    /// solo se las pide a ellos (solo cambia el formato; antes volvia a pedirselo todo a todos).
    private var clientsWithAddress: [String: Set<String>] = [:]
    /// Cliente de cuya DIRECCION DE DESCARGA suena la cancion (no se cuenta contra ningun cliente de reproduccion, pero se excluye 2 minutos).
    private var downloadClientUsed: [String: String] = [:]
    private static let cooldownSeconds: TimeInterval = 600
    private static let exclusionSeconds: TimeInterval = 120
    /// Fallo que todavia no se ha contado contra el cliente: solo cuenta (y puede vetarlo 3 h) si otro cliente SI da una direccion
    /// que abre esa misma cancion; si ninguno sirve, el problema es la cancion y no el cliente.
    private var pendingClientFailure: [String: String] = [:]
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
    func resolveAndPlay(videoId: String, startAt: TimeInterval = 0, onlyIfCurrent: Bool = false, bounded: Bool = true) async throws -> PlaybackResult {
        let generation = restartGeneration[videoId, default: 0]
        if onlyIfCurrent { cancelSupersededResolutions(keeping: videoId) }
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
                if isSuperseded(videoId, generation: generation) { return result }
                if await isNoLongerChosen(videoId, onlyIfCurrent: onlyIfCurrent) { return result }
                await playNetworkResult(result, videoId: videoId, startAt: startAt)
            }
            return result
        }

        let task = Task { [self] in
            try await resolveWithRetries(videoId: videoId, startAt: startAt, onlyIfCurrent: onlyIfCurrent, generation: generation, bounded: bounded)
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
            // Si se reinicio la carga mientras esta seguia, este intento ya no cuenta: es como una cancelacion.
            if restartGeneration[videoId, default: 0] != generation { throw CancellationError() }
            // Una carga cancelada (se eligio otra cancion) o ya superada no es un fallo que ensenar: su aviso pisaria al de
            // "conexion debil" de la cancion que si se quiere oir.
            let nsError = error as NSError
            let cancelled = error is CancellationError || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            if !cancelled {
                await MainActor.run { NowPlaying.shared.trackLoadFinished(videoId: videoId) }
                if !(await isNoLongerChosen(videoId, onlyIfCurrent: onlyIfCurrent)) {
                    await reportPlaybackFailure(error)
                }
            }
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

    /// Esperas (segundos) antes de cada reintento cuando NINGUN cliente da una direccion que sirva a la primera (11 reintentos, 12 intentos en
    /// total, unos 15 s de espera): YouTube suele acabar dando una (VISIONOS acierta a veces). Es el mismo limite que los reintentos de
    /// `NowPlaying` cuando el reproductor rechaza la direccion. `bounded: false` lo desactiva (los que ya reintentan por su cuenta).
    private static let firstResolveBackoff: [Double] = [0.3, 0.3, 0.5, 0.5, 1, 1, 1, 2, 2, 2, 3]

    private func resolveWithRetries(
        videoId: String,
        startAt: TimeInterval,
        onlyIfCurrent: Bool,
        generation: Int,
        bounded: Bool
    ) async throws -> PlaybackResult {
        var retries = 0
        while true {
            do {
                return try await resolveAndPlayFromNetwork(videoId: videoId, startAt: startAt, onlyIfCurrent: onlyIfCurrent, generation: generation)
            } catch {
                let nsError = error as NSError
                let cancelled = error is CancellationError || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
                guard bounded, !cancelled, retries < Self.firstResolveBackoff.count else { throw error }
                // Sin conexion no hay nada que reintentar.
                guard await MainActor.run(body: { NetworkMonitor.shared.hasConnection }) else { throw error }
                let wait = Self.firstResolveBackoff[retries]
                retries += 1
                PlaybackReport.record("pedir \(videoId): sin direccion que sirva, reintento \(retries + 1) de \(Self.firstResolveBackoff.count + 1) tras \(wait) s")
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                // Antes de cada reintento: si se reinicio la carga o se eligio otra cancion, este ya no cuenta (sin esto, un intento viejo podia
                // ponerse a sonar encima de la cancion nueva).
                if restartGeneration[videoId, default: 0] != generation { throw CancellationError() }
                if await isNoLongerChosen(videoId, onlyIfCurrent: true) { throw CancellationError() }
            }
        }
    }

    /// Runs the client fallback chain for playback. Only called once per
    /// videoId by `resolveAndPlay`, which owns the in-flight dedup entry.
    private func resolveAndPlayFromNetwork(
        videoId: String,
        startAt: TimeInterval = 0,
        onlyIfCurrent: Bool = false,
        generation: Int = 0
    ) async throws -> PlaybackResult {
        var request = StreamResolveRequest.playback(videoId: videoId)
        request.options.audioQuality = SettingsStore.shared.audioQuality
        let started = Date()
        let isLong = Self.isLong(await queueSong(for: videoId)) || requireValidation.contains(videoId)
        PlaybackReport.record("pedir \(videoId) largo=\(isLong)")
        clientsWithAddress[videoId] = []
        var resolved: PlaybackResult?
        var firstError: Error?
        do {
            resolved = try await resolveStaged(videoId: videoId, request: request, isLong: isLong, onlyClients: nil, allowHLS: true)
        } catch {
            firstError = error
        }
        // Ultimo recurso: la cadena de DESCARGA, que prefiere el formato AAC (mp4) y no el opus (webm): en alguna cancion el uno da 403 y el otro
        // no. Solo cambia el formato, asi que solo se pide a los clientes que SI dieron una direccion en la pasada anterior (antes se volvia a
        // pedir todo a todos y se duplicaban las peticiones a YouTube en cada vuelta).
        var usedDownloadAddress = false
        if resolved == nil, let firstError, !(firstError is CancellationError) {
            let withAddress = clientsWithAddress[videoId] ?? []
            if withAddress.isEmpty {
                PlaybackReport.record("pedir \(videoId): ningun cliente dio direccion, no se prueba la de descarga (solo cambia el formato)")
            } else {
                PlaybackReport.record(
                    "pedir \(videoId): ningun cliente dio una direccion que sirva, se prueba la de descarga con \(withAddress.sorted().joined(separator: ", "))"
                )
                var downloadRequest = StreamResolveRequest.download(videoId: videoId)
                downloadRequest.options.audioQuality = SettingsStore.shared.audioQuality
                downloadRequest.options.downloadQuality = SettingsStore.shared.downloadQuality
                if let alternative = try? await resolveStaged(
                    videoId: videoId, request: downloadRequest, isLong: isLong, onlyClients: withAddress
                ) {
                    PlaybackReport.record("direccion de descarga de \(videoId): cliente \(alternative.clientName) (ultimo recurso)")
                    resolved = alternative
                    usedDownloadAddress = true
                }
            }
        }
        // Reintento tras un fallo al abrir: solo si OTRO cliente dio una direccion se cuenta el fallo contra el primero.
        let pendingClient = pendingClientFailure.removeValue(forKey: videoId)
        if let pendingClient {
            if let resolved, !usedDownloadAddress, resolved.clientName != pendingClient {
                await countClientFailure(pendingClient, videoId: videoId)
            } else {
                PlaybackReport.record("cliente \(pendingClient): el fallo de \(videoId) no se cuenta (ningun otro cliente la abrio: es la cancion, no el cliente)")
            }
        }
        guard let result = resolved else { throw firstError ?? StreamError.allClientsFailed }
        PlaybackReport.record("direccion de \(videoId): cliente \(result.clientName) en \(Int(Date().timeIntervalSince(started) * 1000)) ms, \(result.mimeType)")
        // Lo que funciona para un podcast no dice nada de la musica: no se recuerda (ni lo que dio la cadena de descarga ni el HLS).
        if !isLong, !usedDownloadAddress, result.clientName != "HLS" { UserDefaults.standard.set(result.clientName, forKey: Self.lastClientKey) }
        if isSuperseded(videoId, generation: generation) { return result }
        if await isNoLongerChosen(videoId, onlyIfCurrent: onlyIfCurrent) { return result }
        await playNetworkResult(result, videoId: videoId, startAt: startAt)
        // Un fallo posterior de una direccion de DESCARGA no se atribuye a ningun cliente de reproduccion (no vetaria uno que funciona para
        // otras canciones: `noteStreamFailure` mira `clientUsed`), pero si se excluye 2 minutos para esta cancion (`downloadClientUsed`).
        if usedDownloadAddress {
            clientUsed[videoId] = nil
            downloadClientUsed[videoId] = result.clientName
        } else {
            downloadClientUsed[videoId] = nil
        }
        return result
    }

    /// Esta carga es de antes de un reinicio (`restartResolution`): la nueva es la que cuenta.
    private func isSuperseded(_ videoId: String, generation: Int) -> Bool {
        guard restartGeneration[videoId, default: 0] != generation else { return false }
        PlaybackReport.record("reproducir \(videoId): una carga mas nueva la sustituye, esta no se pone a sonar")
        return true
    }

    /// La carga de `videoId` quedo colgada (la red cayo o cambio de Wi-Fi a datos mientras cargaba): se cancela la peticion
    /// pendiente, si la hay, se olvida su direccion guardada y se vuelve a pedir y a cargar con la red de ahora.
    func restartResolution(videoId: String) async {
        restartGeneration[videoId, default: 0] += 1
        if let pending = inflightResolutions[videoId] {
            pending.cancel()
            clearInflight(key: videoId)
            playingResolutions.remove(videoId)
        }
        await StreamCache.shared.remove(videoId: videoId)
        _ = try? await resolveAndPlay(videoId: videoId, onlyIfCurrent: true)
    }

    /// Se volvio a la cancion que el reproductor todavia tenia cargada: las cargas de las otras que quedaron pendientes ya no hacen falta.
    func cancelPlayingResolutions() {
        for (key, task) in inflightResolutions where playingResolutions.contains(key) {
            task.cancel()
            PlaybackReport.record("reproducir \(key): se cancela la carga, se volvio a la cancion que ya sonaba")
        }
    }

    /// Al elegir otra cancion, las cargas pendientes de las que se eligieron antes ya no sirven: se cancelan para que la ultima
    /// tenga toda la red (con poca cobertura, 8 peticiones a la vez tardaban entre 20 y 40 s cada una).
    private func cancelSupersededResolutions(keeping videoId: String) {
        for (key, task) in inflightResolutions where key != videoId && playingResolutions.contains(key) {
            task.cancel()
            PlaybackReport.record("reproducir \(key): se cancela la carga, se eligio otra cancion")
        }
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

    // MARK: - Cadena de clientes de Sonar

    /// Una resolucion: recorre la cadena de Sonar (`SonarClients.chain`) y devuelve la primera direccion que pasa la comprobacion. Sustituye
    /// al bucle de SwiftyTube (`StreamFallback.resolveFirstValid`) para poder: (1) apuntar por que falla cada cliente y no volver a pedirselo
    /// durante un rato, (2) comprobar la direccion como la abre el reproductor y (3) meter el audio HLS entre los clientes.
    private func resolveStaged(
        videoId: String,
        request: StreamResolveRequest,
        isLong: Bool,
        onlyClients: Set<String>?,
        allowHLS: Bool = false
    ) async throws -> PlaybackResult {
        await resetHealthIfNetworkChanged()
        if request.policy.useCache, let cached = await StreamCache.shared.get(videoId: videoId) { return cached }
        // El audio HLS solo lo usa la reproduccion: una descarga, el analisis de AutoMix o la onda recibirian una lista m3u8 en vez del audio.
        var entries = SonarClients.chain.filter { allowHLS || $0.isClient }
        if !isLong, let last = UserDefaults.standard.string(forKey: Self.lastClientKey),
           let index = entries.firstIndex(where: { $0.isClient && $0.name == last }), index > 0 {
            // Prueba primero el cliente que funciono la ultima vez: cada fallo de los de delante es una peticion perdida antes de que suene nada.
            entries.insert(entries.remove(at: index), at: 0)
        }
        var usable = usableEntries(entries, videoId: videoId, allowVetoed: false, ignoreCooldowns: false, onlyNames: onlyClients)
        if usable.isEmpty, !clientCooldowns.isEmpty, Date().timeIntervalSince(lastCooldownProbe) > 60 {
            // Todos los clientes estan enfriados: se prueba una vez por minuto (puede que YouTube ya haya dejado de rechazarnos).
            lastCooldownProbe = Date()
            usable = usableEntries(entries, videoId: videoId, allowVetoed: false, ignoreCooldowns: true, onlyNames: onlyClients)
            if !usable.isEmpty {
                PlaybackReport.record("cadena de \(videoId): todos los clientes estan enfriados, se prueba una vez por minuto")
            }
        }
        do {
            return try await runEntries(usable, videoId: videoId, request: request)
        } catch {
            if error is CancellationError { throw error }
            // Solo ahora se prueban los clientes descartados 3 h (y NUNCA los enfriados ni los excluidos en esta cancion).
            let vetoed = avoidedClientNames()
            let limit = onlyClients.map { vetoed.intersection($0) } ?? vetoed
            let extra = usableEntries(entries, videoId: videoId, allowVetoed: true, ignoreCooldowns: false, onlyNames: limit)
            guard !limit.isEmpty, !extra.isEmpty else { throw error }
            PlaybackReport.record("cadena de \(videoId): sin los clientes descartados 3 h no hubo direccion, se prueba solo con ellos")
            return try await runEntries(extra, videoId: videoId, request: request)
        }
    }

    /// Los fallos de los clientes dependen de la red (el aviso "not a bot" es de la IP): al cambiar de red (Wi-Fi a datos...) se olvidan los
    /// enfriamientos y las exclusiones, como hace Metrolist, que apunta los fallos por red.
    private var networkChangeSeen = Date.distantPast

    private func resetHealthIfNetworkChanged() async {
        let changedAt = await MainActor.run { NetworkMonitor.shared.lastInterfaceChangeAt }
        guard changedAt > networkChangeSeen else { return }
        networkChangeSeen = changedAt
        guard !clientCooldowns.isEmpty || !songExclusions.isEmpty || !environmentStrikes.isEmpty else { return }
        clientCooldowns = [:]
        songExclusions = [:]
        environmentStrikes = [:]
        lastCooldownProbe = .distantPast
        PlaybackReport.record("red: cambio de red, se olvidan los clientes enfriados y excluidos")
    }

    /// La cadena sin los clientes enfriados, los excluidos en esta cancion y (si `allowVetoed` es falso) los descartados 3 h. Si no queda
    /// ninguno, la lista sale vacia: NUNCA se vuelve a la cadena entera (cuando todos dicen "not a bot" las exclusiones tienen que seguir).
    private func usableEntries(
        _ entries: [SonarClients.ChainEntry],
        videoId: String,
        allowVetoed: Bool,
        ignoreCooldowns: Bool,
        onlyNames: Set<String>?
    ) -> [SonarClients.ChainEntry] {
        let now = Date()
        clientCooldowns = clientCooldowns.filter { $0.value > now }
        var blocked = Set<String>()
        if !ignoreCooldowns { blocked.formUnion(clientCooldowns.keys) }
        if let excluded = songExclusions[videoId]?.filter({ $0.value > now }), !excluded.isEmpty {
            songExclusions[videoId] = excluded
            blocked.formUnion(excluded.keys)
        } else {
            songExclusions[videoId] = nil
        }
        if !allowVetoed { blocked.formUnion(avoidedClientNames()) }
        return entries.filter { entry in
            if let onlyNames, !onlyNames.contains(entry.name) { return false }
            return !blocked.contains(entry.name)
        }
    }

    private func runEntries(
        _ entries: [SonarClients.ChainEntry],
        videoId: String,
        request: StreamResolveRequest
    ) async throws -> PlaybackResult {
        let providers = StreamResolveProviders.tropLive
        PlaybackReport.record("cadena de \(videoId): \(entries.isEmpty ? "(vacia)" : entries.map(\.name).joined(separator: " > "))")
        var lastError: Error?
        var nonAAC: PlaybackResult?
        var tokenTask: Task<PoTokenResult?, Never>?
        defer { tokenTask?.cancel() }
        var asked = 0
        for entry in entries {
            try Task.checkCancellation()
            switch entry {
            case .hls:
                let hls = await SonarHLS.resolve(videoId: videoId)
                asked += hls.requests
                PlaybackReport.record("HLS de \(videoId): \(hls.hadManifest ? "con lista de audio" : "sin lista HLS (la cancion no la ofrece)")")
                if let result = hls.result {
                    // El HLS no se guarda en la cache de direcciones (`resolve()` de otros usos se lo encontraria).
                    PlaybackReport.record("pedir \(videoId): resuelta con HLS tras \(asked) peticiones /player")
                    return result
                }
                // Sin lista HLS no se vuelve a preguntar en esta cancion (cada pregunta son dos peticiones /player).
                if !hls.hadManifest { excludeForSong(videoId, client: "HLS") }
                if lastError == nil { lastError = StreamError.noStreams }
            case .client(let item):
                let client = item.client
                let name = client.clientName
                var options = request.options
                if client.useWebPoTokens {
                    if tokenTask == nil {
                        let id = videoId
                        tokenTask = Task { await providers.poTokenProvider?(id) }
                    }
                    if let tokenTask {
                        let minted = await tokenTask.value
                        options.poToken = minted?.playerRequestPoToken ?? options.poToken
                        options.streamingDataPoToken = minted?.streamingDataPoToken ?? options.streamingDataPoToken
                    }
                }
                let attemptStart = Date()
                asked += 1
                do {
                    let result = try await StreamResolver.resolve(
                        videoId: videoId,
                        client: client,
                        using: InnerTubeClient.tropShared,
                        options: options,
                        providers: providers
                    )
                    clientsWithAddress[videoId, default: []].insert(name)
                    let check = await Self.checkAddress(result.streamUrl)
                    let ms = Int(Date().timeIntervalSince(attemptStart) * 1000)
                    let head = check.head.map(String.init) ?? "-"
                    let deep = check.deep.map(String.init) ?? "-"
                    PlaybackReport.record("\(name): direccion \(check.valid ? "VALIDA" : "RECHAZADA") (inicio \(head), 1,1 MB \(deep)) \(ms) ms")
                    guard check.valid else {
                        if check.rejected {
                            await providers.onStreamRejection?()
                            if client.useWebPoTokens, result.streamUrl.contains("pot="), await PoTokenSource.shared.invalidate() {
                                PlaybackReport.record("token: 403 con token en \(name), se crea un generador nuevo")
                            }
                            // Una direccion rechazada con 403 cuenta como golpe: TVHTML5 daba 403 en el primer byte en TODAS las canciones
                            // y gastaba una peticion y 0,35 s en cada una. Un acierto (direccion valida) borra los golpes.
                            registerStrike(name, videoId: videoId, reason: "direccion rechazada con 403")
                        }
                        lastError = StreamError.validationFailed(name)
                        continue
                    }
                    if request.policy.preferAAC {
                        let mime = result.mimeType.lowercased()
                        if !(mime.contains("mp4a") || mime.contains("aac")) {
                            if nonAAC == nil { nonAAC = result }
                            continue
                        }
                    } else if request.policy.storeInCache {
                        await StreamCache.shared.set(videoId: videoId, result: result)
                    }
                    environmentStrikes[name] = nil
                    PlaybackReport.record("pedir \(videoId): resuelta con \(name) tras \(asked) peticiones /player")
                    return result
                } catch {
                    let nsError = error as NSError
                    if error is CancellationError || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
                        throw CancellationError()
                    }
                    let ms = Int(Date().timeIntervalSince(attemptStart) * 1000)
                    PlaybackReport.record("\(name): error \(error.localizedDescription) (\(ms) ms)")
                    noteClientError(name, error: error, videoId: videoId)
                    lastError = error
                }
            }
        }
        if request.policy.preferAAC, let nonAAC {
            PlaybackReport.record("pedir \(videoId): resuelta con \(nonAAC.clientName) (sin AAC) tras \(asked) peticiones /player")
            return nonAAC
        }
        if request.policy.expiredCacheFallback, let expired = await StreamCache.shared.getExpired(videoId: videoId) {
            PlaybackReport.record("pedir \(videoId): ningun cliente dio direccion, se usa la ultima guardada (puede haber caducado)")
            return expired
        }
        PlaybackReport.record("pedir \(videoId): ningun cliente sirvio tras \(asked) peticiones /player")
        throw lastError ?? StreamError.allClientsFailed
    }

    /// Un error de entorno no es de la cancion sino de lo que YouTube deja hacer a este cliente desde esta red o sesion: "not a bot", "no
    /// longer supported", formatos sin direccion ni cifrado (SABR), "page needs to be reloaded" o el descifrado roto. Se excluye en esta cancion
    /// 2 minutos de inmediato y, si pasa en 3 intentos de 2 canciones distintas, el cliente se enfria 10 minutos. Los fallos "blandos" (el
    /// "No streaming data" de VISIONOS, que a veces si da direccion) se siguen pidiendo en cada reintento.
    private func noteClientError(_ name: String, error: Error, videoId: String) {
        let text = error.localizedDescription.lowercased()
        let environment = error is CipherError || text.contains("not a bot") || text.contains("no longer supported")
            || text.contains("no direct stream url") || text.contains("needs to be reloaded")
        guard environment else { return }
        excludeForSong(videoId, client: name)
        registerStrike(name, videoId: videoId, reason: "error de entorno (excluido 2 min en la cancion)")
    }

    /// Un golpe contra un cliente: a los 3, en al menos 2 canciones distintas y sin ningun acierto entre medias, se enfria 10 minutos (despues
    /// de enfriarse, un solo golpe mas lo vuelve a enfriar).
    private func registerStrike(_ name: String, videoId: String, reason: String) {
        var strike = environmentStrikes[name] ?? (count: 0, videos: [])
        strike.count += 1
        strike.videos.insert(videoId)
        environmentStrikes[name] = strike
        if strike.count >= 3, strike.videos.count >= 2, clientCooldowns[name] == nil {
            clientCooldowns[name] = Date().addingTimeInterval(Self.cooldownSeconds)
            environmentStrikes[name] = (count: 2, videos: strike.videos)
            PlaybackReport.record("cliente \(name): enfriado 10 min (\(reason) en \(strike.videos.count) canciones)")
        } else {
            PlaybackReport.record("cliente \(name): \(reason) en \(videoId) (aviso \(strike.count))")
        }
    }

    private func excludeForSong(_ videoId: String, client: String) {
        songExclusions[videoId, default: [:]][client] = Date().addingTimeInterval(Self.exclusionSeconds)
        if songExclusions.count > 200 {
            let now = Date()
            songExclusions = songExclusions.filter { entry in entry.value.contains { $0.value > now } }
        }
    }

    private struct AddressCheck: Sendable {
        let valid: Bool
        let rejected: Bool
        let head: Int?
        let deep: Int?
    }

    /// Comprueba una direccion como la abrira el reproductor, con su mismo User-Agent: una peticion al INICIO del archivo (la que antes se
    /// hacia sola) y otra a 1,1 MB. YouTube sirve sin token el primer megabyte, asi que una direccion con token malo pasaba la comprobacion del
    /// inicio y luego mpv recibia el 403 al pedir mas. 416 = el archivo es mas corto que el punto de prueba (vale).
    private static func checkAddress(_ address: String) async -> AddressCheck {
        guard let url = URL(string: address) else { return AddressCheck(valid: false, rejected: false, head: nil, deep: nil) }
        async let head = rangeStatus(url, range: "bytes=0-1023")
        async let deep = rangeStatus(url, range: "bytes=1100000-1100999")
        let (headStatus, deepStatus) = await (head, deep)
        let rejected = headStatus == 403 || deepStatus == 403
        let headOK = headStatus.map { (200 ... 299).contains($0) } ?? false
        // Sin respuesta de la prueba profunda (tiempo agotado, mala cobertura) se da por buena si el inicio lo fue.
        let deepOK = deepStatus.map { (200 ... 299).contains($0) || $0 == 416 } ?? true
        return AddressCheck(valid: headOK && deepOK && !rejected, rejected: rejected, head: headStatus, deep: deepStatus)
    }

    private static func rangeStatus(_ url: URL, range: String) async -> Int? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue(SonarClients.playerUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
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

    /// El reproductor no pudo abrir la direccion de esta cancion (403...): el cliente que la dio no se vuelve a pedir en esta cancion durante
    /// 2 minutos y se olvidan las direcciones guardadas (pueden ser del mismo cliente). Si la direccion llevaba token, se crea un generador de
    /// tokens nuevo (como Metrolist tras un 403 de CDN).
    func noteStreamFailure(videoId: String) async {
        if clientUsed[videoId] == nil, let download = downloadClientUsed[videoId] {
            await StreamCache.shared.remove(videoId: videoId)
            excludeForSong(videoId, client: download)
            PlaybackReport.record("cliente \(download): la direccion de descarga de \(videoId) no abrio, se excluye 2 min en esta cancion")
            return
        }
        guard let name = clientUsed[videoId] else { return }
        // Los videos subidos por usuarios (UGC) dan 403 por ser ellos, no por el cliente: no cuentan para vetarlo (si no,
        // una sola cancion UGC dejaba sin WEB_REMIX a todas las demas durante 3 horas).
        if await queueSong(for: videoId)?.musicVideoType == "MUSIC_VIDEO_TYPE_UGC" {
            await StreamCache.shared.remove(videoId: videoId)
            excludeForSong(videoId, client: name)
            PlaybackReport.record("cliente \(name): fallo de \(videoId) (UGC), no cuenta para descartar al cliente")
            return
        }
        await StreamCache.shared.remove(videoId: videoId)
        // El reintento de esta cancion no vuelve a usar ese cliente. Pero NO se cuenta aun contra el cliente: si ninguno otro abre la
        // cancion, el problema es la cancion (antes, un par de canciones sin metadatos que daban 403 en todos los clientes dejaban sin
        // WEB_REMIX a todas las demas 3 horas).
        excludeForSong(videoId, client: name)
        // Un cliente cuya direccion acaba de rechazar el reproductor deja de ser "el ultimo que funciono": en el informe 186 MWEB se guardo asi
        // y las 4 canciones siguientes empezaron por el, cada una con un token, una peticion y 0,35 s perdidos.
        if UserDefaults.standard.string(forKey: Self.lastClientKey) == name {
            UserDefaults.standard.removeObject(forKey: Self.lastClientKey)
        }
        pendingClientFailure[videoId] = name
        PlaybackReport.record("cliente \(name): fallo de \(videoId), se pide con otro (excluido 2 min en esta cancion); solo se descartara si otro cliente la abre")
        if SonarClients.tokenClientNames.contains(name), await PoTokenSource.shared.invalidate() {
            PlaybackReport.record("token: la direccion de \(name) dio 403 en el reproductor, se crea un generador nuevo")
        }
    }

    /// Otro cliente SI abrio la cancion que le fallo a `name`. Un fallo suelto (un corte de red...) no veta al cliente: hace falta un
    /// segundo fallo suyo en 15 minutos.
    private func countClientFailure(_ name: String, videoId: String) async {
        let now = Date()
        var recent = (clientFailures[name] ?? []).filter { now.timeIntervalSince($0) < 900 }
        recent.append(now)
        clientFailures[name] = recent
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
        PlaybackReport.record("cliente \(name) descartado 3 h: su direccion de \(videoId) no se pudo abrir en el reproductor y otro cliente si")
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
        let isLong = Self.isLong(await queueSong(for: videoId)) || requireValidation.contains(videoId)
        return try await resolveStaged(videoId: videoId, request: request, isLong: isLong, onlyClients: nil)
    }
}
