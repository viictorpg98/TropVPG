//
//  ParaTiMix.swift
//  Trop
//
//  Como "Para ti" elige la cola (con conexion y con el inicio de YouTube respondiendo). Antes: las canciones sueltas del inicio, al azar.
//  Ahora, 70% de canciones que ya escuchas y 30% de descubrimiento:
//
//  - CONOCIDAS (70%): lo que mas escuchas segun tu historial local (cada reproduccion de 30 s o mas cuenta, con mas peso las recientes: la
//    mitad a los ~80 dias) y "Listen again" de YouTube Music (el historial de tu cuenta, de muchos años). Los "Me gusta" solo dan un 15% mas
//    a una cancion que ademas escuchas (los tuyos son muchisimos y muy antiguos). Se quitan las de dormir (las que casi siempre suenan de
//    noche, o una larga que acabo sonando de noche), las que has saltado dos veces, "no me gusta", artistas ocultos y explicitas si las
//    ocultas. Lo que sono hace menos de un dia o salio en el ultimo "Para ti" pesa menos. La musica de dormir (ver SleepFilter: marca manual,
//    historial, palabras del titulo) se quita de TODO: conocidas, "Listen again", semillas, radios de descubrimiento y mezcla guardada.
//  - DESCUBRIMIENTO (30%): la radio de YouTube de 2 canciones tuyas (semillas fijas 30 min, para aprovechar la cache) y la mezcla guardada
//    ("Mixed for you"), sin subidas de usuarios, sin lo que ya escuchas y sin lo que sono en los ultimos 3 dias.
//  - COHERENCIA (nuevo): toda la cola parte de la PRIMERA cancion (una conocida de las de mas peso). Su radio de YouTube es la base del
//    descubrimiento y, de las conocidas, solo entran las que encajan con su estilo, animo y epoca (Gemini, una peticion de texto; sin clave
//    o si falla, las del mismo artista o de artistas de su radio). Asi la cola no salta de un estilo a otro.
//  - Se reparten en un patron fijo (la primera siempre es conocida; una nueva cada 3-4 canciones) y sin repetir artista en 3 seguidas.
//

import Foundation

@MainActor
enum ParaTiMix {
    struct Candidate {
        let song: SongItem
        var weight: Double
    }

    struct LocalProfile {
        var familiar: [Candidate] = []
        var recentlyPlayed: Set<String> = []
        var sleepExcluded = 0
        /// Por que se quitaron las de dormir (marca manual, noche/larga, temporizador, palabras del titulo).
        var sleepReasons: [SleepFilter.Reason: Int] = [:]
        var skipExcluded = 0
        var eventsRead = 0
        var songsWithHistory = 0
    }

    struct RadioResult: Sendable {
        var songs: [SongItem] = []
        var cached = 0
        var fetched = 0
    }

    struct Composition {
        var queue: [SongItem] = []
        /// `true` = descubrimiento, alineado con `queue`.
        var isDiscovery: [Bool] = []
        var listenAgainUsed = 0
        var familiarPool = 0
        var discoveryPool = 0
    }

    private static let recentPicksKey = "sonarMix.recentPicks"
    private static let seedsKey = "sonarMix.seeds"
    private static let queueSize = 40

    // MARK: - Filtros

    static func isBlocked(_ song: SongItem) -> Bool {
        if LikeStore.shared.disliked.contains(song.videoId) { return true }
        if HiddenArtists.shared.isHidden(song) { return true }
        if SettingsStore.shared.hideExplicit && song.isExplicit { return true }
        if song.musicVideoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" { return true }
        // Musica para dormir: marcada a mano, detectada en el historial local o con palabras de dormir en el titulo. Vale tambien para
        // "Listen again", las semillas, las radios de descubrimiento y la mezcla guardada, que no pasan por el historial local.
        if SleepFilter.shared.isSleep(song) { return true }
        return false
    }

    private static func artistKey(_ song: SongItem) -> String {
        song.artists.first?.name.lowercased() ?? ""
    }

    // MARK: - Conocidas (historial local)

    static func localProfile(stats: [ListeningStat], eventsRead: Int, now: Date) -> LocalProfile {
        var profile = LocalProfile()
        profile.eventsRead = eventsRead
        profile.songsWithHistory = stats.count
        let recentPicks = Set(UserDefaults.standard.stringArray(forKey: recentPicksKey) ?? [])
        let skips = SkipLog.recentCounts()
        // Musica para dormir (ver SleepFilter): se evalua TODO el historial y el resultado se guarda para que tambien lo use lo que no viene
        // de el (Listen again, semillas, radios, widgets). Una cancion de duracion normal solo se quita con la marca manual.
        let sleepEval = SleepFilter.shared.evaluate(stats: stats)
        for stat in stats {
            let entity = stat.entity
            if now.timeIntervalSince(stat.lastPlayed) < 3 * 86_400 { profile.recentlyPlayed.insert(entity.id) }
            if entity.isEpisode { continue }
            if let reason = sleepEval.excluded[entity.id] {
                profile.sleepExcluded += 1
                profile.sleepReasons[reason, default: 0] += 1
                continue
            }
            let song = SongItem(entity: entity)
            if isBlocked(song) { continue }
            if (skips[entity.id] ?? 0) >= 2 {
                profile.skipExcluded += 1
                continue
            }
            var weight = stat.score
            if entity.liked { weight *= 1.15 }
            if now.timeIntervalSince(stat.lastPlayed) < 86_400 { weight *= 0.4 }
            if recentPicks.contains(entity.id) { weight *= 0.35 }
            profile.familiar.append(Candidate(song: song, weight: max(weight, 0.02)))
        }
        return profile
    }

    /// Suma "Listen again" (el historial de la cuenta) a las conocidas. Pesa como minimo lo que la mediana de las locales (el historial local
    /// solo tiene lo escuchado en Sonar, y al principio mucho de ello salio del "Para ti" al azar).
    static func addListenAgain(to familiar: [Candidate], listenAgain: [SongItem]) -> (list: [Candidate], used: Int) {
        let sorted = familiar.map(\.weight).sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let base = max(median, 1.5)
        var list = familiar
        var index: [String: Int] = [:]
        for (position, candidate) in list.enumerated() { index[candidate.song.videoId] = position }
        let recentPicks = Set(UserDefaults.standard.stringArray(forKey: recentPicksKey) ?? [])
        var used = 0
        for song in listenAgain where !isBlocked(song) {
            let weight = recentPicks.contains(song.videoId) ? base * 0.35 : base
            if let position = index[song.videoId] {
                list[position].weight = max(list[position].weight, weight)
            } else {
                index[song.videoId] = list.count
                list.append(Candidate(song: song, weight: weight))
                used += 1
            }
        }
        return (list, used)
    }

    // MARK: - Semillas y radios

    /// Dos canciones de artistas distintos, de las mas escuchadas (al azar ponderado). Se guardan 30 minutos: si se toca "Para ti" varias
    /// veces seguidas se repiten las mismas semillas y las radios salen de la cache de 10 minutos (cada radio son hasta 2 peticiones).
    static func pickSeeds(from familiar: [Candidate]) -> [(id: String, title: String)] {
        let defaults = UserDefaults.standard
        if let stored = defaults.dictionary(forKey: seedsKey),
           let at = stored["at"] as? Double, Date().timeIntervalSince1970 - at < 1800,
           let ids = stored["ids"] as? [String], let titles = stored["titles"] as? [String],
           !ids.isEmpty, ids.count == titles.count,
           !ids.contains(where: { LikeStore.shared.disliked.contains($0) || SleepFilter.shared.isSleep(videoId: $0) }) {
            return Array(zip(ids, titles)).map { (id: $0.0, title: $0.1) }
        }
        let ordered = weightedOrder(familiar)
        var picked: [SongItem] = []
        for song in ordered.prefix(14) {
            let key = artistKey(song)
            if picked.contains(where: { !key.isEmpty && artistKey($0) == key }) { continue }
            picked.append(song)
            if picked.count == 2 { break }
        }
        saveSeeds(picked)
        return picked.map { (id: $0.videoId, title: $0.title) }
    }

    static func seedsFromListenAgain(_ listenAgain: [SongItem]) -> [(id: String, title: String)] {
        var picked: [SongItem] = []
        for song in listenAgain.filter({ !isBlocked($0) }).shuffled() {
            let key = artistKey(song)
            if picked.contains(where: { !key.isEmpty && artistKey($0) == key }) { continue }
            picked.append(song)
            if picked.count == 2 { break }
        }
        saveSeeds(picked)
        return picked.map { (id: $0.videoId, title: $0.title) }
    }

    /// La primera cancion de la cola: una conocida de las de mas peso (al azar ponderado: cada "Para ti" parte de un estilo distinto).
    static func pickFirst(from familiar: [Candidate]) -> SongItem? {
        weightedOrder(familiar).first
    }

    /// Sin historial local: una de "Listen again" al azar.
    static func firstFromListenAgain(_ listenAgain: [SongItem]) -> SongItem? {
        listenAgain.filter { !isBlocked($0) }.randomElement()
    }

    /// Las conocidas que encajan con la primera cancion (estilo, animo, epoca). `note` explica como se filtro (para el informe).
    /// Con la clave de Gemini y "La radio recuerda" activado: una peticion de texto con las 60 de mas peso. Si no, o si falla o deja menos de 10:
    /// las del mismo artista o de artistas de su radio. Si tampoco salen 10, la lista entera (como antes).
    static func coherentFamiliar(first: SongItem, familiar: [Candidate], radio: [SongItem]) async -> (list: [Candidate], note: String) {
        let pool = familiar.filter { $0.song.videoId != first.videoId }
        let top = Array(pool.sorted { $0.weight > $1.weight }.prefix(60))
        if RadioSettings.isConfigured, RadioSettings.memoryEnabled, top.count >= 12 {
            let lines = top.enumerated().map { "\($0.offset + 1). \($0.element.song.artistNamesDisplay) - \($0.element.song.title)" }.joined(separator: "\n")
            let system = "Eres un experto en musica. Te doy una cancion de referencia y una lista numerada de canciones. Devuelve SOLO un JSON {\"encajan\": [numeros]} con las canciones de la lista que encajan con el ESTILO, el ANIMO y la EPOCA de la referencia, de modo que sonando seguidas no desentonen. Si dudas, NO la incluyas. No expliques nada."
            let prompt = "REFERENCIA: \(first.artistNamesDisplay) - \(first.title)\n\nLISTA:\n" + lines
            if let json = try? await Gemini.text(system: system, prompt: prompt, temperature: 0.1, timeout: 6),
               let data = json.data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let fits = object["encajan"] as? [Any] {
                let numbers = Set(fits.compactMap { ($0 as? NSNumber)?.intValue })
                let kept = top.enumerated().filter { numbers.contains($0.offset + 1) }.map { $0.element }
                if kept.count >= 10 { return (kept, "Gemini: \(kept.count) de \(top.count) encajan") }
            }
        }
        var artists = Set(radio.map(artistKey))
        artists.insert(artistKey(first))
        artists.remove("")
        let byArtist = pool.filter { artists.contains(artistKey($0.song)) }
        if byArtist.count >= 10 { return (byArtist, "por artistas de su radio: \(byArtist.count) de \(pool.count)") }
        return (pool, "sin filtro de estilo (\(byArtist.count) por artistas)")
    }

    private static func saveSeeds(_ songs: [SongItem]) {
        guard !songs.isEmpty else { return }
        UserDefaults.standard.set(
            ["at": Date().timeIntervalSince1970, "ids": songs.map(\.videoId), "titles": songs.map(\.title)] as [String: Any],
            forKey: seedsKey
        )
    }

    /// La radio de YouTube de cada semilla (hasta 2 peticiones cada una; con la cache de 10 min, ninguna). `cached`: respondio al instante.
    static func loadRadios(_ seeds: [(id: String, title: String)], limit: Int = 25) async -> RadioResult {
        let ids = seeds.map { $0.id }
        let allowExplicit = !SettingsStore.shared.hideExplicit
        return await withTaskGroup(of: (songs: [SongItem], cached: Bool).self) { group in
            for id in ids {
                group.addTask {
                    let started = Date()
                    let radio = try? await PersonalizationService.shared.fetchRadio(
                        videoId: id,
                        options: RadioOptions(style: .similar, limit: limit, allowExplicit: allowExplicit),
                        playlistId: nil
                    )
                    return (radio?.songs ?? [], Date().timeIntervalSince(started) < 0.05)
                }
            }
            var result = RadioResult()
            for await part in group {
                result.songs += part.songs
                if part.cached { result.cached += 1 } else { result.fetched += 1 }
            }
            return result
        }
    }

    // MARK: - Cola

    /// Al azar ponderado (Efraimidis-Spirakis): las de mas peso salen antes de media, pero no siempre las mismas.
    private static func weightedOrder(_ items: [Candidate]) -> [SongItem] {
        items
            .map { item -> (song: SongItem, key: Double) in
                let u = Double.random(in: 0.000_000_1 ..< 1)
                return (item.song, log(u) / item.weight)
            }
            .sorted { $0.key > $1.key }
            .map { $0.song }
    }

    static func compose(familiar: [Candidate], radios: [SongItem], saved: [SongItem], recentlyPlayed: Set<String>, first: SongItem? = nil) -> Composition {
        var composition = Composition()
        var familiarQueue = weightedOrder(familiar)
        let familiarIds = Set(familiar.map(\.song.videoId))
        composition.familiarPool = familiarQueue.count

        // Descubrimiento: radios primero (mezcladas) y luego la mezcla guardada.
        var seen = Set<String>()
        func usableForDiscovery(_ song: SongItem) -> Bool {
            !isBlocked(song)
                && song.musicVideoType != "MUSIC_VIDEO_TYPE_UGC"
                && !familiarIds.contains(song.videoId)
                && !recentlyPlayed.contains(song.videoId)
                && seen.insert(song.videoId).inserted
        }
        var discoveryQueue = radios.shuffled().filter(usableForDiscovery) + saved.shuffled().filter(usableForDiscovery)
        composition.discoveryPool = discoveryQueue.count

        var used = Set<String>()
        func next(from pool: inout [SongItem], after queue: [SongItem]) -> SongItem? {
            let recentArtists = queue.suffix(3).map(artistKey)
            let free = pool.firstIndex { song in
                let key = artistKey(song)
                return !used.contains(song.videoId) && (key.isEmpty || !recentArtists.contains(key))
            }
            if let free { return pool.remove(at: free) }
            if let any = pool.firstIndex(where: { !used.contains($0.videoId) }) { return pool.remove(at: any) }
            return nil
        }

        // La primera cancion (la de la que parte toda la cola) va en la posicion 0.
        var startPosition = 0
        if let first {
            used.insert(first.videoId)
            composition.queue.append(first)
            composition.isDiscovery.append(false)
            startPosition = 1
        }
        for position in startPosition ..< queueSize {
            // Una nueva en las posiciones 3, 6, 9, 13, 16, 19... (30%); la primera siempre es conocida.
            let wantsDiscovery = position >= 3 && ((position + 1) * 3 / 10 > position * 3 / 10)
            var pick: SongItem?
            var discovery = false
            if wantsDiscovery, let song = next(from: &discoveryQueue, after: composition.queue) {
                pick = song
                discovery = true
            } else if let song = next(from: &familiarQueue, after: composition.queue) {
                pick = song
            } else if let song = next(from: &discoveryQueue, after: composition.queue) {
                pick = song
                discovery = true
            }
            guard let song = pick else { break }
            used.insert(song.videoId)
            composition.queue.append(song)
            composition.isDiscovery.append(discovery)
        }
        return composition
    }

    /// Las primeras canciones de la cola: la proxima vez pesan menos (para que dos toques seguidos no den lo mismo).
    static func rememberPicks(_ queue: [SongItem]) {
        let previous = UserDefaults.standard.stringArray(forKey: recentPicksKey) ?? []
        let merged = queue.prefix(15).map(\.videoId) + previous
        UserDefaults.standard.set(Array(merged.prefix(90)), forKey: recentPicksKey)
    }
}
