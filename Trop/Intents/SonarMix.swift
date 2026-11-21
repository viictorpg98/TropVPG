//
//  SonarMix.swift
//  Trop
//

import Foundation
import UIKit

/// "Pon música": empieza a sonar una mezcla de lo que le gusta a la persona, sin abrir pantallas.
/// Orden de preferencia (el elegido por el usuario):
/// 1. Con conexion (y el inicio respondiendo): la cola de `ParaTiMix` (70% lo que mas escuchas, 30% descubrimiento; ver ese archivo); si
/// sale corta, las canciones del inicio al azar o la radio de una de ellas.
/// 2. Canciones descargadas (suenan al instante desde el archivo; sin conexion van primero).
/// 3. La ultima mezcla guardada (sin conexion, o si el inicio no responde).
/// 4. Canciones que te gustan, guardadas en el dispositivo.
///
/// La accion no termina hasta que el audio esta sonando: si devolviera el control antes, iOS podria
/// suspender la app y la musica empezaria "al rato" (y Siri diria que hubo un problema).
@MainActor
enum SonarMix {
    private static let cacheKey = "sonarMix.cachedSongs"
    private static let reportKey = "sonarMix.lastReport"

    // MARK: - Informe de tiempos

    private static var traceStart = Date()
    private static var traceLines: [String] = []

    /// Apunta un paso con el tiempo transcurrido y lo guarda, para poder consultarlo despues
    /// con la accion "Informe" (asi se ve donde se va el tiempo sin necesidad de un Mac).
    private static func trace(_ text: String) {
        let ms = Int(Date().timeIntervalSince(traceStart) * 1000)
        traceLines.append("\(ms) ms: \(text)")
        UserDefaults.standard.set(traceLines.joined(separator: "\n"), forKey: reportKey)
        if mirrorToVoiceLog { VoiceLog.add("[mix] \(text)", report: false) }
    }

    /// Mientras dura una busqueda por voz, cada paso de SonarMix tambien se apunta en el registro de voz (asi se ve donde se queda parada).
    static var mirrorToVoiceLog = false

    /// Texto del ultimo arranque de "Pon mi musica".
    static var lastReport: String {
        UserDefaults.standard.string(forKey: reportKey)
            ?? "Todavia no hay datos: ejecuta antes Pon mi musica."
    }

    /// Devuelve `true` si ha empezado a sonar algo.
    static func start() async -> Bool {
        traceStart = Date()
        traceLines = []
        trace("inicio")

        // Mantiene la app con CPU mientras se prepara y arranca el audio.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SonarMix")
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        // Antes de pedir ninguna cancion hay que cargar la sesion (cookies, identidad de visitante...).
        // En la app normal lo hace la pantalla de inicio al abrirse; cuando la accion lanza la app en
        // segundo plano esa pantalla no existe, y sin esto la primera peticion de stream va "anonima":
        // YouTube devuelve una direccion que el reproductor rechaza y la musica no suena (o suena al rato).
        await prepareSession()
        trace("sesion cargada")

        // Orden elegido por el usuario: CON conexion manda el inicio de YouTube; las descargadas van primero solo sin conexion (o si el inicio no
        // responde). Antes iban siempre primero y "Para ti" parecia ignorar el inicio.
        let online = NetworkMonitor.shared.hasConnection

        // 1) Con conexion, el inicio de YouTube Music. Con limite de tiempo: solo la primera pagina del inicio (una peticion), que ya trae
        // canciones tuyas ("Volver a escuchar"...). Buscar "Mezclado para ti" exige varias peticiones mas, asi que eso se hace despues, en
        // segundo plano. Se espera hasta 10 s al audio de cada cancion (con reintentos de por medio) antes de pasar a la siguiente.
        if online {
            // El historial local se lee y las radios de las semillas se piden MIENTRAS llega el inicio (se solapan).
            let listening = (try? await DatabaseService.shared.fetchListeningStats()) ?? (stats: [], eventsRead: 0)
            let profile = ParaTiMix.localProfile(stats: listening.stats, eventsRead: listening.eventsRead, now: Date())
            var seeds = ParaTiMix.pickSeeds(from: profile.familiar)
            var radioTask: Task<ParaTiMix.RadioResult, Never>?
            if !seeds.isEmpty {
                let seedList = seeds
                radioTask = Task { await ParaTiMix.loadRadios(seedList) }
            }
            let sections = await withTimeout(seconds: 10) { await loadHomeSections(deep: false) }
            trace(sections.map { "inicio cargado: \($0.count) secciones" } ?? "inicio: sin respuesta a tiempo")
            if let sections {
                let songs = homeSongs(in: sections)
                // Se guarda ya, para que la proxima vez (sin conexion) arranque al instante desde la mezcla guardada.
                if songs.count >= 3 { saveCache(songs) }
                // "Listen again" (el historial de tu cuenta): conocidas; y semillas si el historial local esta vacio.
                let listenAgain = homeSongs(in: sections.filter { HomeSectionTitles.isKeepListening($0.title) })
                if seeds.isEmpty {
                    seeds = ParaTiMix.seedsFromListenAgain(listenAgain)
                    if !seeds.isEmpty {
                        let seedList = seeds
                        radioTask = Task { await ParaTiMix.loadRadios(seedList) }
                    }
                }
                let pendingRadios = radioTask
                let radios = await withTimeout(seconds: 5) { () async -> ParaTiMix.RadioResult? in await pendingRadios?.value }
                let merged = ParaTiMix.addListenAgain(to: profile.familiar, listenAgain: listenAgain)
                let composition = ParaTiMix.compose(
                    familiar: merged.list,
                    radios: radios?.songs ?? [],
                    saved: cachedMix() ?? [],
                    recentlyPlayed: profile.recentlyPlayed
                )
                let discoveryCount = composition.isDiscovery.filter { $0 }.count
                let firstSix = zip(composition.queue.prefix(6), composition.isDiscovery.prefix(6))
                    .map { "\($0.1 ? "N" : "C") \(String($0.0.title.prefix(22)))" }
                    .joined(separator: " | ")
                let seedTitles = seeds.map { String($0.title.prefix(22)) }.joined(separator: ", ")
                PlaybackReport.record(
                    "para ti: \(profile.eventsRead) eventos leidos (\(profile.songsWithHistory) canciones), conocidas \(merged.list.count) "
                        + "(sueño fuera \(profile.sleepExcluded), saltadas fuera \(profile.skipExcluded), Listen again nuevas \(merged.used) de \(listenAgain.count)), "
                        + "semillas [\(seedTitles)] radios \(radios?.songs.count ?? 0) (cache \(radios?.cached ?? 0), pedidas \(radios?.fetched ?? 0)"
                        + "\(radios == nil && radioTask != nil ? ", sin respuesta a tiempo" : "")), guardada \(cachedMix()?.count ?? 0) "
                        + "-> cola \(composition.queue.count - discoveryCount) conocidas + \(discoveryCount) nuevas; primeras: \(firstSix)"
                )
                let started: Bool
                if composition.queue.count >= 10 {
                    ParaTiMix.rememberPicks(composition.queue)
                    started = await play(composition.queue, context: "para ti", waitSeconds: 10)
                } else if songs.count >= 3 {
                    started = await play(Array(songs.shuffled().prefix(40)), context: "canciones del inicio", waitSeconds: 10)
                } else {
                    started = await playRadioOfAnySong(in: sections)
                }
                if started {
                    Task {
                        await refreshCacheIfStale()
                    }
                    return true
                }
            }
        } else {
            trace("sin conexion: se salta el inicio")
        }

        // 2) Canciones descargadas (sin conexion, o con conexion si el inicio no dio nada). Suenan desde el archivo, sin red.
        let downloaded = await downloadedSongs()
        trace("descargadas: \(downloaded.count)")
        if !downloaded.isEmpty {
            var queue = Array(await variedOrder(downloaded).prefix(40))
            if let cached = cachedMix() {
                let ids = Set(queue.map(\.videoId))
                queue += cached.shuffled().filter { !ids.contains($0.videoId) }.prefix(30)
            }
            if await play(queue, context: "downloaded first") {
                if let first = queue.first { rememberStart(first.videoId) }
                // Mientras suena la descargada se calienta lo necesario para las siguientes.
                let seed = queue.last?.videoId ?? ""
                Task {
                    await warmUpTokens(videoId: seed)
                    trace("tokens listos (en segundo plano)")
                    await refreshCacheIfStale()
                }
                return true
            }
        }

        // 3) Sin conexion (o el inicio no respondio a tiempo): la ultima mezcla guardada, sin esperar a la red.
        let cachedSongs = cachedMix()
        trace("mezcla guardada: \(cachedSongs?.count ?? 0) canciones")
        if let cached = cachedSongs, await play(cached.shuffled(), context: "mezcla guardada") {
            Task {
                await refreshCacheIfStale()
            }
            return true
        }

        // 4) Lo ultimo: canciones que te gustan, guardadas en el dispositivo.
        return await playLikedSongs()
    }

    /// Espera el resultado de `work`, pero como mucho `seconds`; pasado ese tiempo devuelve `nil`
    /// (el trabajo sigue en segundo plano, pero ya no se espera).
    static func withTimeout<T>(seconds: Double, _ work: @escaping () async -> T?) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            var finished = false
            let finish: (T?) -> Void = { value in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: value)
            }
            Task { @MainActor in finish(await work()) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                finish(nil)
            }
        }
    }

    // MARK: - Descargadas y calentamiento

    private static func downloadedSongs() async -> [SongItem] {
        await DownloadManager.shared.fetchAll().map { SongItem(entity: $0) }
    }

    private static let recentStartsKey = "sonarMix.recentStarts"

    /// Baraja las descargadas para que no suene siempre lo mismo: las que se han escuchado en los
    /// ultimos dias van al final, y la primera nunca es una de las ultimas con las que ya se arranco.
    private static func variedOrder(_ songs: [SongItem]) async -> [SongItem] {
        let played = await OfflineMix.lastPlayedDates()
        let recentCut = Date().addingTimeInterval(-3 * 86_400)
        var fresh: [SongItem] = []
        var heardRecently: [SongItem] = []
        for song in songs.shuffled() {
            if let when = played[song.videoId], when > recentCut {
                heardRecently.append(song)
            } else {
                fresh.append(song)
            }
        }
        var ordered = fresh + heardRecently
        let recentStarts = Set(UserDefaults.standard.stringArray(forKey: recentStartsKey) ?? [])
        if let index = ordered.firstIndex(where: { !recentStarts.contains($0.videoId) }), index > 0 {
            ordered.swapAt(0, index)
        }
        return ordered
    }

    private static func rememberStart(_ videoId: String) {
        var recent = UserDefaults.standard.stringArray(forKey: recentStartsKey) ?? []
        recent.removeAll { $0 == videoId }
        recent.append(videoId)
        UserDefaults.standard.set(Array(recent.suffix(25)), forKey: recentStartsKey)
    }

    /// Arranca el generador de tokens (navegador oculto + BotGuard) para que, cuando haga falta
    /// resolver una cancion por red, ya este listo.
    private static func warmUpTokens(videoId: String) async {
        guard !videoId.isEmpty else { return }
        _ = try? await PoTokenSource.shared.generate(videoId: videoId, sessionId: PlaybackManager.sessionId)
    }

    // MARK: - Reproduccion

    /// Pone la cola y espera a que la primera cancion este sonando.
    /// Prueba hasta 3 canciones de la cola y solo da por bueno el intento cuando el audio avanza de
    /// verdad: que mpv acepte la orden de cargar no significa que se oiga algo.
    private static func play(_ songs: [SongItem], context: String, waitSeconds: Double = 6) async -> Bool {
        guard !songs.isEmpty else { return false }
        trace("\(context): reproductor antes: \(PlayerController.shared.diagnosticSnapshot())")

        for index in 0..<min(3, songs.count) {
            let song = songs[index]
            NowPlaying.shared.setQueue(songs, startIndex: index)
            trace("\(context): intento \(index + 1), pidiendo la cancion")
            do {
                // Con una sola cancion (el widget) la carga reintenta por su cuenta si ningun cliente da direccion a la primera; con una cola
                // (Para ti) es mejor pasar a la siguiente cancion que esperar a la primera.
                let result = try await PlaybackManager.shared.resolveAndPlay(videoId: song.videoId, bounded: songs.count == 1)
                trace("\(context): ordenada (cliente \(result.clientName))")
            } catch {
                trace("\(context): fallo al resolver (\(error.localizedDescription))")
                Log.nowPlaying.error("Intent playback failed (\(context)): \(error)")
                continue
            }

            if await waitForAudio(seconds: waitSeconds) {
                trace("\(context): audio confirmado")
                return true
            }
            trace("\(context): SIN audio tras \(Int(waitSeconds)) s -> \(PlayerController.shared.diagnosticSnapshot())")
            // Antes del siguiente intento, se reactiva la sesion de audio.
            PlayerController.shared.assertAudioSession()
        }
        return false
    }

    // MARK: - Pedir una cancion concreta

    private static let ignoredWords: Set<String> = [
        "de", "la", "el", "los", "las", "del", "por", "y", "un", "una", "en", "the", "by", "of", "a", "and", "cancion", "song"
    ]

    /// Palabras de lo que se pidio, sin acentos ni mayusculas ni palabras de relleno.
    private static func searchWords(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !ignoredWords.contains($0) }
    }

    /// La mejor coincidencia entre las descargadas: tienen que aparecer todas las palabras pedidas en titulo o
    /// artista; gana la que mas palabras tiene en el titulo y, a igualdad, el titulo mas corto.
    private static func bestDownloadedMatch(_ words: [String], in songs: [SongItem]) -> SongItem? {
        var best: (song: SongItem, inTitle: Int, length: Int)?
        for song in songs {
            let title = searchWords(song.title).joined(separator: " ")
            let artist = searchWords(song.artists.map(\.name).joined(separator: " ")).joined(separator: " ")
            guard words.allSatisfy({ title.contains($0) || artist.contains($0) }) else { continue }
            let inTitle = words.filter { title.contains($0) }.count
            if let current = best,
               current.inTitle > inTitle || (current.inTitle == inTitle && current.length <= title.count) { continue }
            best = (song, inTitle, title.count)
        }
        return best?.song
    }

    /// "Pon una canción": primero entre las descargadas (vale sin red) y luego en YouTube Music (primer
    /// resultado de canciones). La reproduce con su cola. `nil` si no la encuentra.
    static func playSong(named query: String) async -> SongItem? {
        let words = searchWords(query)
        guard !words.isEmpty else { return nil }
        await prepareSession()
        trace("cancion pedida: \(query)")

        var chosen = bestDownloadedMatch(words, in: await downloadedSongs())
        if chosen != nil { trace("encontrada entre las descargadas") }
        if chosen == nil, await NetworkMonitor.shared.hasConnection {
            if let raw = try? await SearchService.shared.search(query: query) {
                let sections = SearchParser.parseSearchResults(from: raw)
                let preferred = sections.first { $0.title.lowercased().contains("song") || $0.title.lowercased().contains("canci") }
                for section in ([preferred].compactMap { $0 } + sections) {
                    for item in section.items {
                        if case .song(let song) = item { chosen = song; break }
                    }
                    if chosen != nil { break }
                }
                trace("busqueda en YouTube Music: \(chosen?.title ?? "sin resultado")")
            }
        }
        guard let song = chosen else { return nil }
        await MainActor.run { PlaybackQueue.playSingleWithRadio(song, log: Log.nowPlaying) }
        _ = await waitForAudio(seconds: 8)
        return song
    }

    /// Espera a que mpv empiece a avanzar; `false` si no lo hace en `seconds`.
    private static func waitForAudio(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if PlayerController.shared.isAudioAdvancing { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return PlayerController.shared.isAudioAdvancing
    }

    // MARK: - Sesion e inicio

    static func prepareSession() async {
        await InnerTubeClient.tropShared.syncTropLocale()
        let cookieStore = CookieStore()
        if await cookieStore.isLoggedIn() {
            await InnerTubeClient.tropShared.loadState(from: cookieStore)
        }
    }

    /// Las secciones del inicio de YouTube Music (la primera pagina y, si hace falta, las siguientes,
    /// porque "Mezclado para ti" suele venir mas abajo).
    /// Con `deep: false` solo la primera pagina (una peticion).
    private static func loadHomeSections(deep: Bool = true) async -> [HomePage.Section]? {
        guard let json = try? await InnerTubeClient.tropShared.browse(browseId: "FEmusic_home"),
              let page = HomePageParser.parseHomePage(from: json) else {
            trace("inicio: la peticion fallo")
            return nil
        }

        var sections = page.sections
        guard deep else { return sections }
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

    /// El inicio de YouTube Music para los widgets (que no tienen pantalla): la primera pagina y, si todavia no sale "Selecciones rapidas"
    /// (YouTube la suele poner en las paginas siguientes), hasta 4 paginas mas. Limite de 20 s en total. `nil` sin conexion o si falla.
    static func homeSectionsForWidget() async -> [HomePage.Section]? {
        await prepareSession()
        guard NetworkMonitor.shared.hasConnection else { return nil }
        return await withTimeout(seconds: 20) { () async -> [HomePage.Section]? in
            guard let json = try? await InnerTubeClient.tropShared.browse(browseId: "FEmusic_home"),
                  let page = HomePageParser.parseHomePage(from: json) else { return nil }
            var sections = page.sections
            var continuation = page.continuation
            var attempts = 0
            while attempts < 4, !sections.contains(where: { HomeSectionTitles.isQuickPicks($0.title) }), let token = continuation {
                attempts += 1
                guard let json = try? await InnerTubeClient.tropShared.browse(continuation: token),
                      let (more, next) = HomePageParser.parseContinuationSections(from: json) else { break }
                sections.append(contentsOf: more)
                continuation = next
            }
            return sections
        }
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
              let (_, rows) = try? await SyncBridge.playlistDetail.fetchPlaylistRows(playlistId: first.id, maxPages: 2) else {
            return nil
        }
        let songs = rows.compactMap { item -> SongItem? in
            guard let renderer = item["musicResponsiveListItemRenderer"] as? [String: Any] else { return nil }
            return SongItem.from(renderer)
        }
        return songs.count >= 3 ? songs : nil
    }

    private static let lastRefreshKey = "sonarMix.lastRefresh"

    /// Despues de arrancar, la mezcla guardada se refresca en segundo plano como mucho cada 30 minutos. Cada refresco son unas 6 peticiones (el
    /// inicio entero, la lista "Mezclado para ti" y mas) y con "Para ti" tocado varias veces seguidas (informe 186) se repetia cada 6 s. La mezcla
    /// guardada ya se actualiza con las canciones de la primera pagina del inicio en cada arranque.
    private static func refreshCacheIfStale() async {
        let last = UserDefaults.standard.object(forKey: lastRefreshKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 1800 else {
            trace("mezcla guardada: refresco reciente, no se repite")
            return
        }
        UserDefaults.standard.set(Date(), forKey: lastRefreshKey)
        await refreshCache()
        trace("mezcla refrescada (en segundo plano)")
    }

    /// Vuelve a pedir la mezcla y la guarda, para que la proxima vez arranque al instante.
    /// Devuelve las canciones encontradas (para que la mezcla sin conexion las pueda descargar).
    @discardableResult
    static func refreshCache() async -> [SongItem] {
        await prepareSession()
        guard let sections = await loadHomeSections() else { return [] }
        if let songs = await mixedForYouSongs(in: sections) {
            saveCache(songs)
            trace("mezcla guardada: Mezclado para ti (\(songs.count))")
            return songs
        }
        // Sin "Mezclado para ti": al menos algo guardado, pero sin pisar una mezcla mejor.
        let songs = homeSongs(in: sections)
        if cachedMix() == nil, songs.count >= 3 {
            saveCache(songs)
            trace("mezcla guardada: canciones del inicio (\(songs.count))")
        } else {
            trace("no se encontro Mezclado para ti")
        }
        return songs
    }

    // MARK: - Canciones del inicio

    /// Todas las canciones sueltas que aparecen en el inicio, sin repetir.
    private static func homeSongs(in sections: [HomePage.Section]) -> [SongItem] {
        var seen = Set<String>()
        var songs: [SongItem] = []
        for section in sections {
            for item in section.items {
                if case .song(let song) = item, !HiddenArtists.shared.isHidden(song),
                   seen.insert(song.videoId).inserted { songs.append(song) }
            }
        }
        return songs
    }

    private static func playRadioOfAnySong(in sections: [HomePage.Section]) async -> Bool {
        let songs = homeSongs(in: sections)
        guard let pick = songs.randomElement(),
              await play([pick], context: "radio seed") else { return false }
        PlaybackQueue.startRadio(for: pick)
        return true
    }

    // MARK: - Pedir por voz: artista, Me gusta, selecciones rapidas y categorias

    private static func folded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    }

    // MARK: - Pedido por voz

    /// Lo que se pondra por voz, ya decidido pero sin sonar todavia (asi se puede decir "Poniendo X" antes de empezar).
    struct VoiceTarget {
        enum Kind { case song, artist, album, playlist, radio }
        var kind: Kind
        var title: String
        var artist: String?
        var songs: [SongItem]
        /// `true`: `songs` es la cola entera (artista, album, lista). `false`: suena `songs[0]` y sigue con su radio.
        var asQueue: Bool
    }

    /// Decide que poner para lo que se dijo, como el buscador: una cancion descargada cuyo titulo lleva todo lo pedido gana (vale sin red); si no, manda
    /// el "mejor resultado" de YouTube Music: artista = sus canciones mas conocidas, album = el album entero, y lo demas = la cancion mas parecida.
    static func resolveVoiceRequest(_ query: String) async -> VoiceTarget? {
        let words = searchWords(query)
        guard !words.isEmpty else { return nil }
        await prepareSession()
        trace("pedido por voz: \(query)")

        func songTarget(_ song: SongItem) -> VoiceTarget {
            VoiceTarget(kind: .song, title: song.title, artist: song.artists.first?.name, songs: [song], asQueue: false)
        }

        let downloadedMatch = bestDownloadedMatch(words, in: await downloadedSongs())
        if let match = downloadedMatch {
            let title = searchWords(match.title).joined(separator: " ")
            if words.allSatisfy({ title.contains($0) }) {
                trace("pedido por voz: encontrada entre las descargadas")
                return songTarget(match)
            }
        }
        guard NetworkMonitor.shared.hasConnection, let raw = try? await SearchService.shared.search(query: query) else {
            return downloadedMatch.map(songTarget)
        }
        let sections = SearchParser.parseSearchResults(from: raw)
        let top = SearchParser.topResult(from: raw)
        switch top {
        case .artist(let artist)?:
            var target = artistTarget(named: artist.name, in: sections)
            // Con una frase larga ("alguna cancion de ...") la busqueda trae pocas canciones suyas: se busca otra vez solo con su nombre.
            if target?.asQueue != true,
               searchWords(artist.name) != words,
               let again = try? await SearchService.shared.search(query: artist.name),
               let better = artistTarget(named: artist.name, in: SearchParser.parseSearchResults(from: again)),
               better.asQueue || target == nil {
                target = better
            }
            if let target {
                trace("pedido por voz: mejor resultado = artista \(artist.name), \(target.songs.count) canciones")
                return target
            }
        case .album(let album)?:
            if let target = await albumTarget(album) {
                trace("pedido por voz: mejor resultado = album \(target.title)")
                return target
            }
        case .playlist(let playlist)?:
            if let target = await playlistTarget(playlist) {
                trace("pedido por voz: mejor resultado = lista \(target.title), \(target.songs.count) canciones")
                return target
            }
        default:
            break
        }

        var chosen: SongItem?
        let allSongs = sections.flatMap(\.items).compactMap { item -> SongItem? in
            if case .song(let song) = item { return song }
            return nil
        }
        if case .song(let topSong)? = top {
            chosen = allSongs.first { $0.videoId == topSong.videoId } ?? topSong
        }
        if chosen == nil {
            let preferred = sections.first { $0.title.lowercased().contains("song") || $0.title.lowercased().contains("canci") }
            for section in ([preferred].compactMap { $0 } + sections) {
                for item in section.items {
                    if case .song(let song) = item { chosen = song; break }
                }
                if chosen != nil { break }
            }
        }
        trace("pedido por voz: cancion \(chosen?.title ?? "sin resultado")")
        guard let chosen else { return downloadedMatch.map(songTarget) }
        // Se elige la que mas se parece a lo dicho (palabras del titulo y del artista). Los videos y directos ("Visualizer", "Official Video", "En vivo"...)
        // restan puntos: a igualdad gana la cancion de audio, pero si lo unico que coincide es un video, se pone ese (la app ya cambia un video por
        // su version de audio si la tiene). La tarjeta del mejor resultado no trae el tipo ni el artista, asi que se busca la misma cancion en la lista.
        func coverage(_ song: SongItem) -> Int {
            let text = searchWords(song.title + " " + song.artists.map(\.name).joined(separator: " ")).joined(separator: " ")
            return words.filter { text.contains($0) }.count
        }
        func score(_ song: SongItem) -> Int {
            var value = coverage(song) * 10
            if AudioCounterpartStore.isVideoType(song) { value -= 4 }
            if looksLikeVideo(song, asked: words) { value -= 4 }
            return value
        }
        var final = allSongs.first { $0.videoId == chosen.videoId } ?? chosen
        var finalScore = score(final)
        for candidate in allSongs.prefix(12) where score(candidate) > finalScore {
            final = candidate
            finalScore = score(candidate)
        }
        if final.videoId != chosen.videoId {
            trace("pedido por voz: se prefiere \(final.title) (puntos \(finalScore)) a \(chosen.title)")
        }
        var target = songTarget(final)
        // La tarjeta del mejor resultado no trae el artista: se toma de la misma cancion en la lista de canciones de la busqueda.
        if target.artist == nil {
            let key = searchWords(final.title).joined(separator: " ")
            target.artist = allSongs.first { searchWords($0.title).joined(separator: " ") == key && !$0.artists.isEmpty }?.artists.first?.name
        }
        return target
    }

    /// "Mis descargas": tus canciones descargadas, barajadas (la primera no es una de las ultimas con las que ya se arranco).
    static func playDownloads() async -> Bool {
        let songs = await variedOrder(await downloadedSongs())
        guard !songs.isEmpty else { return false }
        return await play(Array(songs.prefix(60)), context: "descargas")
    }

    /// Sus canciones mas conocidas (las de la busqueda); si salen menos de 4 suyas, la primera con su radio.
    private static func artistTarget(named name: String, in sections: [SearchSection]) -> VoiceTarget? {
        let words = searchWords(name)
        var seen = Set<String>()
        var byArtist: [SongItem] = []
        var others: [SongItem] = []
        for section in sections {
            for item in section.items {
                guard case .song(let song) = item, seen.insert(song.videoId).inserted else { continue }
                if AudioCounterpartStore.isVideoType(song) || looksLikeVideo(song, asked: words) { continue }
                let artists = searchWords(song.artists.map(\.name).joined(separator: " ")).joined(separator: " ")
                if words.allSatisfy({ artists.contains($0) }) {
                    byArtist.append(song)
                } else {
                    others.append(song)
                }
            }
        }
        guard let first = byArtist.first ?? others.first else { return nil }
        if byArtist.count >= 4 {
            return VoiceTarget(kind: .artist, title: name, artist: nil, songs: Array(byArtist.prefix(25)), asQueue: true)
        }
        return VoiceTarget(kind: .artist, title: name, artist: nil, songs: [first], asQueue: false)
    }

    // MARK: - Peticiones concretas por voz (ultimo album, lo mejor de, parecido a, album, lista)

    /// Resuelve una peticion de `VoiceCommands.parseRequest`. `nil` si no se encuentra (entonces se busca la frase como una cancion).
    static func resolveVoiceTask(_ request: VoiceRequest) async -> VoiceTarget? {
        await prepareSession()
        trace("peticion por voz: \(request)")
        guard NetworkMonitor.shared.hasConnection else { return nil }
        switch request {
        case .top(let name):
            return await resolveVoiceRequest(name)

        case .radio(let name):
            // La radio de su cancion mas conocida: suena esa y sigue con canciones parecidas.
            guard let base = await resolveVoiceRequest(name), let first = base.songs.first else { return nil }
            let who = base.kind == .artist ? base.title : (first.artists.first?.name ?? name)
            return VoiceTarget(kind: .radio, title: who, artist: nil, songs: [first], asQueue: false)

        case .latest(let name, let kind):
            guard let artist = await findArtist(name),
                  let json = try? await InnerTubeClient.tropShared.browse(browseId: artist.browseId) else { return nil }
            let info = ArtistDetailViewModel.parseArtistDetail(from: json, browseId: artist.browseId)
            trace("ultimo de \(artist.name): albumes \(info.albums.prefix(3).map(\.title)), sencillos \(info.singles.prefix(3).map(\.title))")
            let item: AlbumItem?
            switch kind {
            case .album: item = info.albums.first ?? info.singles.first
            case .single: item = info.singles.first ?? info.albums.first
            case .any: item = await newerRelease(album: info.albums.first, single: info.singles.first)
            }
            guard let item, var target = await albumTarget(item) else { return nil }
            if target.artist == nil { target.artist = artist.name }
            return target

        case .album(let query):
            guard let raw = try? await SearchService.shared.search(query: query) else { return nil }
            if case .album(let album)? = SearchParser.topResult(from: raw), let target = await albumTarget(album) { return target }
            for section in SearchParser.parseSearchResults(from: raw) {
                for item in section.items {
                    if case .album(let album) = item { return await albumTarget(album) }
                }
            }
            return nil

        case .playlist(let query):
            guard let raw = try? await SearchService.shared.search(query: query) else { return nil }
            if case .playlist(let playlist)? = SearchParser.topResult(from: raw), let target = await playlistTarget(playlist) { return target }
            for section in SearchParser.parseSearchResults(from: raw) {
                for item in section.items {
                    if case .playlist(let playlist) = item { return await playlistTarget(playlist) }
                }
            }
            return nil
        }
    }

    /// El artista que mejor encaja con el nombre dicho: el mejor resultado si es un artista, o el primero que salga.
    private static func findArtist(_ name: String) async -> ArtistItem? {
        guard let raw = try? await SearchService.shared.search(query: name) else { return nil }
        if case .artist(let artist)? = SearchParser.topResult(from: raw) { return artist }
        for section in SearchParser.parseSearchResults(from: raw) {
            for item in section.items {
                if case .artist(let artist) = item { return artist }
            }
        }
        return nil
    }

    /// De un album y un sencillo, el mas reciente (por el año de su pagina; a igualdad, el album).
    private static func newerRelease(album: AlbumItem?, single: AlbumItem?) async -> AlbumItem? {
        guard let album else { return single }
        guard let single else { return album }
        let albumYear = await releaseYear(album)
        let singleYear = await releaseYear(single)
        return (singleYear ?? 0) > (albumYear ?? 0) ? single : album
    }

    private static func releaseYear(_ item: AlbumItem) async -> Int? {
        if let year = item.year { return year }
        guard let json = try? await InnerTubeClient.tropShared.browse(browseId: item.browseId) else { return nil }
        return AlbumDetailViewModel.parseAlbumDetail(from: json, browseId: item.browseId).year
    }

    /// Titulos de video o de directo ("Visualizer", "Official Video", "En vivo"...), salvo que se hayan pedido en la frase.
    private static func looksLikeVideo(_ song: SongItem, asked words: [String]) -> Bool {
        let tokens = Set(searchWords(song.title))
        let markers: [[String]] = [
            ["visualizer"], ["official", "video"], ["video", "oficial"], ["lyric", "video"], ["lyrics", "video"], ["videoclip"],
            ["video", "clip"], ["vivo"], ["live"], ["directo"]
        ]
        for marker in markers where marker.allSatisfy({ tokens.contains($0) }) {
            if marker.allSatisfy({ words.contains($0) }) { continue }
            return true
        }
        return false
    }

    /// Una lista de reproduccion de YouTube Music (las dos primeras paginas, como "Mezclado para ti"). Hacen falta al menos 3 canciones.
    private static func playlistTarget(_ playlist: PlaylistItem) async -> VoiceTarget? {
        let loaded = await withTimeout(seconds: 8) { () async -> [[String: Any]]? in
            guard let (_, rows) = try? await SyncBridge.playlistDetail.fetchPlaylistRows(playlistId: playlist.id, maxPages: 2) else { return nil }
            return rows
        }
        guard let rows = loaded else {
            trace("lista \(playlist.title): no cargo a tiempo")
            return nil
        }
        let songs = rows.compactMap { item -> SongItem? in
            guard let renderer = item["musicResponsiveListItemRenderer"] as? [String: Any] else { return nil }
            return SongItem.from(renderer)
        }
        guard songs.count >= 3 else { return nil }
        return VoiceTarget(kind: .playlist, title: playlist.title, artist: nil, songs: Array(songs.prefix(60)), asQueue: true)
    }

    private static func albumTarget(_ album: AlbumItem) async -> VoiceTarget? {
        guard let json = try? await InnerTubeClient.tropShared.browse(browseId: album.browseId) else { return nil }
        let info = AlbumDetailViewModel.parseAlbumDetail(from: json, browseId: album.browseId)
        guard !info.songs.isEmpty else { return nil }
        return VoiceTarget(kind: .album, title: info.title, artist: info.artists.first?.name, songs: info.songs, asQueue: true)
    }

    /// Pone lo decidido por `resolveVoiceRequest`. `true` si el audio llega a avanzar.
    static func playVoiceTarget(_ target: VoiceTarget) async -> Bool {
        if target.asQueue {
            let context: String
            switch target.kind {
            case .album: context = "album"
            case .playlist: context = "lista"
            case .radio: context = "radio"
            case .artist, .song: context = "artista"
            }
            return await play(target.songs, context: context)
        }
        guard let song = target.songs.first else { return false }
        PlaybackQueue.playSingleWithRadio(song, log: Log.nowPlaying)
        return await waitForAudio(seconds: 8)
    }

    /// "Pon [artista]": sus canciones mas conocidas (las de la busqueda de YouTube Music) y, si salen pocas, la radio
    /// de la primera. Devuelve el nombre del artista, o `nil` si no encuentra nada.
    static func playArtist(named query: String) async -> String? {
        let words = searchWords(query)
        guard !words.isEmpty else { return nil }
        await prepareSession()
        trace("artista pedido: \(query)")
        guard NetworkMonitor.shared.hasConnection,
              let raw = try? await SearchService.shared.search(query: query) else { return nil }
        let sections = SearchParser.parseSearchResults(from: raw)
        var seen = Set<String>()
        var byArtist: [SongItem] = []
        var others: [SongItem] = []
        for section in sections {
            for item in section.items {
                guard case .song(let song) = item, seen.insert(song.videoId).inserted else { continue }
                let artists = searchWords(song.artists.map(\.name).joined(separator: " ")).joined(separator: " ")
                if words.allSatisfy({ artists.contains($0) }) {
                    byArtist.append(song)
                } else {
                    others.append(song)
                }
            }
        }
        guard let first = byArtist.first ?? others.first else { return nil }
        let name = first.artists.first?.name ?? query
        if byArtist.count >= 4 {
            guard await play(Array(byArtist.prefix(25)), context: "artista") else { return nil }
        } else {
            PlaybackQueue.playSingleWithRadio(first, log: Log.nowPlaying)
            _ = await waitForAudio(seconds: 8)
        }
        return name
    }

    /// "El dado": una cancion al azar de lo que sale en el inicio de YouTube Music y de tu Acceso rapido guardado, con su radio
    /// (lo mismo que el dado del inicio, pero sin necesitar la pantalla). Sin red, solo el Acceso rapido. `false` si no hay nada.
    static func playRandomPick() async -> Bool {
        await prepareSession()
        var songs: [SongItem] = []
        if NetworkMonitor.shared.hasConnection,
           let sections = await withTimeout(seconds: 10, { await loadHomeSections(deep: false) }) {
            songs = homeSongs(in: sections)
        }
        var seen = Set(songs.map(\.videoId))
        for entry in (try? await DatabaseService.shared.fetchSpeedDial()) ?? [] {
            let song = entry.toSongItem()
            if seen.insert(song.videoId).inserted { songs.append(song) }
        }
        trace("dado: \(songs.count) candidatas")
        guard let pick = songs.randomElement(), await play([pick], context: "dado") else { return false }
        PlaybackQueue.startRadio(for: pick)
        return true
    }

    /// Una cancion o episodio concreto (las portadas del widget): suena y sigue su radio. `false` si no arranca.
    /// `duration` y `isEpisode` son importantes: con ellos el reproductor trata un podcast como contenido largo (otra cadena de
    /// clientes de YouTube); sin ellos un episodio de 88 min se pedia como una cancion y la direccion daba 403.
    static func playTrack(videoId: String, title: String, artist: String, duration: Int, isEpisode: Bool) async -> Bool {
        guard !videoId.isEmpty else { return false }
        await prepareSession()
        let song = SongItem(
            videoId: videoId,
            title: title,
            artists: artist.isEmpty ? [] : [YTArtist(name: artist, id: nil)],
            album: nil,
            albumId: nil,
            duration: duration,
            thumbnailUrl: nil,
            isExplicit: false,
            playlistId: nil,
            likeStatus: nil,
            musicVideoType: isEpisode ? "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" : nil
        )
        trace("widget: \(title)")
        // Tarea en segundo plano (como `start`): sin ella, si la cancion tarda (reintentos de la cadena de clientes) la accion termina, la app
        // puede quedar suspendida con la pantalla de inicio delante y la cancion no llega a sonar hasta que se abre la app. Se espera hasta 20 s
        // al audio: cubre los reintentos acotados de `NowPlaying` (12 intentos, unos 17 s de espera).
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SonarWidgetPlay")
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
        guard await play([song], context: "widget", waitSeconds: 20) else { return false }
        PlaybackQueue.startRadio(for: song)
        return true
    }

    /// "Pon mis Me gusta": las canciones que te gustan, guardadas en el dispositivo (vale sin red).
    static func playLiked() async -> Bool {
        await prepareSession()
        return await playLikedSongs()
    }

    /// "Pon mis selecciones rapidas": la seccion de ese nombre del inicio de YouTube Music.
    static func playQuickPicks() async -> Bool {
        await prepareSession()
        let sections = await withTimeout(seconds: 10) { await loadHomeSections(deep: false) }
        guard let sections else { return false }
        let quick = sections.first {
            let title = folded($0.title)
            return title.contains("quick pick") || title.contains("selecciones rapidas")
        }
        let songs = homeSongs(in: quick.map { [$0] } ?? sections)
        guard songs.count >= 3 else { return false }
        return await play(Array(songs.prefix(40)), context: "selecciones rapidas")
    }

    /// "Pon Entrenamiento / Dormir...": la portada del boton de ese nombre del inicio de YouTube Music.
    /// Devuelve el nombre del boton, o `nil` si no lo hay o no trae canciones.
    static func playCategory(keywords: [String]) async -> String? {
        await prepareSession()
        guard NetworkMonitor.shared.hasConnection,
              let json = try? await InnerTubeClient.tropShared.browse(browseId: "FEmusic_home"),
              let page = HomePageParser.parseHomePage(from: json) else { return nil }
        let chip = page.chips.first { chip in
            let title = folded(chip.title)
            return keywords.contains { title.contains($0) }
        }
        guard let chip, let params = chip.params,
              let chipJson = try? await InnerTubeClient.tropShared.browse(
                  browseId: "FEmusic_home", params: params, locale: .deviceLanguage
              ),
              let chipPage = HomePageParser.parseHomePage(from: chipJson, chipMode: true) else { return nil }
        let songs = homeSongs(in: chipPage.sections)
        trace("categoria \(chip.title): \(songs.count) canciones")
        guard songs.count >= 3 else { return nil }
        guard await play(Array(songs.prefix(40)), context: "categoria \(chip.title)") else { return nil }
        return chip.title
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

    static func cachedMix() -> [SongItem]? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let songs = try? JSONDecoder().decode([SongItem].self, from: data),
              songs.count >= 3 else { return nil }
        return songs
    }
}
