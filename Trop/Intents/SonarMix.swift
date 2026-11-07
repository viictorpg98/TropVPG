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
    }

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

        // 0) Lo mas rapido: canciones descargadas. Suenan desde el archivo, sin red.
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
                    await refreshCache()
                    trace("mezcla refrescada (en segundo plano)")
                }
                return true
            }
        }

        // 1) Ultima mezcla guardada: sin esperar a la red.
        let cachedSongs = cachedMix()
        trace("mezcla guardada: \(cachedSongs?.count ?? 0) canciones")
        if let cached = cachedSongs, await play(cached.shuffled(), context: "mezcla guardada") {
            Task {
                await refreshCache()
                trace("mezcla refrescada (en segundo plano)")
            }
            return true
        }

        // 2) Con red y con limite de tiempo: solo la primera pagina del inicio (una peticion), que ya
        // trae canciones tuyas ("Volver a escuchar"...). Buscar "Mezclado para ti" exige varias
        // peticiones mas, asi que eso se hace despues, en segundo plano.
        let sections = await withTimeout(seconds: 10) { await loadHomeSections(deep: false) }
        trace(sections.map { "inicio cargado: \($0.count) secciones" } ?? "inicio: sin respuesta a tiempo")
        if let sections {
            let songs = homeSongs(in: sections)
            // Se guarda ya, para que la proxima vez arranque al instante desde la mezcla guardada.
            if songs.count >= 3 { saveCache(songs) }
            let started: Bool
            if songs.count >= 3 {
                started = await play(Array(songs.shuffled().prefix(40)), context: "canciones del inicio")
            } else {
                started = await playRadioOfAnySong(in: sections)
            }
            if started {
                Task {
                    await refreshCache()
                    trace("mezcla refrescada (en segundo plano)")
                }
                return true
            }
        }

        // 3) Sin red o sin respuesta: canciones que te gustan, guardadas en el dispositivo.
        return await playLikedSongs()
    }

    /// Espera el resultado de `work`, pero como mucho `seconds`; pasado ese tiempo devuelve `nil`
    /// (el trabajo sigue en segundo plano, pero ya no se espera).
    private static func withTimeout<T>(seconds: Double, _ work: @escaping () async -> T?) async -> T? {
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
        _ = try? await PoTokenGenerator.shared.generate(videoId: videoId, sessionId: PlaybackManager.sessionId)
    }

    // MARK: - Reproduccion

    /// Pone la cola y espera a que la primera cancion este sonando.
    /// Prueba hasta 3 canciones de la cola y solo da por bueno el intento cuando el audio avanza de
    /// verdad: que mpv acepte la orden de cargar no significa que se oiga algo.
    private static func play(_ songs: [SongItem], context: String) async -> Bool {
        guard !songs.isEmpty else { return false }
        trace("\(context): reproductor antes: \(PlayerController.shared.diagnosticSnapshot())")

        for index in 0..<min(3, songs.count) {
            let song = songs[index]
            NowPlaying.shared.setQueue(songs, startIndex: index)
            trace("\(context): intento \(index + 1), pidiendo la cancion")
            do {
                let result = try await PlaybackManager.shared.resolveAndPlay(videoId: song.videoId)
                trace("\(context): ordenada (cliente \(result.clientName))")
            } catch {
                trace("\(context): fallo al resolver (\(error.localizedDescription))")
                Log.nowPlaying.error("Intent playback failed (\(context)): \(error)")
                continue
            }

            if await waitForAudio(seconds: 6) {
                trace("\(context): audio confirmado")
                return true
            }
            trace("\(context): SIN audio tras 6 s -> \(PlayerController.shared.diagnosticSnapshot())")
            // Antes del siguiente intento, se reactiva la sesion de audio.
            PlayerController.shared.assertAudioSession()
        }
        return false
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
                if case .song(let song) = item, seen.insert(song.videoId).inserted { songs.append(song) }
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
