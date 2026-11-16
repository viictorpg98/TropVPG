//
//  DJPlanner.swift
//  Trop
//
//  Cuando deja un DJ una cancion: la valora el propio programa, sin un tiempo fijo.
//
//  - Mira la forma de la saliente (su analisis: donde empieza la musica, sus cambios de seccion y de volumen, sus compases) y la
//    compara con la entrante (tempo y tonalidad).
//  - Cuanto deja oir depende de "cuanto de cada cancion" (Ajustes > DJ), contando desde el primer sonido. En normal no mezcla antes de
//    1:15 de musica ni despues de 2:40 y apunta al 65 % de la cancion (entre 1:15 y 2:05). Con "menos" apunta al 45 % (50-90 s, hasta
//    1:50 como mucho) y con "casi toda" al 85 % (al menos 1:30, hasta 25 s antes del final). Nunca mezcla a menos de 30 s del final.
//  - El punto elegido es donde TERMINA la mezcla, no donde empieza: la saliente se va apagando durante los ultimos segundos de su parte
//    fuerte (o de su frase) y cuando llegaria lo siguiente (la estrofa, donde suele entrar la voz) ya suena la entrante. Asi no se corta
//    justo antes de que cante el artista. Los puntos donde SUBE el volumen (donde empieza el estribillo) no se usan nunca.
//  - Elige el final de parte fuerte (el volumen BAJA) mas cercano al objetivo; si no hay ninguno, el inicio de frase (cada 8 compases) mas
//    cercano.
//  - La duracion de la mezcla la elige segun lo bien que encajan las dos: si tempo y tonalidad casan, larga; si chocan, corta.
//  - No toca las canciones largas (mezclas de horas, directos, podcasts): suenan enteras.
//  - Si no queda margen (la cancion es muy corta o ya va por la mitad), no corta: suena hasta su final natural.
//
//  El motor luego ajusta el inicio de la mezcla al siguiente inicio de compas.
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
        let store = TrackAnalysisStore.shared
        if store.isLong(outId) {
            return Decision(cutMs: nil, length: nil, note: "cancion larga: suena entera")
        }
        // Sin tempo medible en alguna de las dos no se puede planificar (y las cuentas de tempo no terminarian).
        guard outgoing.bpm > 0, incoming.bpm > 0, outgoing.beatMs > 0 else {
            return Decision(cutMs: nil, length: nil, note: "sin tempo medible: no se planifica")
        }
        let first = outgoing.firstSoundMs
        let end = outgoing.musicEndMs
        let usable = end - first
        guard usable >= 100_000 else {
            return Decision(cutMs: nil, length: nil, note: "demasiado corta para cortarla antes (\(usable / 1000) s de musica)")
        }

        let clash = pairClash(outgoing: outgoing, incoming: incoming)
        let length: MixStyle.Length = clash.level == 0 ? .long : (clash.level == 2 ? .short : .medium)

        // Cuanto deja oir el DJ de cada cancion segun "cuanto de cada cancion" (0 = menos, 1 = normal, 2 = casi toda). Todo se cuenta desde el
        // primer sonido de la cancion y se refiere al punto donde TERMINA la mezcla.
        let level = min(max(DJSettings.shared.playAmount, 0), 2)
        let lowestPlay: [Int64] = [50_000, 75_000, 60_000]
        let highestPlay: [Int64] = [110_000, 160_000, 10_000_000]
        let fractions: [Double] = [0.45, 0.65, 0.85]
        let preferredMin: [Int64] = [50_000, 75_000, 90_000]
        let preferredMax: [Int64] = [90_000, 125_000, 10_000_000]
        let tailKept: Int64 = level == 2 ? 25_000 : 30_000
        // Margen en el que puede terminar la mezcla: desde la musica minima (y a 35 s o mas de ahora, para que de tiempo a prepararla)
        // hasta la maxima o `tailKept` antes del final.
        let lower = max(first + lowestPlay[level], Int64((currentTime + 35) * 1000))
        let upper = min(first + highestPlay[level], end - tailKept)
        guard lower < upper else {
            return Decision(cutMs: nil, length: length, note: "no queda margen para cortarla antes, suena hasta el final (\(clash.text))")
        }
        let preferredPlay = min(max(Int64(Double(usable) * fractions[level]), preferredMin[level]), preferredMax[level])
        let aim = min(max(first + preferredPlay, lower), upper)

        // Lo que durara la mezcla, aproximado (el planificador la ajusta): sin voces conocidas no pasa de ~10 s. Ademas, dos pulsos de margen
        // por el ajuste al inicio de compas.
        // Las parejas que casan muy bien (tempo y tonalidad) admiten una mezcla mas larga aunque no se sepa cuando cantan (hasta 16 s); el resto, 10 s.
        let vocalCap: Int64 = clash.level == 0 ? 16_000 : 10_000
        let estimate = min(AutoMixMath.durationMs(outgoing: outgoing, incoming: incoming, scale: length.durationScale), vocalCap)
        let margin = Int64(outgoing.beatMs * 2)
        func start(forEnd boundary: Int64) -> Int64 {
            max(boundary - estimate - margin, first + 20_000)
        }
        func described(_ boundary: Int64) -> String {
            String(format: "termina hacia %.0f s y empieza en %.0f s (objetivo %.0f s), mezcla %@ (%@)",
                   Double(boundary) / 1000, Double(start(forEnd: boundary)) / 1000, Double(aim) / 1000, length.rawValue, clash.text)
        }

        // El final de una parte fuerte (el volumen BAJA) mas cercano al objetivo. Los puntos donde SUBE el volumen no se usan.
        let drops = outgoing.sections.filter { $0.deltaDb < 0 && $0.timeMs >= lower && $0.timeMs <= upper }
        if let drop = drops.min(by: { abs($0.timeMs - aim) < abs($1.timeMs - aim) }) {
            return Decision(
                cutMs: start(forEnd: drop.timeMs), length: length,
                note: String(format: "fin de parte fuerte (baja %.1f dB): ", -drop.deltaDb) + described(drop.timeMs),
                vocalCapMs: vocalCap
            )
        }
        // Sin un final de parte fuerte a mano: el inicio de frase (cada 8 compases desde el primer compas con musica) mas cercano.
        let bars = outgoing.downbeatsMs.filter { $0 >= first }
        var phraseStarts: [Int64] = []
        for (index, bar) in bars.enumerated() where index % 8 == 0 { phraseStarts.append(bar) }
        if let phrase = phraseStarts.filter({ $0 >= lower && $0 <= upper }).min(by: { abs($0 - aim) < abs($1 - aim) }) {
            return Decision(cutMs: start(forEnd: phrase), length: length, note: "inicio de frase: " + described(phrase), vocalCapMs: vocalCap)
        }
        return Decision(cutMs: start(forEnd: aim), length: length, note: "sin secciones ni compases claros: " + described(aim), vocalCapMs: vocalCap)
    }
}
