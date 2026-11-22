//
//  RadioPlanner.swift
//  Trop
//
//  De lo que dices a lo que suena: la RECETA (Gemini convierte "reguetón del antiguo" en busquedas, artistas y epoca; probado en el PC, speechify-prueba\
//  radio-peticion2.py), la frase con la que confirman los locutores (en una llamada APARTE, para que sus reintentos no retrasen la musica) y la COLA de
//  canciones (busquedas en YouTube Music una tras otra y como mucho dos radios: los fallos de YouTube vienen del ritmo de peticiones). Todo pasa por el
//  filtro de "Para ti" (musica de dormir, artistas ocultos, "no me gusta") y por el de "Esto no, en la radio".
//

import Foundation

struct RadioRecipe {
    var summary: String
    var searches: [String]
    var artists: [String]
    var songs: [String]
    var avoid: [String]
    var confidence: Double
    var usesTaste: Bool
}

struct RadioTaste {
    let text: String
    let familiar: [SongItem]
}

/// Las canciones a las que has dicho "Esto no, en la radio" (solo afecta a la radio).
enum RadioBlocklist {
    private static let storageKey = "radio.blocklist.v1"

    static func key(for song: SongItem) -> String {
        HiddenArtists.normalize(song.title) + "|" + HiddenArtists.normalize(song.artists.first?.name ?? "")
    }

    private static var saved: [String] {
        UserDefaults.standard.stringArray(forKey: storageKey) ?? []
    }

    static func contains(_ song: SongItem) -> Bool {
        let entries = saved
        return entries.contains(song.videoId) || entries.contains(key(for: song))
    }

    static func add(_ song: SongItem) {
        var entries = saved
        entries.append(song.videoId)
        entries.append(key(for: song))
        UserDefaults.standard.set(Array(entries.suffix(400)), forKey: storageKey)
    }
}

@MainActor
enum RadioPlanner {
    private static let recipeSystem = """
    Eres el "cerebro musical" de una radio dentro de una app de musica. Una persona acaba de decir en voz alta lo que quiere escuchar (el texto viene de un reconocedor de voz y puede tener errores de transcripcion, sobre todo en nombres propios). Conviertelo en una receta para buscar musica en YouTube Music.
    Devuelve SOLO un objeto JSON con estas claves:
    - "resumen": 2 a 5 palabras en español que describen lo pedido.
    - "busquedas": entre 3 y 6 consultas de busqueda cortas (maximo 6 palabras cada una), distintas entre si (genero y epoca, exitos, subgeneros). Sin comillas ni operadores.
    - "artistas": entre 6 y 12 artistas reales y representativos. Solo los que estes SEGURO de que existen.
    - "canciones": entre 0 y 6 canciones muy conocidas con formato "Artista - Titulo". Solo las que estes SEGURO de que existen.
    - "evitar": lista de estilos o palabras que NO encajan con lo pedido.
    - "usa_gustos": true si has usado los gustos de la persona para escoger artistas o canciones.
    - "confianza": numero de 0 a 1: cuanto estas seguro de haber entendido bien lo pedido.
    GUSTOS: si la peticion es especifica (genero, epoca o artista), manda la peticion y los gustos solo desempatan. Si es vaga (entrenar, fiesta, coche, sorprendeme, verano...), usa los gustos como DIRECCION (generos y estilos que le gustan) y mezcla artistas parecidos a los suyos, no solo los suyos. Si no se dan gustos, escoge lo mas representativo de lo pedido. Si un nombre propio parece mal transcrito, corrigelo al artista mas probable. No inventes nada que no sepas.
    """

    private static let confirmationRules = """
    REGLAS DE LA CONFIRMACION: los locutores confirman, con gracia, lo que se va a poner. Suena a gente real hablando en español de Puerto Rico informal (alguna duda o muletilla leve, sin florituras ni frases de anuncio). Habla del estilo o de la epoca; NO cites artistas ni apodos de artistas ni datos de canciones. Cada turno, 4 a 16 palabras. No uses las muletillas prohibidas. No empieces como las confirmaciones ya dichas.
    Responde SOLO con un JSON, sin texto antes ni despues: una lista de objetos {"speaker": "Pitirre" o "Chuleta", "text": "..."}.
    """

    private static let confirmationFormats: [String: String] = [
        "reaccion": "reacciona con una exclamacion corta y natural al estilo o la epoca pedidos, con un chiste muy breve.",
        "pique": "pica con cariño al otro locutor o a la persona por lo que ha pedido.",
        "aviso": "avisa con exageracion de que va a sonar algo (a los vecinos, a la calle, al local), con humor.",
        "pregunta": "haz una pregunta corta de complicidad sobre lo pedido y contesta tu mismo o que conteste el otro.",
        "nostalgia": "recuerda con cariño la epoca o el estilo, SIN inventar datos concretos de canciones ni de personas.",
        "orden": "manda subir el volumen o ponerse comodo, con gracia, y confirma lo que se pone.",
        "seca": "confirmacion seca y breve, como en una radio de verdad, sin chiste: solo lo que se va a poner."
    ]

    private static var formatDeck: [String] = []

    /// Muletillas de las primeras pruebas: al principio de una frase o en cualquier sitio.
    private static let bannedAtStart = try? NSRegularExpression(
        pattern: "^\\W*(dale|suéltate|sueltate|ahora mismo|prepárate|preparate)\\b", options: [.caseInsensitive]
    )
    private static let bannedAnywhere = try? NSRegularExpression(
        pattern: "mi amor|\\bnena\\b|mi hermano|te voy a poner|puro fuego", options: [.caseInsensitive]
    )

    // MARK: - Gustos

    /// Lo que mas escucha (para la receta) y sus canciones conocidas sin musica de dormir (para mezclarlas con la cola).
    static func taste() async -> RadioTaste {
        let listening = (try? await DatabaseService.shared.fetchListeningStats()) ?? (stats: [], eventsRead: 0)
        let profile = ParaTiMix.localProfile(stats: listening.stats, eventsRead: listening.eventsRead, now: Date())
        var weights: [String: Double] = [:]
        var names: [String: String] = [:]
        for candidate in profile.familiar {
            guard let artist = candidate.song.artists.first?.name, !artist.isEmpty else { continue }
            let key = HiddenArtists.normalize(artist)
            weights[key, default: 0] += candidate.weight
            names[key] = artist
        }
        let top = weights.sorted { $0.value > $1.value }.prefix(8).compactMap { names[$0.key] }
        let text = top.isEmpty ? "" : "GUSTOS DE LA PERSONA: artistas que mas escucha: " + top.joined(separator: ", ") + "."
        return RadioTaste(text: text, familiar: profile.familiar.map { $0.song })
    }

    // MARK: - Receta

    static func recipe(for spoken: String, taste: String) async throws -> RadioRecipe {
        let prompt = (taste.isEmpty ? "" : taste + "\n\n") + "LO QUE DIJO LA PERSONA: " + spoken
        let json = try await Gemini.text(system: recipeSystem, prompt: prompt, temperature: 0.4, timeout: 8)
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Gemini.Failure(code: 0, message: "la receta no era JSON")
        }
        func strings(_ key: String) -> [String] {
            (object[key] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        }
        let recipe = RadioRecipe(
            summary: object["resumen"] as? String ?? spoken,
            searches: strings("busquedas"),
            artists: strings("artistas"),
            songs: strings("canciones"),
            avoid: strings("evitar"),
            confidence: (object["confianza"] as? NSNumber)?.doubleValue ?? 0.5,
            usesTaste: object["usa_gustos"] as? Bool ?? false
        )
        guard !recipe.searches.isEmpty || !recipe.artists.isEmpty else {
            throw Gemini.Failure(code: 0, message: "la receta no traia busquedas")
        }
        return recipe
    }

    // MARK: - Confirmacion

    private static func drawFormat() -> String {
        if formatDeck.isEmpty { formatDeck = Array(confirmationFormats.keys).shuffled() }
        return formatDeck.removeLast()
    }

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func firstWord(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.letters.inverted).first { !$0.isEmpty } ?? ""
    }

    /// El audio con el que los locutores confirman lo que van a poner (1 o 2 locutores, formato distinto cada vez). `nil` si no se puede.
    static func confirmationClip(spoken: String, recipe: RadioRecipe) async -> RadioClip? {
        let format = drawFormat()
        let twoVoices = Bool.random()
        let first = Bool.random() ? "Pitirre" : "Chuleta"
        let second = first == "Pitirre" ? "Chuleta" : "Pitirre"
        let who = twoVoices ? "LOS DOS locutores, dos turnos: primero \(first) y despues \(second)." : "UN solo locutor: \(first)."
        let history = RadioHistory.all()
        let usedOpenings = Set(history.suffix(6).compactMap { $0.first.map { firstWord($0.text) } })
        var notice = ""
        // Si el ultimo intento solo falla por la apertura o una muletilla (no por el numero de turnos ni por la forma), se usa antes que quedarse sin confirmacion.
        var acceptable: [RadioTurn]?
        for _ in 0..<2 {
            var prompt = "LO QUE DIJO LA PERSONA: \(spoken)\nLO QUE SE VA A PONER: \(recipe.summary)\n"
            if recipe.confidence < 0.6 {
                prompt += "La peticion no estaba clara: confirma que vas con lo que mas le suele gustar a la persona, sin preguntar nada.\n"
            }
            prompt += "CONFIRMACION: \(who)\nFORMATO: \(confirmationFormats[format] ?? "")"
            prompt += RadioHistory.promptBlock(count: 6) + notice
            guard let json = try? await Gemini.text(
                system: RadioContent.ficha + "\n\n" + confirmationRules, prompt: prompt, temperature: 1.0, timeout: 8
            ) else { return nil }
            let turns = RadioContent.parseTurns(json)
            var problems: [String] = []
            if turns.count != (twoVoices ? 2 : 1) { problems.append("numero de turnos") }
            for (index, turn) in turns.enumerated() {
                if matches(bannedAtStart, turn.text) || matches(bannedAnywhere, turn.text) { problems.append("muletilla prohibida") }
                if turn.text.split(separator: " ").count > 20 { problems.append("turno largo") }
                if index == 0, usedOpenings.contains(firstWord(turn.text)) { problems.append("empieza como una anterior") }
            }
            if twoVoices, turns.count == 2, turns[0].speaker == turns[1].speaker { problems.append("mismo locutor") }
            if problems.isEmpty {
                RadioHistory.add(turns)
                return await RadioVoice.clip(turns)
            }
            let soft: Set<String> = ["muletilla prohibida", "empieza como una anterior"]
            if turns.count == (twoVoices ? 2 : 1), Set(problems).isSubset(of: soft) { acceptable = turns }
            notice = "\n\nEL INTENTO ANTERIOR FALLO POR: " + problems.joined(separator: "; ") + ". Corrigelo."
        }
        if let acceptable {
            RadioHistory.add(acceptable)
            return await RadioVoice.clip(acceptable)
        }
        return nil
    }

    // MARK: - Cola

    private static func artistKey(_ song: SongItem) -> String {
        song.artists.first?.name.lowercased() ?? ""
    }

    private static func usable(_ song: SongItem) -> Bool {
        !ParaTiMix.isBlocked(song)
            && !RadioBlocklist.contains(song)
            && song.musicVideoType != "MUSIC_VIDEO_TYPE_UGC"
            && song.musicVideoType != "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"
    }

    /// Canciones de una busqueda (las de la seccion "Canciones" primero).
    private static func searchSongs(_ query: String, limit: Int) async -> [SongItem] {
        guard let raw = try? await SearchService.shared.search(query: query) else { return [] }
        let sections = SearchParser.parseSearchResults(from: raw)
        let preferred = sections.first { $0.title.lowercased().contains("song") || $0.title.lowercased().contains("canci") }
        var songs: [SongItem] = []
        for section in ([preferred].compactMap { $0 } + sections) {
            for item in section.items {
                if case .song(let song) = item, !songs.contains(where: { $0.videoId == song.videoId }) { songs.append(song) }
            }
            if songs.count >= limit { break }
        }
        return Array(songs.prefix(limit))
    }

    /// La cola de la radio (hasta 30 canciones) y cuantas peticiones a YouTube hizo. `exclude`: lo que ya sono o esta en la cola.
    static func buildQueue(recipe: RadioRecipe, familiar: [SongItem], exclude: Set<String>) async -> (songs: [SongItem], requests: Int) {
        var requests = 0
        var found: [SongItem] = []
        // Busquedas: como mucho 3, UNA TRAS OTRA (SearchService cancela la anterior si se lanzan a la vez, y asi no se rafaguea a YouTube).
        for query in recipe.searches.prefix(3) {
            requests += 1
            found += await searchSongs(query, limit: 8)
        }
        // Canciones concretas de la receta: solo si salen pocas (el modelo puede equivocarse de titulo; solo suena lo que se encuentra).
        if found.count < 12 {
            for entry in recipe.songs.prefix(3) {
                requests += 1
                found += await searchSongs(entry, limit: 1)
            }
        }
        var seen = exclude
        let searchPool = found.filter { usable($0) && seen.insert($0.videoId).inserted }

        // Radios: dos semillas de artistas distintos de lo encontrado.
        var seeds: [(id: String, title: String)] = []
        var seedArtists = Set<String>()
        for song in searchPool where seeds.count < 2 {
            if seedArtists.insert(artistKey(song)).inserted { seeds.append((id: song.videoId, title: song.title)) }
        }
        var radioPool: [SongItem] = []
        if !seeds.isEmpty {
            requests += seeds.count
            let radios = await ParaTiMix.loadRadios(seeds)
            radioPool = radios.songs.filter { usable($0) && seen.insert($0.videoId).inserted }
        }

        // Conocidas tuyas cuyo artista encaja con la receta.
        let wanted = Set(recipe.artists.map { HiddenArtists.normalize($0) })
        let familiarPool = familiar.filter { song in
            usable(song) && song.artists.contains { wanted.contains(HiddenArtists.normalize($0.name)) } && seen.insert(song.videoId).inserted
        }
        let songs = compose(search: searchPool, radio: radioPool, familiar: familiarPool)
        return (songs, requests)
    }

    /// Reparte las tres fuentes en un patron fijo (mas busquedas que radios y de vez en cuando una conocida) sin repetir artista en 3 seguidas.
    private static func compose(search: [SongItem], radio: [SongItem], familiar: [SongItem]) -> [SongItem] {
        var pools: [String: [SongItem]] = ["a": search.shuffled(), "b": radio.shuffled(), "c": familiar.shuffled()]
        let pattern = ["a", "b", "a", "c", "b", "a"]
        var result: [SongItem] = []
        var step = 0
        while result.count < 30, pools.values.contains(where: { !$0.isEmpty }) {
            let order = (0..<pattern.count).map { pattern[(step + $0) % pattern.count] }
            step += 1
            guard let name = order.first(where: { !(pools[$0] ?? []).isEmpty }), var pool = pools[name] else { continue }
            let recent = result.suffix(3).map(artistKey)
            let index = pool.firstIndex { song in
                let key = artistKey(song)
                return key.isEmpty || !recent.contains(key)
            } ?? 0
            result.append(pool.remove(at: index))
            pools[name] = pool
        }
        return result
    }
}
