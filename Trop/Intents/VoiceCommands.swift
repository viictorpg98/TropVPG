//
//  VoiceCommands.swift
//  Trop
//
//  Ordenes por voz ("mis descargas", "activa el DJ", "apagalo en media hora"...) que se reconocen ANTES de buscar una cancion. Solo cuenta como
//  orden si lo que dijiste ES la orden entera (con "pon", "activa", "por favor" y articulos de sobra): "pon DJ Snake" o "pon Mezcla de Quevedo"
//  llevan mas palabras y se buscan como cancion. Para forzar la busqueda se puede empezar por "busca".
//
//  Como no fallar con las palabras cortas ("DJ", "mezcla"): se miran TODAS las transcripciones que devuelve el reconocedor, no solo la mejor, y se
//  admite una letra de diferencia en las palabras largas. Si la orden solo sale de una alternativa o de una coincidencia aproximada, Sonar
//  pregunta antes de hacerla ("¿Activo el DJ?"). Cada decision queda en el registro de voz.
//

import Foundation

enum VoiceCommand: Equatable {
    case downloads
    case forYou
    case liked
    case random
    case quickPicks
    case mix
    case nowPlaying
    case cancelTimer
    /// `on`: `true` activar, `false` apagar, `nil` cambiar (como el boton del widget).
    case dj(on: Bool?)
    /// `minutes`: `nil` si se pidio el temporizador pero no se entendio el tiempo.
    case sleepTimer(minutes: Int?)
    case category(SonarCategory)

    /// Si la orden se confirmo con un "no", puede que en realidad fuera una cancion ("Dormir", "Me gusta", "Fiestas"): se busca como tal.
    var couldBeSongTitle: Bool {
        switch self {
        case .downloads, .forYou, .liked, .random, .quickPicks, .mix, .category: return true
        case .nowPlaying, .cancelTimer, .dj, .sleepTimer: return false
        }
    }

    /// Preguntar antes de hacerlo si la orden no salio exacta. "Que suena" no cambia nada: no hace falta.
    var needsConfirmation: Bool {
        if case .nowPlaying = self { return false }
        if case .sleepTimer(let minutes) = self, minutes == nil { return false }
        return true
    }
}

struct VoiceCommandMatch {
    let command: VoiceCommand
    /// `true` si salio de la mejor transcripcion, sin aproximar.
    let exact: Bool
    /// La transcripcion de la que salio.
    let source: String
}

/// Lo que se pide sobre un artista, un album o una lista (no es una orden de la app ni el titulo de una cancion).
enum VoiceRequest: Equatable {
    enum LatestKind: Equatable { case album, single, any }

    /// "el ultimo album de X", "lo nuevo de X", "su ultima cancion".
    case latest(artist: String, kind: LatestKind)
    /// "lo mejor de X", "los exitos de X", "lo mas escuchado de X".
    case top(artist: String)
    /// "algo parecido a X", "musica como la de X", "radio de X".
    case radio(artist: String)
    /// "el album X", "el disco X".
    case album(query: String)
    /// "la lista X".
    case playlist(query: String)
}

enum VoiceCommands {
    // MARK: - Peticiones sobre artistas, albumes y listas

    private static let requestLead: Set<String> = fillers.union([
        "lo", "los", "las", "y", "que", "mas", "musica", "canciones", "temas", "cosas", "todo", "toda", "unos", "unas", "dime", "dame", "tu", "su"
    ])
    private static let latestWords: Set<String> = [
        "ultimo", "ultima", "ultimos", "ultimas", "nuevo", "nueva", "nuevos", "nuevas", "reciente", "recientes"
    ]
    private static let latestNouns: Set<String> = [
        "album", "albumes", "disco", "discos", "trabajo", "sencillo", "sencillos", "single", "singles", "cancion", "canciones", "tema", "temas",
        "lanzamiento", "lanzamientos"
    ]
    private static let albumNouns: Set<String> = ["album", "albumes", "disco", "discos", "trabajo"]
    private static let topWords: Set<String> = [
        "mejor", "mejores", "exitos", "populares", "escuchado", "escuchada", "escuchados", "escuchadas", "famosas", "famosos", "conocidas",
        "conocidos", "hits"
    ]
    private static let topNouns: Set<String> = ["canciones", "temas", "musica", "exitos", "hits", "cosas"]
    private static let radioWords: Set<String> = ["parecido", "parecida", "parecidos", "parecidas", "similar", "similares", "radio", "emisora", "estilo"]
    private static let radioConnectors: Set<String> = ["a", "de", "del", "al", "como", "que", "la", "el", "los", "las", "tipo"]

    /// "el ultimo album de Bad Bunny", "lo mejor de Quevedo", "algo parecido a Rels B", "el album Un Verano Sin Ti", "la lista Gym"... `nil` si la frase no
    /// es de ese tipo (se busca como cancion). Solo cuenta si ANTES de la palabra clave hay solo palabras de relleno ("pon", "el", "lo"...): asi
    /// "Ultimo Baile de Gale" o "Pon Como Te Quiero" siguen siendo canciones.
    static func parseRequest(_ spoken: String) -> VoiceRequest? {
        let original = spoken.split(separator: " ").map(String.init)
        let f = original.map { words($0).joined() }
        guard original.count >= 3 else { return nil }

        func subject(from index: Int, skipping skip: Set<String>) -> String? {
            var i = index
            while i < f.count, skip.contains(f[i]) { i += 1 }
            guard i < original.count else { return nil }
            return original[i...].joined(separator: " ")
        }
        func firstIndex(in set: Set<String>) -> Int? { f.firstIndex { set.contains($0) } }
        func onlyLead(before index: Int) -> Bool { f[..<index].allSatisfy { requestLead.contains($0) || $0.isEmpty } }

        // "el ultimo album de X", "lo nuevo de X", "la ultima cancion de X".
        if let i = firstIndex(in: latestWords), onlyLead(before: i) {
            var j = i + 1
            var kind = VoiceRequest.LatestKind.any
            while j < f.count, latestNouns.contains(f[j]) {
                kind = albumNouns.contains(f[j]) ? .album : .single
                j += 1
            }
            if j < f.count, ["de", "del"].contains(f[j]), let who = subject(from: j, skipping: ["de", "del"]) {
                return .latest(artist: who, kind: kind)
            }
        }
        // "lo mejor de X", "los exitos de X", "las canciones mas escuchadas de X".
        if let i = firstIndex(in: topWords), onlyLead(before: i) {
            var j = i + 1
            while j < f.count, topNouns.contains(f[j]) || f[j] == "mas" || topWords.contains(f[j]) { j += 1 }
            if j < f.count, ["de", "del"].contains(f[j]), let who = subject(from: j, skipping: ["de", "del"]) {
                return .top(artist: who)
            }
        }
        // "algo parecido a X", "musica similar a X", "radio de X", "algo del estilo de X", "musica como X".
        if let i = firstIndex(in: radioWords), onlyLead(before: i), i + 1 < f.count {
            // "estilo", "radio" y "emisora" solo con "de" ("estilo de X", "radio de X"): "Estilo Libre" o "Radio Ga Ga" son canciones.
            let next = f[i + 1]
            let nextOK = ["estilo", "radio", "emisora"].contains(f[i]) ? ["de", "del"].contains(next) : ["a", "al", "de", "del", "como"].contains(next)
            if nextOK, let who = subject(from: i + 1, skipping: radioConnectors) { return .radio(artist: who) }
        }
        if let i = f.firstIndex(of: "como"), i > 0, f[..<i].contains(where: { ["algo", "musica", "canciones", "temas", "cosas"].contains($0) }),
           onlyLead(before: i), let who = subject(from: i + 1, skipping: radioConnectors) {
            return .radio(artist: who)
        }
        // "el album X", "el disco X".
        if let i = firstIndex(in: albumNouns), onlyLead(before: i), let what = subject(from: i + 1, skipping: ["de", "del", "llamado", "titulado"]) {
            return .album(query: what)
        }
        // "la lista X", "la playlist X".
        if let i = firstIndex(in: ["lista", "listas", "playlist", "playlists"]), onlyLead(before: i),
           let what = subject(from: i + 1, skipping: ["de", "del", "reproduccion", "llamada", "titulada"]) {
            return .playlist(query: what)
        }
        return nil
    }

    // MARK: - Detectar

    static func detect(best: String, alternatives: [String]) -> VoiceCommandMatch? {
        if forcesSongSearch(best) { return nil }
        if let command = match(best, fuzzy: false) {
            return VoiceCommandMatch(command: command, exact: true, source: best)
        }
        for alternative in alternatives where alternative != best {
            if let command = match(alternative, fuzzy: false) {
                return VoiceCommandMatch(command: command, exact: false, source: alternative)
            }
        }
        if let command = match(best, fuzzy: true) {
            return VoiceCommandMatch(command: command, exact: false, source: best)
        }
        return nil
    }

    /// Las palabras de un texto, sin acentos ni mayusculas ni signos.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func forcesSongSearch(_ text: String) -> Bool {
        guard let first = words(text).first else { return false }
        return ["busca", "buscame", "buscar", "search", "find"].contains(first)
    }

    // MARK: - Palabras

    private static let fillers: Set<String> = [
        "el", "la", "los", "las", "lo", "un", "una", "algo", "de", "del", "por", "favor", "porfa", "oye", "gracias", "ahora",
        "puedes", "podrias", "quiero", "escuchar", "oir", "reproduce", "reproducir", "ponme", "pon", "poner", "activa", "activar",
        "enciende", "encender", "apaga", "apagar", "quita", "quitar", "desactiva", "desactivar", "arranca", "arrancar", "inicia",
        "iniciar", "empieza", "empezar", "deten", "detener", "modo", "sesion", "dime", "dame", "play", "put", "please", "the", "a", "some", "turn",
        "on", "off", "start", "stop"
    ]
    private static let offVerbs: Set<String> = [
        "apaga", "apagar", "quita", "quitar", "desactiva", "desactivar", "deten", "detener", "termina", "terminar", "stop", "off", "disable"
    ]
    private static let onVerbs: Set<String> = [
        "activa", "activar", "enciende", "encender", "arranca", "arrancar", "inicia", "iniciar", "empieza", "empezar", "pon", "ponme",
        "poner", "start", "on", "enable"
    ]
    private static let timerWords: Set<String> = ["temporizador", "timer"]
    /// Todo lo que puede decirse en una frase de temporizador; si hay una palabra mas, es otra cosa (una cancion, por ejemplo).
    private static let timerVocabulary: Set<String> = [
        "en", "de", "y", "media", "medio", "cuarto", "hora", "horas", "minuto", "minutos", "min", "mins", "hour", "hours", "minute",
        "minutes", "musica", "music", "half", "an", "in", "for", "sleep", "duermete", "duerme", "apagalo", "apagame", "paralo",
        "temporizador", "timer", "cuenta", "atras", "cancela", "cancelar", "anula", "anular", "cancel", "elimina", "borra", "mi", "mis"
    ]
    private static let cancelWords: Set<String> = [
        "cancela", "cancelar", "anula", "anular", "quita", "quitar", "desactiva", "desactivar", "elimina", "borra", "cancel"
    ]

    private static let djAliases = [
        "dj", "dis", "diyei", "dijei", "deyei", "dejota", "diyey", "dijey", "deyey", "didyei", "didjei", "djay", "diyay", "dyei", "dijay",
        "dejay", "deyay"
    ]
    private static let mixAliases = ["mezcla", "mezclar", "mezclalo", "mezclame", "mezclanos", "mix", "mixnow", "mixit"]
    private static let forYouAliases = ["parati", "mimezcla", "mimusica", "paratimezcla", "mimezclaparati", "foryou", "mymix", "mymusic"]
    private static let downloadsAliases = [
        "descargas", "misdescargas", "descargado", "descargada", "descargadas", "descargados", "musicadescargada", "cancionesdescargadas",
        "misdescargadas", "mimusicadescargada", "mismusicasdescargadas", "sinconexion", "sinred", "offline", "downloads", "mydownloads",
        "downloaded"
    ]
    private static let likedAliases = [
        "megusta", "mismegusta", "megustan", "quemegustan", "quemegusta", "favoritas", "misfavoritas", "misfavoritos", "favoritos",
        "liked", "mylikes", "likes", "mylikedsongs", "likedsongs"
    ]
    private static let randomAliases = [
        "aleatorio", "aleatoria", "alazar", "sorprendeme", "sorpresa", "cualquiera", "cualquiercosa", "random", "surpriseme", "anything"
    ]
    private static let quickPicksAliases = ["seleccionesrapidas", "seleccionrapida", "misseleccionesrapidas", "quickpicks", "mysquickpicks"]

    private static let categoryAliases: [(SonarCategory, [String])] = [
        (.sleep, ["dormir", "dormirme", "sleep", "sleeping", "sueno"]),
        (.relax, ["relajarme", "relajar", "relajarte", "relax", "relajante", "relajacion", "tranquila", "calma", "chill", "relaxing"]),
        (.focus, ["concentrarme", "concentrar", "concentracion", "estudiar", "trabajar", "focus", "study", "studying", "work"]),
        (.workout, ["entrenar", "entrenamiento", "gimnasio", "ejercicio", "workout", "gym", "correr", "running"]),
        (.party, ["fiesta", "party", "bailar"]),
        (.energize, ["energia", "energizar", "energize", "animarme", "animar", "animada"]),
        (.commute, ["desplazamientos", "desplazamiento", "trayecto", "commute", "viaje", "conducir"]),
        (.feelGood, ["buenrollo", "alegre", "feelgood", "contenta", "felicidad", "happy"]),
        (.romance, ["romantica", "romance", "romantico", "amor", "love"])
    ]

    // MARK: - Reconocer una transcripcion

    private static func match(_ text: String, fuzzy: Bool) -> VoiceCommand? {
        let tokens = words(text)
        guard !tokens.isEmpty, tokens.count <= 10 else { return nil }
        let tokenSet = Set(tokens)

        // Temporizador: cancelarlo o programarlo. Solo si TODAS las palabras son del temporizador ("pon No Mires Atras" no lo es).
        let isTimerPhrase = tokens.allSatisfy { fillers.contains($0) || timerVocabulary.contains($0) || number($0) != nil }
        if isTimerPhrase {
            let hasTimerWord = !tokenSet.isDisjoint(with: timerWords) || (tokenSet.contains("cuenta") && tokenSet.contains("atras"))
            if hasTimerWord {
                if !tokenSet.isDisjoint(with: cancelWords) { return .cancelTimer }
                return .sleepTimer(minutes: minutes(in: tokens))
            }
            let hasTimeUnit = !tokenSet.isDisjoint(with: ["minuto", "minutos", "min", "mins", "minute", "minutes", "hora", "horas", "hour", "hours"])
            let hasStopVerb = !tokenSet.isDisjoint(with: ["apagalo", "apagame", "apaga", "apagar", "duermete", "duerme", "paralo", "stop", "sleep"])
            if hasTimeUnit, hasStopVerb, let amount = minutes(in: tokens) { return .sleepTimer(minutes: amount) }
            if tokenSet.contains("duermete") || (tokenSet.contains("sleep") && tokenSet.contains("in")) {
                return .sleepTimer(minutes: minutes(in: tokens))
            }
        }

        let core = tokens.filter { !fillers.contains($0) }
        guard !core.isEmpty else { return nil }
        let compact = core.joined()

        // El DJ (se oye de muchas formas: "di yei", "de jota"...).
        // "de jota" se oye mucho para "DJ", pero "de" es una palabra de relleno y se habria quitado: se mira aparte.
        if hit(compact, djAliases, fuzzy: fuzzy) || (compact == "jota" && tokenSet.contains("de")) {
            if !tokenSet.isDisjoint(with: offVerbs), tokenSet.isDisjoint(with: ["on"]) { return .dj(on: false) }
            if !tokenSet.isDisjoint(with: onVerbs) { return .dj(on: true) }
            return .dj(on: nil)
        }
        if hit(compact, forYouAliases, fuzzy: fuzzy) { return .forYou }
        if hit(compact, mixAliases, fuzzy: fuzzy) { return .mix }
        if hit(compact, downloadsAliases, fuzzy: fuzzy) { return .downloads }
        if hit(compact, likedAliases, fuzzy: fuzzy) { return .liked }
        if hit(compact, randomAliases, fuzzy: fuzzy) { return .random }
        if hit(compact, quickPicksAliases, fuzzy: fuzzy) { return .quickPicks }

        // "Que suena", "que cancion es esta".
        if let first = core.first, ["que", "quien", "what", "whats", "who"].contains(first), core.count <= 6,
           !Set(core).isDisjoint(with: ["suena", "sonando", "cancion", "canta", "tema", "playing", "song", "this", "music"]) {
            return .nowPlaying
        }

        // "Suena" o "sonando" a secas (el reconocedor a veces se come el "que").
        if core == ["suena"] || core == ["sonando"] { return .nowPlaying }

        // Categorias ("algo para dormir").
        let categoryCore = core.filter { !["para", "for", "to", "me", "mi", "musica", "music", "cancion", "canciones", "temas"].contains($0) }
        if !categoryCore.isEmpty {
            let categoryCompact = categoryCore.joined()
            for (category, aliases) in categoryAliases where hit(categoryCompact, aliases, fuzzy: fuzzy) {
                return .category(category)
            }
        }
        return nil
    }

    /// `compact` es una de las formas de decirlo (exacta; o a una letra de distancia si `fuzzy` y la palabra es larga).
    private static func hit(_ compact: String, _ aliases: [String], fuzzy: Bool) -> Bool {
        if aliases.contains(compact) { return true }
        guard fuzzy, compact.count >= 6 else { return false }
        return aliases.contains { $0.count >= 6 && abs($0.count - compact.count) <= 1 && distance($0, compact) <= 1 }
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[y.count]
    }

    // MARK: - Minutos del temporizador

    private static let numberWords: [String: Int] = [
        "un": 1, "uno": 1, "una": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6, "siete": 7, "ocho": 8, "nueve": 9,
        "diez": 10, "once": 11, "doce": 12, "trece": 13, "catorce": 14, "quince": 15, "dieciseis": 16, "diecisiete": 17,
        "dieciocho": 18, "diecinueve": 19, "veinte": 20, "veintiuno": 21, "veintidos": 22, "veintitres": 23, "veinticuatro": 24,
        "veinticinco": 25, "veintiseis": 26, "veintisiete": 27, "veintiocho": 28, "veintinueve": 29, "treinta": 30, "cuarenta": 40,
        "cincuenta": 50, "sesenta": 60, "setenta": 70, "ochenta": 80, "noventa": 90,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "fifteen": 15,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60
    ]

    private static func number(_ word: String) -> Int? {
        Int(word) ?? numberWords[word]
    }

    /// "30 minutos", "media hora", "una hora y media", "un cuarto de hora", "treinta y cinco minutos". `nil` si no se entiende.
    static func minutes(in tokens: [String]) -> Int? {
        for (index, token) in tokens.enumerated() {
            let isMinute = ["minuto", "minutos", "min", "mins", "minute", "minutes"].contains(token)
            let isHour = ["hora", "horas", "hour", "hours"].contains(token)
            guard isMinute || isHour else { continue }
            if isHour, index > 0, ["media", "medio", "half"].contains(tokens[index - 1]) { return 30 }
            if isHour, index > 1, tokens[index - 1] == "de", tokens[index - 2] == "cuarto" { return 15 }
            if isHour, index > 0, tokens[index - 1] == "an", tokens.contains("half") { return 30 }
            var value = index > 0 ? number(tokens[index - 1]) : nil
            // "treinta y cinco": decena + "y" + unidad.
            if let unit = value, unit < 10, index > 2, tokens[index - 2] == "y", let tens = number(tokens[index - 3]), tens >= 20, tens % 10 == 0 {
                value = tens + unit
            }
            guard let amount = value ?? (isHour ? 1 : nil) else { continue }
            var total = isHour ? amount * 60 : amount
            // "una hora y media".
            if isHour, index + 2 < tokens.count, tokens[index + 1] == "y", tokens[index + 2] == "media" { total += 30 }
            return min(total, 600)
        }
        return nil
    }

    // MARK: - Textos

    /// Como se dice una categoria en voz alta ("Poniendo musica para dormir").
    static func label(for category: SonarCategory, spanish: Bool) -> String {
        switch category {
        case .sleep: return spanish ? "música para dormir" : "music for sleeping"
        case .relax: return spanish ? "música para relajarte" : "relaxing music"
        case .focus: return spanish ? "música para concentrarte" : "music to focus"
        case .workout: return spanish ? "música para entrenar" : "workout music"
        case .party: return spanish ? "música de fiesta" : "party music"
        case .energize: return spanish ? "música con energía" : "energizing music"
        case .commute: return spanish ? "música para el trayecto" : "commute music"
        case .feelGood: return spanish ? "música de buen rollo" : "feel-good music"
        case .romance: return spanish ? "música romántica" : "romantic music"
        }
    }

    /// Si el inicio de YouTube Music no tiene ese boton, se busca esto como una cancion cualquiera y suena con su radio.
    static func fallbackSearch(for category: SonarCategory, spanish: Bool) -> String {
        label(for: category, spanish: spanish)
    }

    /// "30 minutos", "una hora", "una hora y media", "2 horas".
    static func spokenDuration(_ minutes: Int, spanish: Bool) -> String {
        if spanish {
            if minutes == 1 { return "un minuto" }
            if minutes == 60 { return "una hora" }
            if minutes == 90 { return "una hora y media" }
            if minutes > 60, minutes % 60 == 0 { return "\(minutes / 60) horas" }
            return "\(minutes) minutos"
        }
        if minutes == 1 { return "one minute" }
        if minutes == 60 { return "an hour" }
        if minutes == 90 { return "an hour and a half" }
        if minutes > 60, minutes % 60 == 0 { return "\(minutes / 60) hours" }
        return "\(minutes) minutes"
    }
}
