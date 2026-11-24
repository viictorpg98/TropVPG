//
//  RadioContent.swift
//  Trop
//
//  Lo que dicen los locutores de Sónar efe eme: la ficha de la emisora, los guiones de los comentarios entre canciones (portados de las pruebas del
//  PC, speechify-prueba\gemini-guion.py), las frases fijas (preguntas, rellenos, cuñas) y la memoria de lo ya dicho para no repetirse.
//  Los locutores son personajes inventados: dos puertorriqueños afincados en España. NUNCA se inventa nada de las canciones ni de los artistas.
//

import Foundation

enum RadioPieceKind {
    case mini, charla, section
}

/// Lo ultimo que dijeron, para que no se repitan ideas ni palabras.
enum RadioHistory {
    private static let key = "radio.history.v1"
    private static let limit = 12

    private static let stopWords: Set<String> = Set("""
    para pero como esta este esto esas esos estoy estas pues porque cuando donde tambien entonces ahora siempre nunca todo toda todos todas aqui alli algo alguien
    nadie mucho mucha muchos muchas tiene tienes tengo hacer haces hace voy vamos dice dices digo eso esa ese bien mismo misma solo sola cosa cosas vez veces dale mira
    nene wepa suena sonar quiero quiere puedo puede quien quienes sobre entre desde hasta cada otro otra otros otras
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    static func all() -> [[RadioTurn]] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([[RadioTurn]].self, from: data) else { return [] }
        return saved
    }

    static func add(_ turns: [RadioTurn]) {
        var saved = all()
        saved.append(turns)
        if saved.count > limit { saved.removeFirst(saved.count - limit) }
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Palabras de 5 letras o mas que ya salieron 3 veces o mas.
    static func usedWords(minimum: Int = 3, top: Int = 14) -> [String] {
        var counts: [String: Int] = [:]
        for turns in all() {
            for turn in turns {
                for word in words(in: turn.text) where !stopWords.contains(word) { counts[word, default: 0] += 1 }
            }
        }
        return counts.filter { $0.value >= minimum }.sorted { $0.value > $1.value }.prefix(top).map { $0.key }
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 5 }
    }

    /// El bloque que se añade al prompt.
    static func promptBlock(count: Int) -> String {
        let recent = all().suffix(count)
        guard !recent.isEmpty else { return "" }
        var text = "\n\nYA SE DIJO ANTES (no repitas ideas, chistes, objetos ni giros de esto):\n"
        text += recent.map { "- " + $0.map(\.text).joined(separator: " / ") }.joined(separator: "\n")
        let used = usedWords()
        if !used.isEmpty { text += "\nPALABRAS YA MUY USADAS (evitalas): " + used.joined(separator: ", ") }
        text += RadioSlang.promptLine()
        return text
    }
}

enum RadioContent {
    /// La ficha de la emisora, con la ciudad elegida en Ajustes y el bloque de lo local (ver `RadioLocal`).
    static var ficha: String { fichaWith(humor: RadioHumor.current) }

    /// La ficha con el texto del nivel de humor (ver `RadioHumor`).
    static func fichaWith(humor: RadioHumorLevel) -> String {
        fichaBase.replacingOccurrences(of: "{CIUDAD}", with: RadioLocal.cityName) + "\n" + RadioLocal.block + RadioHumor.block(for: humor)
    }

    private static let fichaBase = """
    EMISORA: Sónar efe eme, una radio con humor gamberro y mucho cachondeo. Si nombras la emisora, escribe su nombre como "Sónar efe eme".
    LOCUTORES (personajes inventados, NO personas reales): dos puertorriqueños que viven en {CIUDAD} y hacen radio desde alli. Hablan español de Puerto Rico informal, como cualquier persona normal: se les nota el acento y algun giro suelto de vez en cuando, casi nunca el mismo (sin exagerar ni caricaturizar), y miran la zona con ojos de fuera, siempre con cariño.
    - El Pitirre (hombre, 30 y pico): relajado, chulito, arrastra las palabras, se rie facil de sus propios chistes. Presenta. Su speaker es "Pitirre".
    - La Chuleta (mujer, 30 y pico): rapida, picona, se burla de Pitirre sin piedad, interrumpe, se rie con ganas. Lo desmonta todo. Su speaker es "Chuleta".
    RELACION: se pican todo el rato con cariño y se llaman por el mote.
    """

    private static let commonRules = """
    - Suena a gente real hablando, no a texto escrito: frases cortas (maximo 18 palabras), alguna duda ("pues", "o sea", "mira"). Nada de discursos.
    - Prefiere una observacion sencilla y concreta sobre algo cotidiano a un chiste: NO todas las intervenciones necesitan gracia, a veces solo presentan la cancion con naturalidad, como una radio normal. Cuando haya humor, que sea pequeño y concreto. Prohibido: chistes de manual con remate y moraleja, listas de tres elementos, eslogan publicitario, frases tipo "porque siempre hay alguien que...", juegos de palabras forzados.
    - Si se te dan DATOS REALES EXTRA (lo que suena, tu historial, el tiempo), puedes usar UNO solo si cabe natural y SOLO tal cual vienen; no inventes ningun otro dato ni año ni cifra.
    - Puedes aludir a la cancion SOLO con lo que se te da: jugar con las palabras del titulo, el contraste entre una cancion y la siguiente. NO inventes NADA sobre la cancion, el artista, su vida, su discografia, premios, listas ni anecdotas. Si no estas seguro, no lo digas.
    - No uses nombres de personas reales ni imites a nadie. No pongas indicaciones escenicas entre parentesis. Para una risa usa exactamente la etiqueta <laugh>.
    - NO hables de comida, bebida, dieta, cocina ni hambre. Regla estricta.
    - Cada intervencion debe ser DISTINTA de las anteriores: otro tema, otros detalles, otras palabras. Si el historial que se te da ya usa una idea, un objeto o un chiste, elige otro.
    - Lo que dicen suena NATURAL, como lo diria una persona de verdad en una conversacion: reaccionan a lo que dice el otro, no recitan, no sueltan eslogan y no explican los chistes. Y lo dicen con el tono de dos locutores de radio, el que sea mas natural en cada momento (animados, tranquilos, complices, serios, burlones...), sin forzar la energia. Prohibido decir "wepa".
    - La jerga puertorriqueña es un condimento MUY escaso: una expresion suelta de vez en cuando (en menos de la mitad de las piezas), nunca la misma que en las piezas de YA SE DIJO ANTES, y nunca como relleno ni para cerrar. No repitas el arranque ("oye", "mira", "pues") de las piezas anteriores, ni el mismo tono (por ejemplo, que la misma persona siempre sea la sarcastica).
    - No cierres todas las piezas con una frase hecha ("dale fuego", "suena brutal", "vamos con..."): a veces solo presentas la cancion, o la frase acaba donde acaba la idea. Cada pieza debe sonar distinta de las anteriores, no a plantilla.
    - Cada linea puede llevar un campo opcional "tono" con UNO de estos valores: \(RadioTone.names). Pon en cada linea el tono con el que la diria un locutor de radio en ese momento, el mas natural (no hace falta variarlo por variarlo: si el de siempre del personaje encaja, omite el campo). Reserva susurro, grito e incredulo para cuando el contenido lo pida de verdad.
    - Responde SOLO con un JSON, sin texto antes ni despues: un objeto {"tema": "de que va la pieza en 3 a 6 palabras", "lineas": [{"speaker": "Pitirre" o "Chuleta", "text": "...", "tono": "..." (opcional)}]}.
    """

    /// Reglas de las piezas entre canciones; la forma, el proposito y la longitud de cada una vienen en su PLAN (ver `RadioShapes`).
    private static let pieceRules = """
    REGLAS (PIEZA ENTRE CANCIONES):
    - El PLAN del mensaje dice de que va, la FORMA de la conversacion y la LONGITUD: respetalos. Como mucho un <laugh>.
    - Nombra la cancion que viene (titulo y artista) cuando sea natural: al principio o al final; en las piezas muy cortas puede bastar con eso.
    - Si se te dan DATOS REALES o RECUERDOS de la persona, puedes usarlos tal cual (solo esos; no inventes ningun otro dato sobre ella).
    - No todo es chiste: la mayoria de las piezas son radio normal, con calidez. Las pullas entre ellos, como mucho una pequeña, y no en todas las piezas.
    - Las frases pueden quedar a medias, con dudas o con una interrupcion, como en una conversacion real.

    """ + commonRules

    /// Las reglas de las piezas segun el nivel de humor: con picante o negro se quitan las lineas que piden poca gracia, pullas pequeñas o jerga escasa (si no, se
    /// contradicen con el humor). La prueba del PC (`humor-prueba.py`) repite estos mismos cambios.
    private static func rules(for level: RadioHumorLevel) -> String {
        guard level != .mild else { return pieceRules }
        return pieceRules
            .replacingOccurrences(of: "- No todo es chiste: la mayoria de las piezas son radio normal, con calidez. Las pullas entre ellos, como mucho una pequeña, y no en todas las piezas.", with: "- Casi todas las piezas llevan chiste y mala leche; las pullas entre ellos pueden ser duras. De vez en cuando basta con presentar la cancion con calidez.")
            .replacingOccurrences(of: "Prefiere una observacion sencilla y concreta sobre algo cotidiano a un chiste: NO todas las intervenciones necesitan gracia, a veces solo presentan la cancion con naturalidad, como una radio normal. Cuando haya humor, que sea pequeño y concreto. Prohibido:", with: "El humor es concreto, con veneno y sobre algo cotidiano muy especifico. Prohibido:")
            .replacingOccurrences(of: "es un condimento MUY escaso: una expresion suelta de vez en cuando (en menos de la mitad de las piezas), nunca la misma", with: "se usa con moderacion, nunca la misma")
    }

    private static let charlaFormats = [
        "una dedicatoria absurda pero creible de un oyente a otro oyente (nombres de pila normales inventados, nada de famosos)",
        "discuten fingiendo enfado por una tonteria cotidiana muy concreta del TEMA",
        "uno cuenta una anecdota corta de lo que le paso hoy y el otro no se la cree",
        "una noticia falsa y absurda de un sitio INVENTADO (negocios, calles y personas con nombres inventados; nada de lugares, clubes ni empresas reales), de tres frases, con un dato ridiculo y muy concreto, como cachondeo de la emisora",
        "un fallo en directo (se les cruza un papel, entra una llamada equivocada, se cuelga el equipo) y lo resuelven mal",
        "una apuesta tonta entre ellos sobre algo de la proxima cancion (el titulo, el nombre del artista) con un premio ridiculo",
        "un consejo gamberro para el oyente que va conduciendo o trabajando",
        "uno presume de algo y el otro lo desmonta con un detalle concreto",
        "la resena falsa de un negocio de barrio inventado (con nombre y un detalle absurdo pero concreto)",
        "una charla tranquila SIN chiste: comentan algo cotidiano muy concreto que les paso esta semana, como dos colegas hablando en el estudio, y presentan la cancion",
        "uno le cuenta al otro algo que noto hoy yendo por la calle (un detalle concreto y real de cualquier ciudad), sin remate, y el otro responde con curiosidad"
    ]

    /// Solo salen cuando se permite hablar de la hora o del momento del dia (de vez en cuando; ver `reserveHourSlot`).
    private static let charlaHourFormats = [
        "comentan que significa ese momento del dia y de la semana, con un recuerdo concreto de cuando eran chicos",
        "una charla tranquila SIN chiste: comentan algo cotidiano muy concreto de esta hora del dia, como dos colegas hablando en el estudio, y presentan la cancion"
    ]

    /// Solo sale cuando hay datos de la persona (1 de cada 3 charlas): los locutores la vacilan con SUS datos, como si la radio fuese ella.
    private static let dataFormat = "los locutores vacilan al oyente con SUS DATOS REALES de la lista de abajo (lo que pide, lo que mas suena, los 'Esto no', los recuerdos de otros dias), como si la radio fuese el oyente; con cariño y sin inventar ningun dato"

    private static let miniFormats = [
        "una broma corta jugando con las palabras del titulo de la cancion que ACABA de sonar",
        "una broma corta jugando con las palabras del titulo de la cancion que VIENE",
        "un comentario sobre el contraste entre las dos canciones (sin inventar ningun dato de ellas)",
        "una pulla de un locutor al otro, y anuncia la siguiente cancion",
        "una reaccion exagerada a lo que acaba de sonar, sin afirmar nada concreto sobre la cancion",
        "anunciar la siguiente cancion de forma gamberra, con un detalle cotidiano inventado y concreto que no tenga que ver con la cancion",
        "presentar la siguiente cancion con naturalidad, SIN chiste: una frase de radio normal, calida, y ya",
        "una observacion corta y real sobre algo cotidiano (sin hablar de la hora), sin remate, y presentar la siguiente"
    ]

    /// Solo salen cuando se permite hablar de la hora o del momento del dia.
    private static let miniHourFormats = [
        "un comentario sobre la hora o el dia en que estamos, y presenta la siguiente",
        "presentar la siguiente cancion con naturalidad, SIN chiste: un comentario sencillo sobre el momento del dia y nada mas",
        "una observacion corta y real sobre lo que se suele hacer a esta hora del dia, sin remate, y presentar la siguiente"
    ]

    private static let topics = [
        "el trabajo y los jefes", "el trafico y los atascos", "las mascotas", "los vecinos", "el movil y las redes sociales", "el calor o la lluvia",
        "el gimnasio y el deporte", "la familia y las reuniones", "los viajes y los aeropuertos", "ir de compras y las rebajas", "el coche y el taller",
        "las citas y el ligue", "la escuela y los examenes", "la tecnologia que no funciona", "el banco y los papeles", "la ropa y el pelo",
        "las fiestas y los cumpleaños", "dormir y el insomnio", "el beisbol o el futbol", "las vacaciones", "los apodos y los motes",
        "la musica de cuando eran chicos", "las mudanzas", "las filas y los tramites", "las llamadas equivocadas", "el wifi", "la playa",
        "los horarios de España", "el transporte publico de la ciudad", "el frio de España visto por dos caribeños"
    ]

    private static let manias = [
        "La Chuleta lleva la cuenta de las veces que el Pitirre dice 'mañana'",
        "el Pitirre habla de su primo, que 'sabe de todo' y siempre se equivoca",
        "el Pitirre se queja del calor aunque este lloviendo",
        "La Chuleta cuenta algo que le dijo su comadre, que siempre exagera",
        "al Pitirre se le olvida el nombre de la persona con la que habla",
        "La Chuleta interrumpe al Pitirre para corregirle un dato que luego resulta ser ella la equivocada",
    ] + Array(repeating: "(ninguna manía: esta charla es limpia, sin gags recurrentes)", count: 10)

    nonisolated(unsafe) private static var miniDeck: [String] = []
    nonisolated(unsafe) private static var charlaDeck: [String] = []
    // Cada nivel de humor tiene sus propios mazos (si no, al reescribir en suave una pieza bloqueada saldria un formato picante del mazo del otro nivel).
    nonisolated(unsafe) private static var spicyMiniDeck: [String] = []
    nonisolated(unsafe) private static var spicyCharlaDeck: [String] = []
    nonisolated(unsafe) private static var darkCharlaDeck: [String] = []
    nonisolated(unsafe) private static var topicDeck: [String] = []
    nonisolated(unsafe) private static var maniaDeck: [String] = []
    nonisolated(unsafe) private static var miniHourDeck: [String] = []
    nonisolated(unsafe) private static var charlaHourDeck: [String] = []
    nonisolated(unsafe) private static var lastHourMention: Date?

    /// ¿Puede esta pieza hablar de la hora y del momento del dia? Solo de vez en cuando (pasados al menos 25 min desde la ultima vez y, aun asi, la mitad
    /// de las veces no): si no, lo dicen en todos los comentarios.
    static func reserveHourSlot() -> Bool {
        if let last = lastHourMention, Date().timeIntervalSince(last) < 25 * 60 { return false }
        guard Int.random(in: 0..<2) == 0 else { return false }
        lastHourMention = Date()
        return true
    }

    /// Al azar y SIN repetir hasta que se agotan todos.
    private static func draw(_ deck: inout [String], from all: [String]) -> String {
        if deck.isEmpty { deck = all.shuffled() }
        return deck.removeLast()
    }

    private static let foodPattern = try? NSRegularExpression(
        pattern: "comid|dieta|arroz|pollo|nevera|hambre|caf[eé]|t[aá]per|tupper|cocin|comer|comi[oó]|comiste|cena\\b|almuerz|pizza|desayun|merienda|habichuela|plato|fritur|sandwich|hamburg|paella|tortilla|croqueta|bocata",
        options: [.caseInsensitive]
    )

    private static let clockPattern = try? NSRegularExpression(
        pattern: "\\b(?:casi|sobre|pasadas?|alrededor de) las\\b|\\bson las\\b|\\bde la (?:tarde|mañana|noche|madrugada)\\b|\\bmediod[ií]a\\b|\\blas \\d{1,2}\\b|\\ba las (?:una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|once|doce)\\b",
        options: [.caseInsensitive]
    )

    /// Lo que sobra en una pieza segun lo permitido en esta ocasion (hora, nombre de la emisora); `nil` si esta bien. Solo sirve para reintentar.
    private static func styleProblem(_ text: String, allowHour: Bool, allowStation: Bool) -> String? {
        var problems: [String] = []
        if !allowHour, let clockPattern, clockPattern.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil {
            problems.append("menciona la hora o el momento del dia (en esta pieza no se habla de eso)")
        }
        if !allowStation, text.range(of: "sonar efe eme", options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            problems.append("nombra la emisora (en esta pieza no se nombra)")
        }
        let slang = RadioSlang.violations(in: text)
        if !slang.isEmpty { problems.append("usa muletillas que se han repetido demasiado (\(slang.joined(separator: ", ")))") }
        guard !problems.isEmpty else { return nil }
        return "\n\nTU INTENTO ANTERIOR " + problems.joined(separator: " y ") + ". Reescribelo sin eso y manteniendo lo demas."
    }

    private static let slangPattern = try? NSRegularExpression(pattern: "¡?\\b(?:wepa|uepa|guepa|dale fuego|dale candela)\\b[!,.]?\\s*", options: [.caseInsensitive])

    /// Quita "wepa" y parecidos (no se quieren) y deja la frase con mayuscula inicial.
    private static func stripBanned(_ line: String) -> String {
        guard let slangPattern else { return line }
        let range = NSRange(line.startIndex..., in: line)
        guard slangPattern.firstMatch(in: line, options: [], range: range) != nil else { return line }
        let result = slangPattern.stringByReplacingMatches(in: line, options: [], range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = result.first, first.isLowercase else { return result }
        return String(first).uppercased() + String(result.dropFirst())
    }

    static func mentionsFood(_ text: String) -> Bool {
        guard let foodPattern else { return false }
        return foodPattern.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - Comentarios entre canciones

    /// `spoken`: cuando se va a oir el comentario (no ahora: se escribe mientras suena la cancion anterior, unos minutos antes).
    private static func dataBlock(previous: SongItem?, next: SongItem, spoken: Date, allowHour: Bool) -> String {
        var text = ""
        if let previous {
            text += "Acaba de sonar: «\(previous.title)»\(byArtist(previous))\(songDetail(previous)).\n"
        }
        text += "A continuacion suena: «\(next.title)»\(byArtist(next))\(songDetail(next)).\n"
        if allowHour {
            let weekday = DateFormatter()
            weekday.locale = Locale(identifier: "es_ES")
            weekday.dateFormat = "EEEE"
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm"
            text += "Es \(weekday.string(from: spoken)) y son, mas o menos, las \(clock.string(from: spoken)) (hora aproximada: si la dices, di \"sobre las...\" o \"casi las...\", nunca minutos exactos).\n"
        } else {
            text += "En esta pieza NO hables de la hora, ni del momento del dia, ni del dia de la semana.\n"
        }
        return text
    }

    /// El disco y el año de una cancion, si se saben (para repasar lo que sono con datos seguros).
    private static func songDetail(_ song: SongItem) -> String {
        var parts: [String] = []
        if let album = song.album, !album.isEmpty, album.lowercased() != song.title.lowercased(),
           !album.hasSuffix("- Single"), !album.hasSuffix("- EP") {
            parts.append("disco: \(album)")
        }
        if let year = song.year, year > 1900 { parts.append("año: \(year)") }
        return parts.isEmpty ? "" : " (" + parts.joined(separator: "; ") + ")"
    }

    private static func byArtist(_ song: SongItem) -> String {
        song.artistNamesDisplay.isEmpty ? "" : " de \(song.artistNamesDisplay)"
    }

    /// Los turnos de una respuesta JSON. Solo valen los locutores (Pitirre y Chuleta) y, con `allowing`, esos oyentes por nombre; el tono solo si es de la lista.
    static func parseTurns(_ text: String, allowing guests: [String] = []) -> [RadioTurn] {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var list: [Any] = []
        if let array = object as? [Any] {
            list = array
        } else if let dictionary = object as? [String: Any], let found = dictionary.values.first(where: { $0 is [Any] }) as? [Any] {
            list = found
        }
        let allowed = Set(["Pitirre", "Chuleta"] + guests)
        var turns: [RadioTurn] = []
        for case let item as [String: Any] in list {
            let speaker = item["speaker"] as? String ?? ""
            let line = stripBanned((item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            if allowed.contains(speaker), !line.isEmpty {
                turns.append(RadioTurn(speaker: speaker, text: line, tone: RadioTone.clean(item["tono"])))
            }
        }
        return turns
    }

    /// El texto de una pieza entre dos canciones (vacio si no sale a la tercera). Cada pieza sale de un PLAN: de que va, forma de la conversacion y longitud (ver `RadioShapes`).
    /// `facts`: lo que la radio sabe de la persona (solo para las charlas; "" si la memoria esta apagada).
    /// `extras`: datos reales opcionales (de lo que suena, de tu historial, el tiempo) de los que puede usar UNO.
    /// `allowHour`: si esta pieza puede hablar de la hora y del momento del dia (ver `reserveHourSlot`).
    /// `humor`: solo para reescribir en suave una pieza que Google ha bloqueado; normalmente es el nivel elegido en Ajustes.
    static func piece(kind: RadioPieceKind, previous: SongItem?, next: SongItem, facts: String = "", extras: [String] = [], spoken: Date = Date(), allowHour: Bool = false, humor: RadioHumorLevel? = nil) async -> [RadioTurn] {
        let isMini = kind == .mini
        let level = humor ?? RadioHumor.current
        let nearby = RadioWorld.nearbyLines()
        let plan = RadioBlueprint.draw(kind: kind, hasPrevious: previous != nil, hasLocal: !nearby.isEmpty, hasFacts: !facts.isEmpty, humor: level)
        // El nombre de la emisora, solo en una de cada cuatro piezas.
        let allowStation = Int.random(in: 0..<4) == 0
        // De que va: el chiste sale de los mazos de formatos de siempre; lo demas, de su texto fijo (con su dato).
        var purpose = plan.purpose.instruction
        var topic = ""
        var mania = ""
        var zoneLine: String?
        switch plan.purpose {
        case .banter:
            if isMini {
                if allowHour {
                    purpose = draw(&miniHourDeck, from: miniHourFormats)
                } else if level == .mild {
                    purpose = draw(&miniDeck, from: miniFormats)
                } else {
                    purpose = draw(&spicyMiniDeck, from: RadioHumor.miniFormats)
                }
            } else {
                if allowHour {
                    purpose = draw(&charlaHourDeck, from: charlaHourFormats)
                } else {
                    switch level {
                    case .mild: purpose = draw(&charlaDeck, from: charlaFormats)
                    case .spicy: purpose = draw(&spicyCharlaDeck, from: RadioHumor.charlaFormats)
                    case .dark: purpose = draw(&darkCharlaDeck, from: RadioHumor.charlaFormats + RadioHumor.darkCharlaFormats)
                    }
                }
                topic = draw(&topicDeck, from: topics)
                mania = draw(&maniaDeck, from: manias)
            }
        case .local:
            zoneLine = nearby.randomElement()
        default:
            break
        }
        let system = fichaWith(humor: level) + "\n\n" + rules(for: level) + RadioHumor.rulesNote(level)
        var notice = ""
        var best: [RadioTurn] = []
        var bestTopic: String?
        // Si ningun intento cumple la longitud, se usa el mas cercano (recortado) antes que dejar el paso sin voz.
        var lengthFallback: [RadioTurn] = []
        var fallbackTopic: String?
        for attempt in 0..<3 {
            var prompt = "Escribe la PIEZA que suena entre dos canciones.\n"
            prompt += dataBlock(previous: previous, next: next, spoken: spoken, allowHour: allowHour)
            prompt += allowStation ? "Puedes nombrar la emisora UNA vez, solo si cabe natural.\n" : "En esta pieza NO nombres la emisora.\n"
            prompt += "PLAN DE ESTA PIEZA (respetalo):\n- DE QUE VA: \(purpose)\n- FORMA: \(plan.shape.instruction)\n- LONGITUD: \(plan.length.instruction)\n"
            if !topic.isEmpty { prompt += "TEMA DE ESTA VEZ (opcional): \(topic).\n" }
            if !mania.isEmpty { prompt += "MANIA DE ESTA VEZ (opcional, solo si cabe natural; no la fuerces): \(mania).\n" }
            if let zoneLine { prompt += "DATO DE LA ZONA (usa SOLO este dato, tal cual, sin inventar nada mas): \(zoneLine)\n" }
            prompt += "Recuerda: solo conoces esos datos; no inventes nada mas sobre las canciones ni los artistas."
            if !extras.isEmpty {
                prompt += "\n\nDATOS REALES EXTRA (usa UNO solo, tal cual, y solo si cabe natural):\n" + extras.map { "- " + $0 }.joined(separator: "\n")
            }
            if !facts.isEmpty { prompt += "\n\n" + facts }
            prompt += RadioHistory.promptBlock(count: 6) + RadioNotebook.promptBlock() + notice
            let json: String
            do {
                json = try await Gemini.text(system: system, prompt: prompt, temperature: 1.2, timeout: 10)
            } catch let failure as Gemini.Failure where failure.isBlocked && level != .mild {
                // Google se ha negado: la pieza se vuelve a escribir en suave (con su propio plan), para no quedarse sin ella.
                PlaybackReport.record("radio: pieza bloqueada por Google con humor \(RadioHumor.name(level)); se reescribe en suave")
                return await piece(kind: kind, previous: previous, next: next, facts: facts, extras: extras, spoken: spoken, allowHour: allowHour, humor: .mild)
            } catch {
                break
            }
            let turns = parseTurns(json)
            let words = turns.reduce(0) { $0 + $1.text.split(separator: " ").count }
            let all = turns.map(\.text).joined(separator: " ")
            if let problem = plan.length.problem(words: words, lines: turns.count) {
                if !turns.isEmpty, !mentionsFood(all) {
                    lengthFallback = turns
                    fallbackTopic = parseTopic(json)
                }
                notice = "\n\nTU INTENTO ANTERIOR " + problem
                continue
            }
            if mentionsFood(all) {
                notice = "\n\nTU INTENTO ANTERIOR HABLABA DE COMIDA. Reescribelo desde cero sin mencionar nada de comer, beber ni cocina."
                best = []
                bestTopic = nil
                continue
            }
            // La forma, la hora, la emisora y las muletillas se comprueban "suave": se reintenta y, al ultimo intento, sale igual.
            let shapeProblem = plan.shape.problem(in: turns)
            let styleNotice = styleProblem(all, allowHour: allowHour, allowStation: allowStation)
            if attempt < 2, shapeProblem != nil || styleNotice != nil {
                best = turns  // si los reintentos fallan por otra cosa, esta vale
                bestTopic = parseTopic(json)
                notice = (styleNotice ?? "") + (shapeProblem.map { "\n\nLA FORMA NO SE CUMPLE: " + $0 + "." } ?? "")
                continue
            }
            best = turns
            bestTopic = parseTopic(json)
            break
        }
        if best.isEmpty, !lengthFallback.isEmpty {
            best = plan.length.trimmed(lengthFallback)
            bestTopic = fallbackTopic
        }
        if !best.isEmpty {
            RadioHistory.add(best)
            if let bestTopic { RadioNotebook.add(bestTopic) }
        }
        return best
    }

    /// El campo "tema" de la respuesta de una pieza (de que ha ido), para el cuaderno del programa.
    static func parseTopic(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let topic = (object["tema"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty else { return nil }
        return String(topic.prefix(80))
    }

    /// Una frase corta para recordar de una charla (algo que quedo pendiente o un gag), para retomarla otro dia. Vacia si no sale.
    static func recallNote(for turns: [RadioTurn]) async -> String {
        let text = turns.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        let system = "Resumes una charla de radio para que los locutores la recuerden otro dia. Devuelve SOLO un JSON {\"nota\": \"...\"} con UNA frase de maximo 14 palabras: lo que quedo pendiente o el gag, solo lo que se dijo en la charla; sin inventar nada."
        guard let json = try? await Gemini.text(system: system, prompt: text, temperature: 0.3, timeout: 8),
              let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let note = object["nota"] as? String else { return "" }
        return note
    }

    // MARK: - Frases fijas (se generan una vez y se guardan)

    /// La pregunta con la que empieza la radio (varias, para que no suene siempre igual).
    static let questions: [[RadioTurn]] = [
        [RadioTurn(speaker: "Pitirre", text: "¡Sónar efe eme en el aire! Dime, nene, ¿qué te ponemos hoy?"),
         RadioTurn(speaker: "Chuleta", text: "Y no digas lo que sea, eh. Que aquí se viene a pedir.")],
        [RadioTurn(speaker: "Chuleta", text: "¡Buenas! Bienvenido a la radio. ¿Qué quieres escuchar?"),
         RadioTurn(speaker: "Pitirre", text: "Tú mandas, nosotros ponemos los discos.")],
        [RadioTurn(speaker: "Pitirre", text: "Sónar efe eme, a tu servicio. ¿Qué se te antoja hoy?"),
         RadioTurn(speaker: "Chuleta", text: "Dinos un estilo, una época, un artista... y a darle.")],
        [RadioTurn(speaker: "Chuleta", text: "Mira quién llegó. ¿Qué vamos a poner, jefe?"),
         RadioTurn(speaker: "Pitirre", text: "Pide sin miedo, que la casa invita.")]
    ]

    /// Mientras se prepara la respuesta.
    static let fillers: [RadioTurn] = [
        RadioTurn(speaker: "Pitirre", text: "Dame un segundito, que miro en el cajón de los discos."),
        RadioTurn(speaker: "Chuleta", text: "Espérate, que ya lo busco."),
        RadioTurn(speaker: "Pitirre", text: "Uy, buena petición. Ahorita te lo pongo.")
    ]

    /// Una pregunta ya guardada; si no hay ninguna, se genera la primera ahora (la unica vez que hay que esperar).
    static func question() async -> RadioClip? {
        let order = questions.shuffled()
        for turns in order {
            if let cached = RadioVoice.cachedClip(turns, fixed: true) { return cached }
        }
        return await RadioVoice.clip(order[0], fixed: true, timeout: 12)
    }

    static func cachedFiller() -> RadioClip? {
        for filler in fillers.shuffled() {
            if let cached = RadioVoice.cachedClip([filler], fixed: true) { return cached }
        }
        return nil
    }

    /// Deja guardadas las frases fijas (con una pausa entre peticiones para no pasarse del limite por minuto). Devuelve cuantas ha generado.
    static func prewarm() async -> Int {
        var items: [(turns: [RadioTurn], style: String?)] = []
        for question in questions { items.append((turns: question, style: nil)) }
        for filler in fillers { items.append((turns: [filler], style: nil)) }
        var made = 0
        for item in items {
            if RadioVoice.cachedClip(item.turns, style: item.style, fixed: true) != nil { continue }
            try? await Task.sleep(nanoseconds: 6_500_000_000)
            if await RadioVoice.clip(item.turns, style: item.style, fixed: true) != nil { made += 1 }
        }
        return made
    }
}
