//
//  RadioSections.swift
//  Trop
//
//  Las SECCIONES de la radio (noticiero loco, el tiempo, anuncio parodia, lo mas buscado): mas largas que una charla y con su propia musiquita. Se emiten
//  como un CORTE (la cancion se funde, suena la sintonia, la voz grita el nombre de la seccion, hablan los locutores, cuña de salida y la siguiente cancion
//  empieza desde cero), asi que no se comen ninguna cancion. Los textos salen de datos REALES de hoy (titulares, tendencias, el tiempo): son la UNICA
//  fuente de hechos y el modelo no puede añadir nada. Probado antes en el PC (speechify-prueba\radio-parodia.py).
//

import Foundation

struct RadioSectionAssets {
    let kind: RadioSectionKind
    let turns: [RadioTurn]
    let voice: RadioClip
    let shout: RadioClip?
    let bed: URL?
    let outro: RadioClip?
}

enum RadioSections {
    private static let realRules = """
    REGLAS CON DATOS REALES (muy importantes):
    - Los DATOS de abajo son la UNICA fuente de hechos reales. No añadas hechos, cifras, citas, lugares ni nombres que no esten en ellos.
    - No atribuyas frases ni acciones inventadas a personas con nombre. El humor va sobre la situacion, lo absurdo o la reaccion de los locutores; no inventa que alguien haya dicho o hecho algo.
    - Sin insultos a personas. Si toca politica, trato equilibrado: se pica a todos por igual o al circo de la campaña, sin favorecer ni atacar a un partido.
    - Nada de bromas con muertes, accidentes, violencia ni victimas: si un dato es asi, usa otro.
    - Escribe siempre el nombre de la emisora como "Sónar efe eme". Si no estas seguro de algo, no lo digas.
    - Suena a gente real hablando: frases cortas (maximo 18 palabras), alguna duda o muletilla leve. Sin descripciones entre parentesis; para una risa usa la etiqueta <laugh> (maximo dos).
    - Responde SOLO con un JSON, sin texto antes ni despues: una lista de objetos {"speaker": "Pitirre" o "Chuleta", "text": "..."}.
    """

    /// Lo que grita la voz sobre la sintonia al empezar cada seccion (dos variantes; se guardan una vez).
    static let shouts: [RadioSectionKind: [RadioTurn]] = [
        .noticiero: [RadioTurn(speaker: "Pitirre", text: "¡El noticiero de Sónar efe eme!"),
                     RadioTurn(speaker: "Chuleta", text: "¡Atención, atención! ¡Noticiero Sónar!")],
        .tiempo: [RadioTurn(speaker: "Chuleta", text: "¡Y ahora, el tiempo!"),
                  RadioTurn(speaker: "Pitirre", text: "¡Hora del tiempo en Sónar efe eme!")],
        .anuncios: [RadioTurn(speaker: "Chuleta", text: "¡La publicidad de Sónar efe eme!"),
                    RadioTurn(speaker: "Pitirre", text: "¡Pausa para los anunciantes!")],
        .tendencias: [RadioTurn(speaker: "Pitirre", text: "¡Lo más buscado!"),
                      RadioTurn(speaker: "Chuleta", text: "¡Tendencias en Sónar efe eme!")]
    ]

    private struct Spec {
        let instruction: String
        let data: String
        let minWords: Int
        let maxWords: Int
        let minTurns: Int
    }

    private static func numbered(_ list: [String]) -> String {
        list.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// Lo que pide cada seccion y con que datos; `nil` si no hay datos suficientes para esa seccion.
    private static func spec(for kind: RadioSectionKind, world: RadioWorldData) -> Spec? {
        switch kind {
        case .noticiero:
            guard world.headlines.count >= 6 else { return nil }
            return Spec(
                instruction: "Haz un NOTICIERO LOCO de unos 35 a 45 segundos: los dos locutores comentan 3 de estos titulares (los mas graciosos o absurdos), con humor y picandose entre si. Cita cada titular de forma natural, sin leerlo entero. Cierra devolviendo a la musica.",
                data: numbered(Array(world.headlines.shuffled().prefix(14))), minWords: 75, maxWords: 130, minTurns: 6
            )
        case .tiempo:
            guard let weather = world.weather else { return nil }
            let text = "\(weather.city) ahora: \(Int(weather.now.rounded())) grados, \(weather.text). Hoy: maxima \(Int(weather.max.rounded())), minima \(Int(weather.min.rounded())), probabilidad de lluvia \(weather.rain)%."
            return Spec(
                instruction: "Haz la seccion del TIEMPO de unos 15 a 20 segundos con el tiempo de hoy en \(weather.city), con humor y mirando el clima con ojos de puertorriqueño. Cierra devolviendo a la musica.",
                data: text, minWords: 35, maxWords: 65, minTurns: 3
            )
        case .anuncios:
            let base = Array(world.headlines.shuffled().prefix(6)) + world.trends.shuffled().prefix(6).map { "[Tendencia] \($0)" }
            guard base.count >= 4 else { return nil }
            return Spec(
                instruction: "Haz un ANUNCIO PARODIA de radio de unos 25 a 30 segundos: una marca o cadena REAL muy conocida en España pero con el NOMBRE ALTERADO (cambia letras o juega con el nombre) de modo que se reconozca claramente a quien parodia; un producto o servicio absurdo ligado a una de estas noticias o tendencias de hoy. No afirmes nada real malo de la empresa (nada de fraudes, defectos ni escandalos): es absurdo evidente. Acaba con un eslogan y devuelve a la musica.",
                data: numbered(base), minWords: 55, maxWords: 100, minTurns: 4
            )
        case .tendencias:
            let mix = world.trends.shuffled().prefix(7).map { "[Google Trends] \($0)" } + world.wiki.shuffled().prefix(7).map { "[Wikipedia] \($0)" }
            guard mix.count >= 5 else { return nil }
            return Spec(
                instruction: "Haz LO MAS BUSCADO de unos 15 a 20 segundos: los locutores comentan con humor 2 cosas de las que la gente mas busca hoy en España (elige de la lista). No inventes detalles: solo puedes decir que es tendencia o que 'todo el mundo lo esta buscando'. Cierra devolviendo a la musica.",
                data: numbered(mix.shuffled()), minWords: 38, maxWords: 70, minTurns: 3
            )
        }
    }

    /// Prepara todo lo de una seccion: el texto, la voz (varios segundos de audio), el grito de entrada, la musiquita y la cuña de salida. `nil` si falta
    /// lo imprescindible (datos, texto o voz); sin musiquita o cuña, la seccion sale igual.
    static func make(kind: RadioSectionKind) async -> RadioSectionAssets? {
        guard let world = await RadioWorld.snapshot(), let spec = spec(for: kind, world: world) else { return nil }
        var notice = ""
        var chosen: [RadioTurn] = []
        for _ in 0..<2 {
            let prompt = spec.instruction + "\n\nDATOS REALES DE HOY (unica fuente de hechos):\n" + spec.data + RadioHistory.promptBlock(count: 3) + notice
            guard let json = try? await Gemini.text(
                system: RadioContent.ficha + "\n\n" + realRules, prompt: prompt, temperature: 1.1, timeout: 14
            ) else { return nil }
            let turns = RadioContent.parseTurns(json)
            let words = turns.reduce(0) { $0 + $1.text.split(separator: " ").count }
            if turns.count >= spec.minTurns, words >= spec.minWords, words <= spec.maxWords {
                chosen = turns
                break
            }
            notice = "\n\nTU INTENTO ANTERIOR NO SIRVE (\(words) palabras en \(turns.count) lineas). Escribe entre \(spec.minWords) y \(spec.maxWords) palabras en al menos \(spec.minTurns) lineas."
        }
        guard !chosen.isEmpty, let voice = await RadioVoice.clip(chosen, timeout: 30) else { return nil }
        RadioHistory.add(chosen)
        let shout = await RadioVoice.clip([(shouts[kind] ?? []).randomElement() ?? RadioTurn(speaker: "Pitirre", text: "¡Sónar efe eme!")],
                                          style: Gemini.announcerStyle, fixed: true, timeout: 12)
        return RadioSectionAssets(
            kind: kind, turns: chosen, voice: voice, shout: shout, bed: RadioSounds.bed(for: kind), outro: RadioSounds.cuna(entrance: false)
        )
    }
}
