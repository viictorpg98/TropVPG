//
//  DJPlanner.swift
//  Trop
//
//  Cuando deja un DJ una cancion: la valora el propio programa, sin un tiempo fijo.
//
//  - Mira la forma de la saliente (su analisis: donde empieza la musica, sus cambios de seccion y de volumen, sus compases) y la
//    compara con la entrante (tempo y tonalidad).
//  - No corta antes de ~1 minuto de musica ni despues de ~2 min 20 s; dentro de ese margen apunta a algo mas de la mitad de la
//    cancion (entre 1 y 1:50 min de musica), segun lo que dure.
//  - Elige el cambio de seccion mas cercano a ese punto, mejor si el volumen BAJA ahi (el final de una parte fuerte, que es por donde
//    sale un DJ); si no hay ninguno, el inicio de frase (cada 8 compases) mas cercano.
//  - La duracion de la mezcla la elige segun lo bien que encajan las dos: si tempo y tonalidad casan, larga; si chocan, corta.
//  - No toca las canciones largas (mezclas de horas, directos, podcasts): suenan enteras.
//  - Si no queda margen (la cancion es muy corta o ya va por la mitad), no corta: suena hasta su final natural.
//
//  El motor luego ajusta el punto al siguiente inicio de compas.
//

import Foundation

@MainActor
enum DJPlanner {
    struct Decision {
        /// Donde empieza la mezcla en la saliente (ms de su cancion); `nil`: que suene hasta su final natural.
        var cutMs: Int64?
        /// La duracion de mezcla que le parece bien a esta pareja (`nil`: la que ya habia).
        var length: MixStyle.Length?
        /// Que decidio y por que (para el informe).
        var note: String
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
        let store = TrackAnalysisStore.shared
        if store.isLong(outId) {
            return Decision(cutMs: nil, length: nil, note: "cancion larga: suena entera")
        }
        let first = outgoing.firstSoundMs
        let end = outgoing.musicEndMs
        let usable = end - first
        guard outgoing.beatMs > 0, usable >= 100_000 else {
            return Decision(cutMs: nil, length: nil, note: "demasiado corta para cortarla antes (\(usable / 1000) s de musica)")
        }

        let clash = pairClash(outgoing: outgoing, incoming: incoming)
        let length: MixStyle.Length = clash.level == 0 ? .long : (clash.level == 2 ? .short : .medium)

        // Margen en el que se puede cortar: de 1 min de musica a 2:20 (sin pasarse de 30 s antes del final), y a 25 s o mas de ahora.
        let lower = max(first + 60_000, Int64((currentTime + 25) * 1000))
        let upper = min(first + 140_000, end - 30_000)
        guard lower < upper else {
            return Decision(cutMs: nil, length: length, note: "no queda margen para cortarla antes, suena hasta el final (\(clash.text))")
        }
        let preferredPlay = min(max(Int64(Double(usable) * 0.55), 60_000), 110_000)
        let aim = min(max(first + preferredPlay, lower), upper)

        let inWindow = outgoing.sections.filter { $0.timeMs >= lower && $0.timeMs <= upper }
        func nearest(_ list: [SectionChange]) -> SectionChange? {
            list.min { abs($0.timeMs - aim) < abs($1.timeMs - aim) }
        }
        if let drop = nearest(inWindow.filter { $0.deltaDb < 0 }) {
            return Decision(
                cutMs: drop.timeMs, length: length,
                note: String(format: "corta en %.0f s (baja %.1f dB; objetivo %.0f s), mezcla %@ (%@)",
                             Double(drop.timeMs) / 1000, drop.deltaDb, Double(aim) / 1000, length.rawValue, clash.text)
            )
        }
        if let change = nearest(inWindow) {
            return Decision(
                cutMs: change.timeMs, length: length,
                note: String(format: "corta en %.0f s (cambio de seccion, sube %.1f dB; objetivo %.0f s), mezcla %@ (%@)",
                             Double(change.timeMs) / 1000, change.deltaDb, Double(aim) / 1000, length.rawValue, clash.text)
            )
        }
        // Sin cambios de seccion: el inicio de frase (cada 8 compases desde el primer compas con musica) mas cercano al objetivo.
        let bars = outgoing.downbeatsMs.filter { $0 >= first }
        var phraseStarts: [Int64] = []
        for (index, bar) in bars.enumerated() where index % 8 == 0 { phraseStarts.append(bar) }
        if let phrase = phraseStarts.filter({ $0 >= lower && $0 <= upper }).min(by: { abs($0 - aim) < abs($1 - aim) }) {
            return Decision(
                cutMs: phrase, length: length,
                note: String(format: "corta en %.0f s (inicio de frase; objetivo %.0f s), mezcla %@ (%@)",
                             Double(phrase) / 1000, Double(aim) / 1000, length.rawValue, clash.text)
            )
        }
        return Decision(
            cutMs: aim, length: length,
            note: String(format: "corta hacia %.0f s (sin secciones ni compases claros), mezcla %@ (%@)",
                         Double(aim) / 1000, length.rawValue, clash.text)
        )
    }
}
