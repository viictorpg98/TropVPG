//
//  RadioSections.swift
//  Trop
//
//  Las SECCIONES de la radio (noticiero loco, el tiempo, anuncio parodia, lo mas buscado, tus 5 de la semana, un dia como hoy y los mensajes de oyentes):
//  mas largas que una charla y con su propia musiquita. Se emiten como un CORTE (la cancion se funde, suena la sintonia, la voz grita el nombre de la seccion,
//  hablan los locutores, cuña de salida y la siguiente cancion empieza desde cero), asi que no se comen ninguna cancion. Los textos salen de datos REALES
//  (titulares, tendencias, el tiempo, la Wikipedia, tu historial de escuchas): son la UNICA fuente de hechos y el modelo no puede añadir nada. La excepcion son
//  los mensajes de oyentes: son ficcion evidente (oyentes inventados). Probado antes en el PC (speechify-prueba\radio-parodia.py, voces-invitados.py).
//

import Foundation

struct RadioSectionAssets {
    let kind: RadioSectionKind
    let turns: [RadioTurn]
    let voice: RadioClip
    let shout: RadioClip?
    let bed: URL?
    let outro: RadioClip?
    /// La nota de voz del oyente (solo en los mensajes de oyentes) y el aviso de mensaje que suena al empezar y antes de ella.
    var note: RadioClip? = nil
    var noteTurns: [RadioTurn] = []
}

enum RadioSections {
    private static let realRules = """
    REGLAS CON DATOS REALES (muy importantes):
    - Los DATOS de abajo son la UNICA fuente de hechos reales. No añadas hechos, cifras, citas, lugares ni nombres que no esten en ellos.
    - No atribuyas frases ni acciones inventadas a personas con nombre. El humor va sobre la situacion, lo absurdo o la reaccion de los locutores; no inventa que alguien haya dicho o hecho algo.
    - Sin insultos a personas. Si toca politica, trato equilibrado: se pica a todos por igual o al circo de la campaña, sin favorecer ni atacar a un partido.
    - Nada de bromas con muertes, accidentes, violencia ni victimas: si un dato es asi, usa otro.
    - Si nombras la emisora, escribe su nombre como "Sónar efe eme" (no hace falta nombrarla en cada frase). Si no estas seguro de algo, no lo digas.
    - Suena a gente real hablando: frases cortas (maximo 18 palabras), alguna duda o muletilla leve. Sin descripciones entre parentesis; para una risa usa la etiqueta <laugh> (maximo dos).
    - Lo que dicen suena natural, como en una conversacion de verdad (reaccionan a lo que dice el otro, no recitan), con el tono de dos locutores de radio, el mas natural en cada momento. La jerga puertorriqueña es un condimento escaso: como mucho una expresion en toda la seccion, nunca la misma que en piezas anteriores y nunca para cerrar. Prohibido decir "wepa".
    - Cada linea puede llevar un campo opcional "tono" con UNO de estos valores: \(RadioTone.names). Pon el tono con el que la diria un locutor de radio en ese momento, el mas natural (si el de siempre del personaje encaja, omite el campo); susurro, grito e incredulo solo cuando el contenido lo pida de verdad.
    - Responde SOLO con un JSON, sin texto antes ni despues: una lista de objetos {"speaker": "Pitirre" o "Chuleta", "text": "...", "tono": "..." (opcional)}.
    """

    /// Reglas de los mensajes de oyentes: aqui TODO es ficcion evidente, asi que no rige "solo datos reales", pero si no inventar nada de la cancion.
    private static var listenerRules: String { listenerBase.replacingOccurrences(of: "{PUEBLOS}", with: RadioLocal.townsText) }

    private static let listenerBase = """
    REGLAS (MENSAJES DE OYENTES: todo es ficcion evidente):
    - Los oyentes y sus mensajes son INVENTADOS: nombres de pila normales y pueblos y barrios de la zona de la emisora ({PUEBLOS}), nunca famosos ni personas reales. Peticiones y saludos cotidianos, cariñosos y creibles (un cumpleaños, un dia duro, una apuesta entre amigos...).
    - De la cancion SOLO conoces el titulo y el artista que se te dan: no inventes nada mas sobre ellos.
    - Nada de comida, bebida ni cocina. Sin insultos, politica ni marcas comerciales. Sin descripciones entre parentesis; para una risa usa <laugh> (maximo dos).
    - Si nombras la emisora, escribe su nombre como "Sónar efe eme". Frases cortas (maximo 18 palabras).
    - Lo que dicen suena natural, como en una conversacion de verdad, con el tono de dos locutores de radio. La jerga puertorriqueña casi nunca, y nunca para cerrar. Prohibido decir "wepa".
    - Cada linea puede llevar un campo opcional "tono" con UNO de estos valores: \(RadioTone.names). Pon el tono mas natural para ese momento (el oyente de la nota de voz, sin tono: habla como un oyente normal); si el de siempre encaja, omite el campo; susurro, grito e incredulo solo cuando el contenido lo pida de verdad.
    - Responde SOLO con un JSON, sin texto antes ni despues: una lista de objetos {"speaker": "Pitirre" o "Chuleta" o el nombre del oyente, "text": "...", "tono": "..." (opcional)}.
    """

    private struct Spec {
        let instruction: String
        let data: String
        let minWords: Int
        let maxWords: Int
        let minTurns: Int
        /// Para los mensajes de oyentes: el oyente cuya nota de voz se escribe y sus limites de palabras.
        var guest: RadioGuest? = nil
        var rules: String = RadioSections.realRules
    }

    private static func numbered(_ list: [String]) -> String {
        list.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    private static func byArtist(_ song: SongItem) -> String {
        song.artistNamesDisplay.isEmpty ? "" : " de \(song.artistNamesDisplay)"
    }

    /// Lo que pide cada seccion y con que datos; `nil` si no hay datos suficientes para esa seccion.
    private static func spec(for kind: RadioSectionKind, world: RadioWorldData?, top: [String]?, next: SongItem?, guest: RadioGuest?) -> Spec? {
        switch kind {
        case .noticiero:
            guard let world, world.headlines.count >= 6 else { return nil }
            // Los titulares locales (marcados "[Local: ciudad]") siempre entran: la emisora es de alli.
            let local = world.headlines.filter { $0.hasPrefix("[Local") }
            let national = world.headlines.filter { !$0.hasPrefix("[Local") }
            let pool = Array(local.shuffled().prefix(3)) + Array(national.shuffled().prefix(11))
            return Spec(
                instruction: "Haz un NOTICIERO LOCO de unos 35 a 45 segundos: los dos locutores comentan 3 de estos titulares (los mas graciosos o absurdos), con humor y picandose entre si. Si hay titulares marcados [Local: ciudad], comenta al menos uno como vecinos de esa ciudad (pueden venir en catalan: cuentalos en español con naturalidad, sin inventar nada). Cita cada titular de forma natural, sin leerlo entero. Cierra devolviendo a la musica.",
                data: numbered(pool.shuffled()), minWords: 75, maxWords: 130, minTurns: 6
            )
        case .tiempo:
            guard let weather = world?.weather else { return nil }
            let text = "\(weather.city) ahora: \(Int(weather.now.rounded())) grados, \(weather.text). Hoy: maxima \(Int(weather.max.rounded())), minima \(Int(weather.min.rounded())), probabilidad de lluvia \(weather.rain)%."
            return Spec(
                instruction: "Haz la seccion del TIEMPO de unos 15 a 20 segundos con el tiempo de hoy en \(weather.city), con humor y mirando el clima con ojos de puertorriqueño. Cierra devolviendo a la musica.",
                data: text, minWords: 35, maxWords: 65, minTurns: 3
            )
        case .anuncios:
            guard let world else { return nil }
            let base = Array(world.headlines.shuffled().prefix(6)) + world.trends.shuffled().prefix(6).map { "[Tendencia] \($0)" }
            guard base.count >= 4 else { return nil }
            return Spec(
                instruction: "Haz un ANUNCIO PARODIA de radio de unos 25 a 30 segundos: una marca o cadena REAL muy conocida en España pero con el NOMBRE ALTERADO (cambia letras o juega con el nombre) de modo que se reconozca claramente a quien parodia; un producto o servicio absurdo ligado a una de estas noticias o tendencias de hoy. No afirmes nada real malo de la empresa (nada de fraudes, defectos ni escandalos): es absurdo evidente. Acaba con un eslogan y devuelve a la musica.",
                data: numbered(base), minWords: 55, maxWords: 100, minTurns: 4
            )
        case .top5:
            guard let top, top.count >= 3 else { return nil }
            return Spec(
                instruction: "Haz MIS 5 DE LA SEMANA de unos 25 a 35 segundos: una cuenta atras de lo que esta persona MAS ha escuchado esta semana en su movil (los DATOS de abajo, ya ordenados del puesto 1 al \(top.count): empieza por el ultimo y acaba en el puesto 1). Comenta cada puesto en una frase, diciendo titulo y artista, y vacilala con cariño por las veces que la ha puesto. No inventes nada mas sobre las canciones ni sobre la persona. Cierra devolviendo a la musica.",
                data: top.joined(separator: "\n"), minWords: 55, maxWords: 115, minTurns: 5
            )
        case .hoy:
            guard let world else { return nil }
            let events = RadioWorld.onThisDayToday(world)
            guard events.count >= 4 else { return nil }
            return Spec(
                instruction: "Haz UN DIA COMO HOY de unos 20 a 25 segundos: los locutores comentan 2 de estos hechos que ocurrieron un dia como hoy (di el año tal cual viene), con curiosidad y humor suave, sin inventar ni causas, ni consecuencias, ni personas, ni detalles que no esten en el dato. Cierra devolviendo a la musica.",
                data: numbered(Array(events.shuffled().prefix(6))), minWords: 45, maxWords: 90, minTurns: 3
            )
        case .deportes:
            guard let sports = world?.sports, sports.count >= 6 else { return nil }
            let favorites = RadioSettings.sportsTopics.joined(separator: ", ")
            return Spec(
                instruction: "Haz EL RINCON DEPORTIVO de unos 25 a 35 segundos: los locutores comentan 3 de estos titulares de deporte de hoy (los mas importantes o graciosos), con humor de vestuario y picandose entre si. Mezcla deporte y LaLiga en general con, como mucho, UN titular de los temas favoritos del oyente (los marcados 'Tu tema'; sus temas son: \(favorites)) y solo si de verdad es destacado (un resultado, un partido importante, una polemica); si no lo es, no lo metas. La Chuleta comparte los gustos del oyente (si entre sus temas hay un equipo, es de ese equipo) y El Pitirre la pica con cariño siendo de un equipo rival cualquiera. Las lineas marcadas 'Dato LaLiga' son datos exactos (clasificacion y, del equipo del oyente, su posicion, su ultimo partido y el proximo): usalos con naturalidad si encajan (por ejemplo, su posicion o con quien juega a continuacion), tal cual. Cita marcadores y datos solo tal cual vienen. Nada de burlas personales a jugadores ni arbitros con nombre, nada de lesiones, desgracias ni apuestas. Cierra devolviendo a la musica.",
                data: numbered(sports.shuffled()), minWords: 60, maxWords: 120, minTurns: 5
            )
        case .whatsapp:
            guard let guest, let next else { return nil }
            return Spec(
                instruction: "Haz los MENSAJES DE OYENTES de unos 30 a 40 segundos (el WhatsApp de la emisora). Primero, los dos locutores leen 1 o 2 mensajes de texto de oyentes inventados (nombre de pila y pueblo; piden una cancion o mandan un saludo) y comentan con naturalidad; despues anuncian una NOTA DE VOZ de \(guest.profile) y ahi acaban sus lineas (no hablan despues de anunciarla). Despues escribe la NOTA DE VOZ como lineas con speaker \"\(guest.name)\": de 15 a 45 palabras en total, se presenta con su nombre y su pueblo y pide o dedica la cancion de abajo a alguien de su vida (un nombre de pila inventado), como hablandole a su movil, con naturalidad y sin leer un guion.",
                data: "La cancion que suena a continuacion (la de la nota de voz): «\(next.title)»\(byArtist(next)).",
                minWords: 45, maxWords: 95, minTurns: 3, guest: guest, rules: listenerRules
            )
        }
    }

    /// Las formas de conversacion que van con cada seccion (un anuncio puede ser un solo locutor; un noticiero, no).
    private static func allowedShapes(for kind: RadioSectionKind) -> [RadioShape] {
        switch kind {
        case .noticiero: return [.duo, .listens, .interrupt, .agree]
        case .tiempo: return [.solo, .listens, .duo, .agree]
        case .anuncios: return [.solo, .duo, .interrupt]
        case .top5: return [.solo, .duo, .listens]
        case .hoy: return [.solo, .listens, .agree, .duo]
        case .whatsapp: return [.duo, .agree, .interrupt]
        case .deportes: return [.duo, .listens, .interrupt, .agree]
        }
    }

    /// Prepara todo lo de una seccion: el texto, la voz (varios segundos de audio), el grito de entrada, la musiquita y la cuña de salida. `nil` si falta
    /// lo imprescindible (datos, texto o voz); sin musiquita o cuña, la seccion sale igual. `next` es la cancion que viene (para los mensajes de oyentes).
    static func make(kind: RadioSectionKind, next: SongItem? = nil) async -> RadioSectionAssets? {
        let world = await RadioWorld.snapshot()
        var top: [String]?
        // Tu top 5 sale de tu historial: va con "La radio recuerda" (con la memoria apagada, esta seccion se salta).
        if kind == .top5, RadioSettings.memoryEnabled { top = await RadioSongFacts.weeklyTop() }
        let guest = kind == .whatsapp ? RadioGuests.all.randomElement() : nil
        guard let spec = spec(for: kind, world: world, top: top, next: next, guest: guest) else { return nil }
        var notice = ""
        var hostTurns: [RadioTurn] = []
        var noteTurns: [RadioTurn] = []
        var fallbackHosts: [RadioTurn] = []
        var fallbackNote: [RadioTurn] = []
        // La forma de la conversacion (como en las piezas entre canciones): no siempre "habla uno, habla el otro".
        let shape = RadioBlueprint.drawShape(from: allowedShapes(for: kind))
        let minLines = (shape == .solo ? min(spec.minTurns, 2) : spec.minTurns) - (spec.guest == nil ? 0 : 1)
        for attempt in 0..<2 {
            let prompt = spec.instruction + "\n\nFORMA DE LA CONVERSACION (respetala): \(shape.instruction)" + "\n\nDATOS \(spec.guest == nil ? "REALES " : "")DE HOY (unica fuente de hechos):\n" + spec.data
                + RadioHistory.promptBlock(count: 3) + notice
            guard let json = try? await Gemini.text(
                system: RadioContent.ficha + "\n\n" + spec.rules, prompt: prompt, temperature: 1.1, timeout: 14
            ) else { break }
            let turns = RadioContent.parseTurns(json, allowing: spec.guest.map { [$0.name] } ?? [])
            let hosts = turns.filter { $0.speaker == "Pitirre" || $0.speaker == "Chuleta" }
            let note = turns.filter { $0.speaker != "Pitirre" && $0.speaker != "Chuleta" }
            let words = hosts.reduce(0) { $0 + $1.text.split(separator: " ").count }
            let noteWords = note.reduce(0) { $0 + $1.text.split(separator: " ").count }
            let noteOK = spec.guest == nil ? note.isEmpty : (noteWords >= 12 && noteWords <= 60)
            let allText = turns.map(\.text).joined(separator: " ")
            let foodHit = RadioContent.mentionsFood(allText)
            let slangHit = RadioSlang.violations(in: allText)
            let structureOK = hosts.count >= minLines && words >= spec.minWords - (spec.guest == nil ? 0 : 20)
                && words <= spec.maxWords && noteOK
            // Comida y muletillas repetidas: suave (un reintento y, si sigue, sale igual, para no quedarse sin seccion).
            let shapeProblem = shape.problem(in: hosts)
            if structureOK, (!foodHit && slangHit.isEmpty && shapeProblem == nil) || attempt == 1 {
                hostTurns = hosts
                noteTurns = note
                break
            }
            if structureOK {
                fallbackHosts = hosts
                fallbackNote = note
                if foodHit {
                    notice = "\n\nTU INTENTO ANTERIOR HABLABA DE COMIDA. Reescribelo desde cero sin mencionar nada de comer, beber ni cocina."
                } else if !slangHit.isEmpty {
                    notice = "\n\nTU INTENTO ANTERIOR USABA MULETILLAS QUE SE HAN REPETIDO DEMASIADO (\(slangHit.joined(separator: ", "))). Reescribelo sin ellas."
                } else {
                    notice = "\n\nLA FORMA NO SE CUMPLE: " + (shapeProblem ?? "") + ". Reescribelo respetandola."
                }
            } else {
                notice = "\n\nTU INTENTO ANTERIOR NO SIRVE (\(words) palabras de los locutores en \(hosts.count) lineas\(spec.guest == nil ? "" : ", \(noteWords) palabras en la nota de voz")). Los locutores: entre \(spec.minWords) y \(spec.maxWords) palabras" + (spec.guest == nil ? " en al menos \(spec.minTurns) lineas." : "; la nota de voz de \(spec.guest?.name ?? ""): entre 15 y 45 palabras.")
            }
        }
        if hostTurns.isEmpty, !fallbackHosts.isEmpty {
            hostTurns = fallbackHosts
            noteTurns = fallbackNote
        }
        guard !hostTurns.isEmpty else { return nil }
        // El grito de entrada se escribe y se dice NUEVO cada vez, a la vez que el resto (si no sale, la seccion entra solo con su musiquita).
        let shoutTask = Task { await RadioIdent.make(.section(kind)) }
        var note: RadioClip?
        if spec.guest != nil {
            // La nota de voz va PRIMERO: es lo mas arriesgado (otra voz) y sin ella la seccion no tiene sentido (los locutores ya la habrian anunciado); asi,
            // si falla, no se gasta la peticion de voz de los locutores.
            guard !noteTurns.isEmpty, let made = await RadioVoice.clip(noteTurns, timeout: 25) else { return nil }
            note = made
        }
        guard let voice = await RadioVoice.clip(hostTurns, timeout: 30) else { return nil }
        RadioHistory.add(hostTurns + noteTurns)
        RadioNotebook.add("la seccion de \(kind.name)")
        var assets = RadioSectionAssets(
            kind: kind, turns: hostTurns, voice: voice, shout: await shoutTask.value, bed: RadioSounds.bed(for: kind), outro: nil
        )
        assets.note = note
        assets.noteTurns = noteTurns
        return assets
    }
}
