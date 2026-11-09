//
//  MixLearning.swift
//  Trop
//
//  AutoMix aprende de las valoraciones de las mezclas (los pulgares tras cada mezcla). Cada mezcla se clasifica por el
//  "estilo" con el que se hizo: su duracion (corta, media o larga) y, cuando los tempos son parecidos, si se igualo el
//  tempo o se dejo como estaba. Cada estilo lleva la cuenta de bien y mal; el motor elige con mas probabilidad los que te
//  gustan, pero de vez en cuando prueba otros. Las parejas de canciones valoradas mal no repiten el mismo estilo.
//

import Foundation

/// Como se hace una mezcla concreta.
struct MixStyle: Equatable {
    enum Length: String, CaseIterable {
        case short, medium, long

        /// Cuanto se alarga o acorta la duracion que elegiria AutoMix.
        var durationScale: Double {
            switch self {
            case .short: return 0.7
            case .medium: return 1.0
            case .long: return 1.4
            }
        }
    }

    var length: Length = .medium
    /// `false`: se deja el tempo de cada cancion como esta, sin estirarlo (solo tiene efecto si los tempos son parecidos).
    var matchTempo = true
    /// "near" (tempos parecidos) o "far" (muy distintos).
    var context: String

    var key: String { "\(context)|\(length.rawValue)|\(matchTempo ? "tempo" : "libre")" }

    static func parse(_ key: String) -> MixStyle? {
        let parts = key.split(separator: "|").map(String.init)
        guard parts.count == 3, let length = Length(rawValue: parts[1]) else { return nil }
        return MixStyle(length: length, matchTempo: parts[2] == "tempo", context: parts[0])
    }
}

@MainActor
final class MixLearning {
    static let shared = MixLearning()

    private struct Counts: Codable {
        var good = 0
        var bad = 0
    }

    private struct PairMemory: Codable {
        var arm: String
        var rating: Int
    }

    private struct Stored: Codable {
        var arms: [String: Counts] = [:]
        var pairs: [String: PairMemory] = [:]
    }

    private static let key = "automix.learning.v1"
    private var stored: Stored
    /// Lo ya decidido para cada pareja en esta sesion (el plan se pide varias veces y debe salir igual).
    private var decided: [String: MixStyle] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = saved
        } else {
            stored = Stored()
        }
    }

    // MARK: - Elegir estilo

    private static func pairKey(_ outId: String, _ inId: String) -> String { "\(outId)>\(inId)" }

    static func context(outgoingBpm: Double, incomingBpm: Double) -> String {
        let folded = AutoMixMath.foldedRatio(outgoingBpm: outgoingBpm, incomingBpm: incomingBpm)
        return abs(1 - folded) <= 0.08 ? "near" : "far"
    }

    private func candidates(context: String) -> [MixStyle] {
        var list: [MixStyle] = []
        for length in MixStyle.Length.allCases {
            list.append(MixStyle(length: length, matchTempo: true, context: context))
            // Dejar el tempo como esta solo tiene sentido si los tempos son parecidos (si no, ya no se igualan).
            if context == "near" {
                list.append(MixStyle(length: length, matchTempo: false, context: context))
            }
        }
        return list
    }

    /// El estilo para mezclar estas dos canciones. Sin aprendizaje (apagado en Ajustes), el de siempre: media, tempo igualado.
    func style(outId: String, inId: String, outBpm: Double, inBpm: Double) -> MixStyle {
        let context = Self.context(outgoingBpm: outBpm, incomingBpm: inBpm)
        let standard = MixStyle(length: .medium, matchTempo: true, context: context)
        guard SettingsStore.shared.autoMixLearns else { return standard }
        let pair = Self.pairKey(outId, inId)
        if let known = decided[pair] { return known }

        var options = candidates(context: context)
        var chosen: MixStyle?
        if let memory = stored.pairs[pair] {
            if memory.rating > 0, let liked = MixStyle.parse(memory.arm), options.contains(liked) {
                // Esta pareja ya salio bien: se repite como estaba.
                chosen = liked
            } else if memory.rating < 0 {
                // Esta pareja salio mal: no se repite el mismo estilo.
                let rest = options.filter { $0.key != memory.arm }
                if !rest.isEmpty { options = rest }
            }
        }
        if chosen == nil {
            if Double.random(in: 0..<1) < 0.08 {
                chosen = options.randomElement()
            } else {
                chosen = options.max { score($0, standard: standard) < score($1, standard: standard) }
            }
        }
        let result = chosen ?? standard
        decided[pair] = result
        return result
    }

    /// Media de aciertos (con una creencia inicial a favor del estilo de siempre) mas un extra de curiosidad para los
    /// estilos poco probados.
    private func score(_ style: MixStyle, standard: MixStyle) -> Double {
        let counts = stored.arms[style.key] ?? Counts()
        let prior = style == standard ? (2.0, 1.0) : (1.0, 1.0)
        let total = Double(counts.good + counts.bad)
        let mean = (Double(counts.good) + prior.0) / (total + prior.0 + prior.1)
        return mean + 0.3 / (total + 1).squareRoot()
    }

    // MARK: - Aprender

    /// Una valoracion explicita (1 = bien, -1 = mal) de una mezcla hecha con este estilo.
    func record(arm: String, outId: String, inId: String, rating: Int) {
        guard rating != 0 else { return }
        var counts = stored.arms[arm] ?? Counts()
        if rating > 0 { counts.good += 1 } else { counts.bad += 1 }
        stored.arms[arm] = counts
        let pair = Self.pairKey(outId, inId)
        stored.pairs[pair] = PairMemory(arm: arm, rating: rating)
        decided[pair] = nil
        if stored.pairs.count > 400 {
            // Se conservan las mas recientes (el diccionario no guarda orden: se recorta al azar lo sobrante).
            for key in stored.pairs.keys.prefix(stored.pairs.count - 400) { stored.pairs[key] = nil }
        }
        persist()
        PlaybackReport.record("automix: aprendido de la valoracion: \(arm) \(rating > 0 ? "bien" : "mal") (\(counts.good) bien / \(counts.bad) mal)")
    }

    func reset() {
        stored = Stored()
        decided = [:]
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    // MARK: - Resumen para Ajustes

    var totalRatings: Int {
        stored.arms.values.reduce(0) { $0 + $1.good + $1.bad }
    }

    /// Lineas que cuentan lo que ha aprendido.
    func summary() -> [String] {
        guard totalRatings > 0 else { return [] }
        var lines = [String(format: NSLocalizedString("Ratings so far: %d", comment: ""), totalRatings)]
        for context in ["near", "far"] {
            let arms = candidates(context: context).compactMap { style -> (MixStyle, Counts)? in
                guard let counts = stored.arms[style.key], counts.good + counts.bad > 0 else { return nil }
                return (style, counts)
            }
            guard !arms.isEmpty else { continue }
            let total = arms.reduce(0) { $0 + $1.1.good + $1.1.bad }
            let best = arms.max { lhs, rhs in
                let left = Double(lhs.1.good + 1) / Double(lhs.1.good + lhs.1.bad + 2)
                let right = Double(rhs.1.good + 1) / Double(rhs.1.good + rhs.1.bad + 2)
                return left < right
            }
            guard let best else { continue }
            let contextName = NSLocalizedString(context == "near" ? "Similar tempos" : "Different tempos", comment: "")
            var description = NSLocalizedString("\(best.0.length.rawValue) mixes", comment: "")
            if context == "near" {
                description += ", " + NSLocalizedString(best.0.matchTempo ? "tempo matched" : "tempo left alone", comment: "")
            }
            lines.append(String(
                format: NSLocalizedString("%@: %@ (%d of %d good)", comment: ""),
                contextName, description, best.1.good, best.1.good + best.1.bad
            ))
            _ = total
        }
        return lines
    }
}
