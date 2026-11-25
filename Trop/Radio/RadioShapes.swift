//
//  RadioShapes.swift
//  Trop
//
//  Para que las piezas entre canciones no suenen siempre igual ("habla uno, habla el otro, y seguimos"): cada pieza sale de un PLAN con tres cosas que se sortean
//  y no se repiten seguidas: el PROPOSITO (de que va: chiste, repasar lo que sono, algo de la zona, una dedicatoria...), la FORMA de la conversacion (uno solo,
//  uno cuenta y el otro apenas reacciona, interrupciones, los dos de acuerdo, el dueto clasico) y la LONGITUD (de una frase de 4 segundos a casi un minuto).
//  Las formas se comprueban despues de escribir (si no se cumplen, se reintenta; al ultimo intento sale igual).
//

import Foundation

/// Como se reparte la conversacion.
enum RadioShape: CaseIterable {
    case dry, solo, listens, interrupt, agree, duo

    var instruction: String {
        switch self {
        case .dry:
            return "UN solo locutor, UNA frase: presenta la cancion; si el DE QUE VA trae un chiste o una pulla, esa frase ES el chiste (corto y con remate); si no, con naturalidad, como una radio normal."
        case .solo:
            return "UN solo locutor habla (todas las lineas son suyas; cuantas, segun la LONGITUD) y el otro NO interviene."
        case .listens:
            return "Uno cuenta algo (1 o 2 lineas con sustancia) y el otro solo reacciona con frases de MAXIMO 6 palabras, pero CON GRACIA (una pulla corta o una reaccion absurda; prohibido \"aja\", \"¿en serio?\" y \"no me digas\")."
        case .interrupt:
            return "Una de las lineas se corta a mitad de frase (acaba en \"—\") porque el otro entra a corregir o a completar; la linea cortada no se termina."
        case .agree:
            return "Los dos coinciden y se suman el uno al otro, sin pincharse ni burlarse."
        case .duo:
            return "Conversacion de ida y vuelta (se alternan), con alguna pulla cariñosa."
        }
    }

    /// `nil` si los turnos cumplen la forma; si no, lo que hay que corregir.
    func problem(in turns: [RadioTurn]) -> String? {
        let speakers = Set(turns.map(\.speaker))
        switch self {
        case .dry:
            return turns.count == 1 ? nil : "debe ser UNA sola linea de un solo locutor"
        case .solo:
            return speakers.count == 1 ? nil : "debe hablar UN solo locutor (el otro no interviene)"
        case .listens:
            guard speakers.count == 2 else { return "deben intervenir los dos: uno cuenta y el otro solo reacciona" }
            var words: [String: Int] = [:]
            for turn in turns { words[turn.speaker, default: 0] += turn.text.split(separator: " ").count }
            let least = words.values.min() ?? 0
            return least <= 10 ? nil : "uno de los dos solo debe reaccionar con frases muy cortas (maximo 4 palabras cada una)"
        case .interrupt:
            let cut = turns.dropLast().contains(where: { (turn: RadioTurn) -> Bool in
                let text = turn.text.trimmingCharacters(in: .whitespaces)
                return text.hasSuffix("—") || text.hasSuffix("-") || text.hasSuffix("…") || text.hasSuffix("...")
            })
            return cut ? nil : "una de las lineas debe quedar cortada a medias (acabar en —) porque el otro entra"
        case .agree:
            return speakers.count == 2 ? nil : "deben hablar los dos"
        case .duo:
            return speakers.count == 2 && turns.count >= 2 ? nil : "deben alternarse los dos"
        }
    }
}

/// Cuanto dura la pieza.
enum RadioLength {
    case tiny, short, medium, long

    var instruction: String {
        switch self {
        case .tiny: return "UNA sola linea de UN locutor, de 4 a 12 palabras (3 a 5 segundos): una pulla o un chiste de una frase (con remate) o, si el DE QUE VA no es de chiste, un saludo, un aviso o presentar la cancion."
        case .short: return "De 1 a 3 lineas y de 14 a 32 palabras en total (8 a 12 segundos)."
        case .medium: return "De 3 a 6 lineas y de 50 a 90 palabras en total (20 a 30 segundos)."
        case .long: return "De 5 a 8 lineas y de 100 a 140 palabras en total (40 a 55 segundos)."
        }
    }

    var maxWords: Int {
        switch self {
        case .tiny: return 18
        case .short: return 40
        case .medium: return 115
        case .long: return 170
        }
    }

    /// El minimo se mide en PALABRAS (un monologo puede venir en una sola linea).
    var minWords: Int {
        switch self {
        case .tiny: return 3
        case .short: return 10
        case .medium: return 35
        case .long: return 80
        }
    }

    var maxLines: Int {
        switch self {
        case .tiny: return 2
        case .short: return 3
        case .medium: return 7
        case .long: return 10
        }
    }

    /// Las formas que caben en esta longitud.
    var shapes: [RadioShape] {
        switch self {
        case .tiny: return [.dry]
        case .short: return [.dry, .solo, .listens, .agree, .duo]
        case .medium: return [.solo, .listens, .interrupt, .agree, .duo]
        case .long: return [.solo, .listens, .interrupt, .duo]
        }
    }

    /// Si ningun intento cumple la longitud, se usa el mas cercano recortado (mejor eso que dejar el paso sin voz): el tiny se queda en su primera linea y los demas
    /// pierden lineas del final mientras se pasen de palabras.
    func trimmed(_ turns: [RadioTurn]) -> [RadioTurn] {
        if self == .tiny { return Array(turns.prefix(1)) }
        var result = turns
        func count(_ list: [RadioTurn]) -> Int { list.reduce(0) { $0 + $1.text.split(separator: " ").count } }
        while result.count > 1, count(result) > maxWords { result.removeLast() }
        return result
    }

    /// `nil` si cumple; si no, lo que hay que corregir.
    func problem(words: Int, lines: Int) -> String? {
        if lines < 1 || lines > maxLines || words < minWords || words > maxWords {
            return "NO CUMPLE LA LONGITUD (\(lines) lineas, \(words) palabras). " + instruction
        }
        return nil
    }
}

/// De que va la pieza.
enum RadioPurpose {
    case banter, backAnnounce, reaction, local, dedication, question

    /// El texto del propósito (el del chiste lo pone el mazo de formatos de `RadioContent`).
    var instruction: String {
        switch self {
        case .banter:
            return ""
        case .backAnnounce:
            return "repasan lo que ACABA de sonar con naturalidad (titulo y artista, y el disco o el año solo si se te dan) y presentan la siguiente, como una radio normal; sin chiste o con uno minimo."
        case .reaction:
            return "una reaccion sincera a lo que acaba de sonar o a la que viene, sin afirmar nada concreto sobre la cancion ni el artista."
        case .local:
            return "comentan UNA cosa de la zona usando SOLO el dato de la zona de abajo, y presentan la siguiente."
        case .dedication:
            return "dedican la cancion que viene al oyente usando SOLO uno de sus datos reales de la lista de abajo, con cariño y sin inventar nada."
        case .question:
            return "le hacen al oyente una pregunta cercana y concreta (sin esperar respuesta) y presentan la siguiente."
        }
    }
}

extension RadioPurpose {
    /// El texto del proposito segun el nivel de humor: con picante o negro, los que antes pedian "sin chiste" o "sincera" piden una pulla con gracia.
    func instruction(for level: RadioHumorLevel) -> String {
        guard level != .mild else { return instruction }
        switch self {
        case .banter:
            return ""
        case .backAnnounce:
            return "repasan lo que ACABA de sonar (titulo y artista) con una pulla ingeniosa y concreta, y presentan la siguiente."
        case .reaction:
            return "una reaccion exagerada y con gracia a lo que acaba de sonar o a la que viene (sin afirmar nada concreto sobre la cancion ni el artista), con un detalle concreto."
        case .local:
            return "una pulla ingeniosa con UNA cosa de la zona, usando SOLO el dato de la zona de abajo, y presentan la siguiente."
        case .dedication:
            return "dedican la cancion que viene a la persona con una pulla, usando SOLO uno de sus datos reales de abajo (son datos DE ELLA y se los dicen a ella), sin inventar nada."
        case .question:
            return "le hacen a la persona una pregunta de mala leche, concreta y con gracia (sin esperar respuesta), y presentan la siguiente."
        }
    }
}

/// El plan de una pieza: proposito, forma y longitud, sorteados sin repetir lo ultimo que salio.
struct RadioBlueprint {
    let purpose: RadioPurpose
    let shape: RadioShape
    let length: RadioLength

    nonisolated(unsafe) private static var recentShapes: [RadioShape] = []
    nonisolated(unsafe) private static var lastPurpose: RadioPurpose?

    static func draw(kind: RadioPieceKind, hasPrevious: Bool, hasLocal: Bool, hasFacts: Bool, humor: RadioHumorLevel = .mild) -> RadioBlueprint {
        // Longitud: el mini es una frase de 4 s o algo corto; la charla, mediana o (de vez en cuando) larga.
        let length: RadioLength
        if kind == .mini {
            length = Int.random(in: 0..<100) < 35 ? .tiny : .short
        } else {
            length = Int.random(in: 0..<100) < 18 ? .long : .medium
        }
        // Proposito: el chiste pesa como mucho un 30 % (el doble con humor picante o negro); el resto, radio normal.
        var options: [(purpose: RadioPurpose, weight: Int)] = [
            (purpose: RadioPurpose.banter, weight: humor == .mild ? 30 : 60), (purpose: RadioPurpose.reaction, weight: 12), (purpose: RadioPurpose.question, weight: 10)
        ]
        if hasPrevious { options.append((purpose: RadioPurpose.backAnnounce, weight: 20)) }
        if hasLocal { options.append((purpose: RadioPurpose.local, weight: 16)) }
        if hasFacts { options.append((purpose: RadioPurpose.dedication, weight: 12)) }
        if let last = lastPurpose, options.count > 1 { options.removeAll { $0.purpose == last } }
        let total = options.reduce(0) { $0 + $1.weight }
        var roll = Int.random(in: 0..<max(1, total))
        var purpose = RadioPurpose.banter
        for option in options {
            if roll < option.weight {
                purpose = option.purpose
                break
            }
            roll -= option.weight
        }
        lastPurpose = purpose
        // Forma: sin repetir las dos ultimas; el dueto clasico pesa la mitad que las demas.
        let shape = drawShape(from: length.shapes)
        return RadioBlueprint(purpose: purpose, shape: shape, length: length)
    }

    /// Una forma de entre las permitidas, sin repetir las dos ultimas (tambien la usan las secciones).
    static func drawShape(from allowed: [RadioShape]) -> RadioShape {
        var shapes = allowed.filter { !recentShapes.suffix(2).contains($0) }
        if shapes.isEmpty { shapes = allowed }
        let weighted = shapes + shapes.filter { $0 != .duo }
        let shape = weighted.randomElement() ?? .duo
        recentShapes.append(shape)
        if recentShapes.count > 6 { recentShapes.removeFirst(recentShapes.count - 6) }
        return shape
    }
}
