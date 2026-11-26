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
    /// La epoca pedida como rango ("2000-2009"), o "" si la peticion no habla de epoca.
    var era = ""
    /// Lo que dijo la persona (para que el filtro de la cola sepa que se pidio).
    var request = ""
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
    - "busquedas": entre 3 y 6 consultas de busqueda cortas (maximo 6 palabras cada una), distintas entre si (genero y epoca, exitos, subgeneros, nombres de artistas representativos). Sin comillas ni operadores. NUNCA metas en una consulta el PARA QUE lo quiere ni su estado de animo (motivarme, entrenar, fiesta, relajarme, estudiar, coche...): eso se traduce en que artistas y canciones escoges, no en palabras de busqueda; esas palabras traen playlists y musica generica. Tampoco uses "playlist", "mix", "beat", "instrumental" ni "mejores". Si la peticion tiene EPOCA ("los 2000", "los 90", "del 2005"), TODAS las consultas llevan la decada escrita como "años 2000" o "años 90" (la decada entera: "los 2000" son 2000-2009; no uses un año suelto).
    - "artistas": entre 6 y 12 artistas reales y representativos. Solo los que estes SEGURO de que existen.
    - "canciones": entre 8 y 12 canciones muy conocidas con formato "Artista - Titulo", de artistas distintos, que encajen con lo pedido. Solo las que estes SEGURO de que existen. Si la peticion tiene EPOCA, que sean DE ESA EPOCA (publicadas dentro de ella). Si la peticion es de CALIDAD ("del bueno", "lo mejor", "clasicos", "top", "de referencia"), son los artistas y temas mas respetados y reconocidos del genero, no relleno.
    - "evitar": lista de estilos o palabras que NO encajan con lo pedido.
    - "usa_gustos": true si has usado los gustos de la persona para escoger artistas o canciones.
    - "confianza": numero de 0 a 1: cuanto estas seguro de haber entendido bien lo pedido.
    - "epoca": la epoca pedida como rango de años ("2000-2009", "1990-1999"), o "" si la peticion no habla de epoca.
    NO añadas generos, estilos ni paises que la persona no haya dicho: "lo mas top", "exitos" o "lo mejor" significan lo MAS POPULAR de esa epoca en general, de todos los generos. "De España" o "en España" significa lo que mas sono en España (incluida la musica internacional que triunfo alli), salvo que diga "española" o "en español".
    GUSTOS: si la peticion es especifica (genero, epoca o artista), manda la peticion y los gustos solo desempatan. Si es vaga (entrenar, fiesta, coche, sorprendeme, verano...), usa los gustos como DIRECCION (generos y estilos que le gustan) y mezcla artistas parecidos a los suyos, no solo los suyos. Si no se dan gustos, escoge lo mas representativo de lo pedido. NO des por hecho ningun idioma ni pais: no añadas "en español", ni artistas de un idioma o pais concreto, ni busquedas en un idioma, salvo que la persona lo pida (o lo diga de forma explicita en sus gustos). Si un nombre propio parece mal transcrito, corrigelo al artista mas probable. No inventes nada que no sepas.
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
            usesTaste: object["usa_gustos"] as? Bool ?? false,
            era: (object["epoca"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            request: spoken
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
    /// `anchors`: busca primero las canciones concretas de la receta (solo al empezar; en las ampliaciones de la cola ya estan). Antes solo con epoca: sin ella la cola
    /// salia de busquedas por palabras y de radios sembradas con sus primeros resultados (a menudo relleno).
    static func buildQueue(recipe: RadioRecipe, familiar: [SongItem], exclude: Set<String>, anchors useAnchors: Bool = true, seed startSeed: SongItem? = nil) async -> (songs: [SongItem], requests: Int) {
        var requests = 0
        var anchorSongs: [SongItem] = []
        var found: [SongItem] = []
        let hasEra = !recipe.era.isEmpty
        // Las canciones concretas que el modelo conoce de lo pedido (de ESA epoca, si la hay) van primero (hasta 5, una tras otra); son lo que mejor ancla la cola.
        let ranAnchors = useAnchors && !recipe.songs.isEmpty
        if ranAnchors {
            for entry in recipe.songs.prefix(5) {
                requests += 1
                anchorSongs += await searchSongs(entry, limit: 1)
            }
            PlaybackReport.record("radio: canciones de la receta\(hasEra ? " para la epoca \(recipe.era)" : ""): \(anchorSongs.count) encontradas de \(min(5, recipe.songs.count))")
        }
        // Busquedas: como mucho 3 (2 si ya se buscaron las canciones de la receta, que gastan mas), UNA TRAS OTRA (SearchService cancela la anterior si se lanzan a la vez, y asi no se rafaguea a YouTube).
        for query in recipe.searches.prefix(ranAnchors ? 2 : 3) {
            requests += 1
            found += await searchSongs(query, limit: 8)
        }
        // Canciones concretas de la receta: solo si salen pocas (el modelo puede equivocarse de titulo; solo suena lo que se encuentra).
        if !hasEra, !ranAnchors, found.count < 12 {
            for entry in recipe.songs.prefix(3) {
                requests += 1
                found += await searchSongs(entry, limit: 1)
            }
        }
        var seen = exclude
        let anchorPool = anchorSongs.filter { usable($0) && seen.insert($0.videoId).inserted }
        var searchPool = found.filter { usable($0) && seen.insert($0.videoId).inserted }

        // Radios: dos semillas de artistas distintos (primero de las canciones de la receta, que son las mas seguras).
        var seeds: [(id: String, title: String)] = []
        var seedArtists = Set<String>()
        // Si la radio empieza desde una cancion concreta, su propia radio de YouTube es la primera semilla (lo que mas se parece a ella).
        if let startSeed {
            seeds.append((id: startSeed.videoId, title: startSeed.title))
            seedArtists.insert(artistKey(startSeed))
        }
        for song in anchorPool + searchPool where seeds.count < 2 {
            if seedArtists.insert(artistKey(song)).inserted { seeds.append((id: song.videoId, title: song.title)) }
        }
        var radioPool: [SongItem] = []
        if !seeds.isEmpty {
            requests += seeds.count
            let radios = await ParaTiMix.loadRadios(seeds)
            radioPool = radios.songs.filter { usable($0) && seen.insert($0.videoId).inserted }
        }

        // Filtro final: Gemini descarta lo que claramente no encaja con lo pedido (otra epoca, otro genero).
        let approvedIds = Set(await approved(searchPool + radioPool, recipe: recipe).map { $0.videoId })
        searchPool = searchPool.filter { approvedIds.contains($0.videoId) }
        radioPool = radioPool.filter { approvedIds.contains($0.videoId) }

        // Conocidas tuyas cuyo artista encaja con la receta.
        let wanted = Set(recipe.artists.map { HiddenArtists.normalize($0) })
        let familiarPool = familiar.filter { song in
            usable(song) && song.artists.contains { wanted.contains(HiddenArtists.normalize($0.name)) } && seen.insert(song.videoId).inserted
        }
        let songs = compose(search: searchPool, radio: radioPool, familiar: familiarPool, first: anchorPool)
        return (songs, requests)
    }

    /// Las canciones que encajan con lo pedido: una sola peticion de texto a Gemini con la lista numerada; descarta las que CLARAMENTE no encajan. Si falla, o si
    /// descartaria casi todo, se queda con la lista entera.
    private static func approved(_ songs: [SongItem], recipe: RadioRecipe) async -> [SongItem] {
        guard songs.count >= 8, !recipe.request.isEmpty else { return songs }
        let judged = Array(songs.prefix(70))
        let lines = judged.enumerated().map { "\($0.offset + 1). \($0.element.artistNamesDisplay) - \($0.element.title)" }.joined(separator: "\n")
        var prompt = "PETICION: \(recipe.request) (resumen: \(recipe.summary))"
        if !recipe.era.isEmpty { prompt += "\nEPOCA PEDIDA: \(recipe.era) (canciones publicadas dentro de esos años)" }
        prompt += "\n\nCANCIONES:\n" + lines
        let system = "Eres un experto en musica. Te doy la peticion de una persona y una lista numerada de canciones. Devuelve SOLO un JSON {\"fuera\": [numeros]} con los numeros de las canciones que CLARAMENTE no encajan con lo pedido (sobre todo si son de otra epoca o de otro genero). Si la peticion pide CALIDAD (\"del bueno\", \"lo mejor\", \"clasicos\", \"top\"), tambien van fuera las genericas: beats, instrumentales, mezclas o temas de artistas sin reconocimiento. NO descartes una cancion por su idioma ni por su animo (motivador, triste, tranquilo...): el animo es para que lo quiere, no el estilo. Si dudas, NO la incluyas. No expliques nada."
        guard let json = try? await Gemini.text(system: system, prompt: prompt, temperature: 0.1, timeout: 8),
              let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let out = object["fuera"] as? [Any] else {
            PlaybackReport.record("radio: filtro de la cola: sin respuesta, se deja entera")
            return songs
        }
        let rejected = Set(out.compactMap { ($0 as? NSNumber)?.intValue })
        var kept: [SongItem] = []
        var dropped: [String] = []
        for (index, song) in judged.enumerated() {
            if rejected.contains(index + 1) {
                dropped.append("\(song.artistNamesDisplay) - \(song.title)")
            } else {
                kept.append(song)
            }
        }
        kept += songs.dropFirst(70)
        guard kept.count >= 10 else {
            PlaybackReport.record("radio: filtro de la cola: descartaria casi todo (\(dropped.count) de \(songs.count)), se deja entera")
            return songs
        }
        PlaybackReport.record("radio: filtro de la cola: \(dropped.count) descartadas de \(songs.count): " + dropped.prefix(12).joined(separator: " / "))
        return kept
    }

    /// Reparte las tres fuentes en un patron fijo (mas busquedas que radios y de vez en cuando una conocida) sin repetir artista en 3 seguidas.
    private static func compose(search: [SongItem], radio: [SongItem], familiar: [SongItem], first: [SongItem] = []) -> [SongItem] {
        // `first`: las canciones concretas de la receta (con epoca) salen antes que el resto de las busquedas.
        var pools: [String: [SongItem]] = ["a": first.shuffled() + search.shuffled(), "b": radio.shuffled(), "c": familiar.shuffled()]
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
