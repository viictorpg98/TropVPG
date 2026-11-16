//
//  DJPlanner.swift
//  Trop
//
//  Como mezcla el DJ una pareja de canciones.
//
//  - La saliente suena hasta su punto de salida NATURAL, el mismo de AutoMix: el final de su ultimo estribillo (o el final de la musica) con el
//    ajuste "Momento de la mezcla". El DJ ya no corta las canciones por su cuenta: quien quiera pasar antes pulsa "siguiente", que mezcla
//    con la siguiente al momento (`DJSession.next`). Antes elegia el final de una parte fuerte "mas cercano al objetivo" y, con pocas partes
//    fuertes, mezclaba muy pronto (en los informes: "termina hacia 86 s (objetivo 173 s)").
//  - Lo unico que decide aqui es la DURACION de la mezcla segun lo bien que encajan las dos: si tempo y tonalidad casan, larga (y se admite
//    hasta 16 s aunque no se sepa cuando cantan); si chocan, corta.
//  - No toca las canciones largas (mezclas de horas, directos, podcasts): suenan enteras.
//

import Foundation

@MainActor
enum DJPlanner {
    struct Decision {
        /// Donde empieza la mezcla en la saliente (ms de su cancion); `nil`: el punto de salida natural de AutoMix (lo normal).
        var cutMs: Int64?
        /// La duracion de mezcla que le parece bien a esta pareja (`nil`: la que ya habia).
        var length: MixStyle.Length?
        /// Que decidio y por que (para el informe).
        var note: String
        /// Lo mas que puede durar la mezcla sin saber cuando cantan (ms); `nil`: el de siempre (10 s).
        var vocalCapMs: Int64?
    }

    /// Lo bien que encajan las dos: 0 (casan) a 2 (chocan).
    private static func pairClash(outgoing: TrackStructure, incoming: TrackStructure) -> (level: Int, text: String) {
        let folded = AutoMixMath.foldedRatio(outgoingBpm: outgoing.bpm, incomingBpm: incoming.bpm)
        let tempoGap = abs(1 - folded)
        var keyText = "tonalidad ?"
        var keyDistance = 1
        if let outKey = outgoing.key, let inKey = incoming.key {
            keyDistance = KeyDetector.distance(outKey, inKey)
            keyText = "tonalidad a \(keyDistance)"
        }
        let text = String(format: "tempo %.0f%%, %@", tempoGap * 100, keyText)
        if tempoGap > 0.09 || keyDistance >= 3 { return (2, text) }
        if tempoGap < 0.04, keyDistance <= 1 { return (0, text) }
        return (1, text)
    }

    static func decide(outId: String, outgoing: TrackStructure, incoming: TrackStructure, currentTime: TimeInterval) -> Decision {
        if TrackAnalysisStore.shared.isLong(outId) {
            return Decision(cutMs: nil, length: nil, note: "cancion larga: suena entera")
        }
        // Sin tempo medible en alguna de las dos no se puede decidir (y las cuentas de tempo no terminarian).
        guard outgoing.bpm > 0, incoming.bpm > 0, outgoing.beatMs > 0 else {
            return Decision(cutMs: nil, length: nil, note: "sin tempo medible: se deja a AutoMix")
        }
        let clash = pairClash(outgoing: outgoing, incoming: incoming)
        let length: MixStyle.Length = clash.level == 0 ? .long : (clash.level == 2 ? .short : .medium)
        let vocalCap: Int64 = clash.level == 0 ? 16_000 : 10_000
        return Decision(
            cutMs: nil, length: length,
            note: "sale por su punto natural (como AutoMix), mezcla \(length.rawValue) (\(clash.text))",
            vocalCapMs: vocalCap
        )
    }
}
