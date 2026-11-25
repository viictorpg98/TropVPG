//
//  RadioIdent.swift
//  Trop
//
//  Los GRITOS de la radio ("¡Un día como hoy!", la cuña con la que vuelven las charlas): se escriben y se dicen NUEVOS cada vez (texto de Gemini, voz gritada de los
//  locutores) y suenan sobre la musica de Lyria que ya hay en la app, que baja cuando hablan y sube en las pausas. Nada de esto es fijo: no hay dos iguales seguidos.
//

import Foundation

enum RadioIdent {
    enum Target {
        case section(RadioSectionKind)
        case charla
    }

    private static let historyKey = "radio.shouts.v1"

    /// Que se anuncia y ejemplos del tono (no se copian: solo orientan).
    private static func brief(for target: Target) -> (what: String, examples: [String]) {
        switch target {
        case .charla:
            return ("la vuelta de una pausa: los locutores se ponen a charlar entre dos canciones",
                    ["¡Sónar efe eme, aquí seguimos!", "¡Sónar efe eme, y que no pare la fiesta!", "Sónar efe eme, la radio con dos locos al micrófono."])
        case .section(let kind):
            switch kind {
            case .noticiero:
                return ("el noticiero de la emisora (los titulares de hoy, con humor)",
                        ["¡Paren las prensas, que Sónar efe eme tiene noticias!", "¡Última hora, señores! ¡El noticiero de Sónar efe eme!", "¡Noticiero! / ¡En Sónar efe eme!"])
            case .tiempo:
                return ("la seccion del tiempo", ["¡Saquen el paraguas o las chanclas! ¡El tiempo en Sónar efe eme!", "¡Y ahora, lo que dicen las nubes!", "¿Qué tiempo hace? / ¡El tiempo, en Sónar efe eme!"])
            case .anuncios:
                return ("la pausa publicitaria (anuncios parodia)", ["¡Pausa publicitaria! ¡Sujétense la cartera!", "¡Publicidad! / ¡Que alguien tiene que pagar la luz!", "¡Y ahora, unos anunciantes que no existen... pero casi!"])
            case .top5:
                return ("las cinco canciones que la persona mas ha escuchado esta semana", ["¡Tus cinco de la semana! ¡Los que no has soltado!", "¡Cuenta atrás! ¡Tus cinco favoritos de la semana!", "¡Cinco! / ¡Tus cinco de la semana, en Sónar efe eme!"])
            case .hoy:
                return ("'un dia como hoy': hechos de otros años ocurridos en la fecha de hoy", ["¡Un día como hoy, hace un montón de años!", "¡Abre la máquina del tiempo! ¡Un día como hoy!", "¿Qué pasó un día como hoy? / ¡Pues escucha!"])
            case .deportes:
                return ("el rincon deportivo (los titulares del deporte de hoy)",
                        ["¡Se calienta el vestuario! ¡El rincón deportivo!", "¡Árbitro, pita ya! ¡Deportes en Sónar efe eme!", "¿Quién ganó? / ¡Toca el rincón deportivo!"])
            case .whatsapp:
                return ("los mensajes de los oyentes al WhatsApp (inventado) de la emisora", ["¡Mensajes! ¡Que explota el WhatsApp de Sónar efe eme!", "¡Ya llegaron los mensajes de ustedes, los oyentes!", "¿Quién nos escribe? / ¡El WhatsApp de Sónar efe eme!"])
            }
        }
    }

    private static let rules = """
    REGLAS (GRITO DE EMISORA): es lo que dicen los locutores con energia para ANUNCIAR algo, como en una radio de verdad.
    - Tiene que ANUNCIAR de verdad lo que viene (la seccion por su nombre, o que vuelven a charlar): que quien lo oiga sepa que empieza. Como mucho, un remate corto con gracia.
    - Sin insultos, sin tacos y sin burlas al oyente: es un anuncio de emisora, no una pulla. Nada de frases sueltas sin sentido.
    - UNA o DOS lineas muy cortas, MAXIMO 14 palabras en total: un locutor solo, o los dos en pregunta y respuesta.
    - Original, con personalidad y un punto de humor. Evita lo tipico: nada de "atencion, atencion", "wepa", "uepa", "damas y caballeros" ni exclamaciones genericas.
    - A veces (no siempre) nombra la emisora, escrita como "Sónar efe eme".
    - Nada de comida, bebida ni cocina. No inventes datos. Sin descripciones entre parentesis.
    - Responde SOLO con un JSON, sin texto antes ni despues: una lista de objetos {"speaker": "Pitirre" o "Chuleta", "text": "..."}.
    """

    private static func recent() -> [String] {
        UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    private static func remember(_ text: String) {
        var list = recent()
        list.append(text)
        UserDefaults.standard.set(Array(list.suffix(16)), forKey: historyKey)
    }

    /// Un grito NUEVO (texto de Gemini y voz gritada), o `nil` si no sale a tiempo (la radio sigue sin el). Gasta una peticion de voz.
    static func make(_ target: Target) async -> RadioClip? {
        let info = brief(for: target)
        var notice = ""
        var chosen: [RadioTurn] = []
        for _ in 0..<2 {
            var prompt = "Escribe el grito para anunciar: \(info.what).\nEjemplos del tono (NO los copies ni los imites: inventa otro distinto):\n"
            prompt += info.examples.map { "- " + $0 }.joined(separator: "\n")
            let used = recent()
            if !used.isEmpty { prompt += "\n\nGRITOS YA USADOS (no repitas ni su idea ni sus palabras):\n" + used.suffix(10).map { "- " + $0 }.joined(separator: "\n") }
            prompt += notice
            let json: String
            do {
                json = try await Gemini.text(system: RadioContent.fichaWith(humor: .mild) + "\n\n" + rules, prompt: prompt, temperature: 1.1, timeout: 8)
            } catch {
                PlaybackReport.record("radio: grito: no se pudo escribir (\(error.localizedDescription))")
                return nil
            }
            let turns = RadioContent.parseTurns(json)
            let words = turns.reduce(0) { $0 + $1.text.split(separator: " ").count }
            let all = turns.map(\.text).joined(separator: " ")
            if (1...2).contains(turns.count), (2...18).contains(words), !RadioContent.mentionsFood(all) {
                chosen = turns
                break
            }
            notice = "\n\nTU INTENTO ANTERIOR NO SIRVE (debe ser 1 o 2 lineas, entre 3 y 14 palabras, sin comida). Escribelo de nuevo."
        }
        guard !chosen.isEmpty else {
            PlaybackReport.record("radio: grito: el texto no valia tras 2 intentos (1-2 lineas, 3 a 18 palabras, sin comida)")
            return nil
        }
        let shouted = chosen.map { RadioTurn(speaker: $0.speaker, text: $0.text, tone: "grito") }
        let speakers = Set(shouted.map(\.speaker))
        // Un locutor: estilo de locutor de emisora; dos (duo): el tono "grito" de cada frase.
        guard var clip = await RadioVoice.clip(shouted, style: speakers.count == 1 ? Gemini.announcerStyle : nil, timeout: 12) else { return nil }
        let said = shouted.map(\.text).joined(separator: " / ")
        remember(said)
        clip.label = said
        return clip
    }
}
