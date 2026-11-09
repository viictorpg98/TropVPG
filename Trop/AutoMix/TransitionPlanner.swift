//
//  TransitionPlanner.swift
//  Trop
//
//  Adaptado a Swift de TransitionPlanner.kt y de las formulas de duracion y tempo de
//  CrossfadeExoPlayerAdapter.kt de SimpMusic (maxrave-dev/core, GPL-3.0).
//

import Foundation

/// Donde ocurre una mezcla, en milisegundos de cada cancion: la ventana de la saliente y el segundo
/// desde el que suena la entrante.
struct TransitionPlan: Equatable {
    /// Posicion de la saliente cuando empieza la mezcla.
    var outgoingStartMs: Int64
    /// Posicion de la saliente cuando acaba: el final de su ultimo estribillo o de su musica.
    var outgoingEndMs: Int64
    var durationMs: Int64
    /// Desde donde suena la entrante.
    var incomingStartMs: Int64
    /// Velocidad a la que llega la saliente al final de su rampa (1 = sin cambio).
    var outgoingSpeedRatio: Double
    /// Velocidad con la que empieza la entrante (vuelve a 1 al final de la mezcla).
    var incomingSpeedRatio: Double
}

enum TransitionPlanner {
    /// Parte de la mezcla en que la saliente llega a su velocidad final (suavizado), y luego la mantiene.
    static let rampPortion = 0.6
    /// Solape maximo de voces que se admite (ms), como en LastWave.
    static let maxVocalOverlapMs = 350

    /// Cuando se canta en cada cancion; `nil` si no se sabe.
    struct Vocals {
        var outgoing: [VocalMaskStore.Segment]?
        var incoming: [VocalMaskStore.Segment]?
    }

    /// Una mezcla entre dos canciones ya analizadas, con los puntos ajustados a compases. `nil` si no se puede
    /// mezclar bien (cancion saliente demasiado corta, datos raros...). Con las voces conocidas, busca una colocacion en
    /// que no se pisen (acortando la mezcla o moviendo los puntos de corte y de entrada); sin ellas, limita la duracion.
    static func plan(
        outgoing: TrackStructure, incoming: TrackStructure, vocals: Vocals? = nil
    ) -> (plan: TransitionPlan, note: String)? {
        guard outgoing.beatMs > 0, outgoing.bpm > 0, incoming.bpm > 0 else { return nil }
        // El cambio de tempo se reparte entre las dos canciones (cada una la raiz de la diferencia), asi ninguna se
        // estira mucho, y como maximo un 6 % cada una (mas, en voces, suena mal).
        let full = AutoMixMath.speedRatio(outgoingBpm: outgoing.bpm, incomingBpm: incoming.bpm)
        let outgoingRatio = AutoMixMath.quantized(full.squareRoot())
        let incomingRatio = AutoMixMath.quantized(1 / full.squareRoot())
        var baseDuration = AutoMixMath.durationMs(outgoing: outgoing, incoming: incoming)
        // Si los tempos no se pueden igualar (mas de un 7 %, contando mitad y doble), las dos suenan a la vez con ritmos
        // distintos: cuanto mas dure, peor. Una mezcla corta.
        let folded = AutoMixMath.foldedRatio(outgoingBpm: outgoing.bpm, incomingBpm: incoming.bpm)
        if full == 1, abs(1 - folded) > 0.07 { baseDuration = min(baseDuration, 8_000) }

        let knownVocals = vocals?.outgoing != nil && vocals?.incoming != nil
        if !knownVocals { baseDuration = min(baseDuration, 10_000) }

        let bar = Int64(outgoing.beatMs * 4)
        let incomingBar = Int64(incoming.beatMs * 4)
        var durations: [Int64] = []
        for candidate in [baseDuration, Int64(Double(baseDuration) * 0.8), Int64(Double(baseDuration) * 0.65), 8_000, 6_000] {
            let value = min(candidate, baseDuration)
            if value >= 6_000, !durations.contains(value) { durations.append(value) }
        }
        if durations.isEmpty { durations = [baseDuration] }

        var best: (plan: TransitionPlan, overlap: Int)?
        for duration in durations {
            for cutShift in [Int64(0), bar, 2 * bar, 4 * bar] {
                for incomingShift in [Int64(0), incomingBar, 2 * incomingBar, 4 * incomingBar, 8 * incomingBar] {
                    guard let candidate = build(
                        outgoing: outgoing, incoming: incoming, durationMs: duration,
                        outgoingRatio: outgoingRatio, incomingRatio: incomingRatio,
                        cutShiftMs: cutShift, incomingShiftMs: incomingShift
                    ) else { continue }
                    guard knownVocals, let out = vocals?.outgoing, let inc = vocals?.incoming else {
                        return (candidate, "voces desconocidas, mezcla limitada a \(duration / 1000) s")
                    }
                    let overlap = VocalMaskStore.overlapMs(
                        outgoing: out, incoming: inc,
                        outgoingStart: Double(candidate.outgoingStartMs) / 1000,
                        incomingStart: Double(candidate.incomingStartMs) / 1000,
                        duration: Double(candidate.durationMs) / 1000
                    )
                    if overlap <= maxVocalOverlapMs {
                        return (candidate, "voces: solape \(overlap) ms")
                    }
                    if best == nil || overlap < best!.overlap { best = (candidate, overlap) }
                }
            }
        }
        guard let best else { return nil }
        return (best.plan, "voces: solape \(best.overlap) ms (no se pudo evitar)")
    }

    /// Una colocacion concreta: `cutShiftMs` retrasa el corte de la saliente e `incomingShiftMs` adelanta la entrada de la
    /// entrante (hacia el principio de su cancion).
    private static func build(
        outgoing: TrackStructure, incoming: TrackStructure, durationMs: Int64,
        outgoingRatio: Double, incomingRatio: Double, cutShiftMs: Int64, incomingShiftMs: Int64
    ) -> TransitionPlan? {
        let naturalEnd = outgoing.lastChorusEndMs ?? outgoing.musicEndMs
        let end = min(naturalEnd + cutShiftMs, max(outgoing.musicEndMs, naturalEnd))
        // La saliente recorre mas (o menos) de su propia linea de tiempo de lo que dura la mezcla, porque
        // cambia de velocidad: media a mitad de rampa y luego la mantiene.
        let advance = Double(durationMs) * (1 + (outgoingRatio - 1) * (1 - rampPortion / 2))
        var start = Int64(Double(end) - advance)
        if start <= outgoing.firstSoundMs { return nil }

        // Se empieza en el inicio de compas de la saliente inmediatamente anterior, para que la mezcla quede
        // dentro de la ventana.
        if let bar = outgoing.downbeatsMs.last(where: { $0 <= start }), start - bar < Int64(outgoing.beatMs * 4) {
            start = bar
        }
        if start <= outgoing.firstSoundMs { return nil }

        // La entrante entra por el inicio de compas mas cercano al punto donde su intro acabaria con la mezcla.
        let incomingAdvance = AutoMixMath.incomingAdvanceMs(durationMs: durationMs, startRatio: incomingRatio)
        var incomingStart: Int64 = 0
        if let introEnd = incoming.introEndMs {
            incomingStart = max(introEnd - incomingAdvance, 0)
        } else {
            incomingStart = incoming.firstSoundMs
        }
        incomingStart = max(incomingStart - incomingShiftMs, 0)
        if let bar = incoming.downbeatsMs.min(by: { abs($0 - incomingStart) < abs($1 - incomingStart) }),
           abs(bar - incomingStart) < Int64(incoming.beatMs * 4) {
            incomingStart = bar
        }
        incomingStart = max(
            incomingStart + beatPhaseShift(
                outgoing: outgoing, incoming: incoming, durationMs: durationMs,
                outgoingRatio: outgoingRatio, incomingRatio: incomingRatio
            ),
            0
        )
        return TransitionPlan(
            outgoingStartMs: start,
            outgoingEndMs: end,
            durationMs: durationMs,
            incomingStartMs: incomingStart,
            outgoingSpeedRatio: outgoingRatio,
            incomingSpeedRatio: incomingRatio
        )
    }

    /// Cuanto hay que mover el punto de entrada de la entrante para que sus pulsos caigan sobre los de la saliente
    /// cuando esta termina de igualar su tempo. Las dos cambian de velocidad y avanzan mas (o menos) que la mezcla,
    /// y esa diferencia descuadra los pulsos aunque los tempos acaben iguales. Se compara en que punto de su pulso
    /// esta cada una en ese momento y se mueve la entrante la diferencia.
    /// 0 si los tempos no quedan iguales (entonces no hay pulsos que casar).
    static func beatPhaseShift(
        outgoing: TrackStructure, incoming: TrackStructure, durationMs: Int64,
        outgoingRatio: Double, incomingRatio: Double
    ) -> Int64 {
        // Periodo efectivo del pulso de cada una ya con su velocidad: debe coincidir, o ser el doble/la mitad.
        let effectiveOut = outgoing.beatMs / outgoingRatio
        let effectiveIn = incoming.beatMs / incomingRatio
        let octaves = log2(effectiveOut / effectiveIn)
        guard abs(octaves - octaves.rounded()) < 0.06, abs(octaves) <= 1.05 else { return 0 }
        // Cuando la saliente llega a su velocidad final (la entrante sigue a la suya).
        let rampMs = Double(durationMs) * rampPortion
        let outgoingAdvanced = rampMs * (1 + (outgoingRatio - 1) / 2)
        let incomingAdvanced = rampMs * incomingRatio
        let outPhase = (outgoingAdvanced / outgoing.beatMs).truncatingRemainder(dividingBy: 1)
        let inPhase = (incomingAdvanced / incoming.beatMs).truncatingRemainder(dividingBy: 1)
        var shift = (outPhase - inPhase) * incoming.beatMs
        let beat = incoming.beatMs
        shift -= beat * (shift / beat).rounded()
        return Int64(shift)
    }
}

enum AutoMixMath {
    // Duracion: los extremos de SimpMusic (20-45 s) eran eternos; aqui 8-16 s, mas cerca de lo que se oye en Apple
    // Music. Sin tonalidad (no tenemos metadatos de Tidal) no hay factor de tonalidad.
    private static let minDurationMs = 8_000.0
    private static let maxDurationMs = 16_000.0
    private static let beatCountOptions: [Double] = [8, 12, 16, 24, 32]
    private static let bpmGapScale = 2.0
    /// Diferencia de tempo maxima que se iguala (repartida entre las dos canciones).
    // Cambio total de tempo como maximo un 6 % (LastWave estira una sola cancion hasta ese 6 %): como aqui se reparte entre
    // las dos, cada una cambia como mucho un 3 %. Mas que eso, el estirado de las voces se nota.
    private static let ratioMin = 0.94
    private static let ratioMax = 1.06
    private static let speedStep = 0.005
    static let tempoMatching = true
    /// A partir de que punto de la mezcla la entrante vuelve a su velocidad normal (la saliente ya casi no se oye).
    static let incomingRampStart = 0.75

    /// Lentas -> mezcla algo mas larga; rapidas -> mas corta (BPM 70 = 14 s, BPM 170 = 9 s). Apple Music mezcla en unos
    /// 8-12 s; las de 30 s de SimpMusic se hacian eternas.
    private static func baseTargetMs(bpm: Double) -> Double {
        let clamped = min(max(bpm, 70), 170)
        return 14_000 - (clamped - 70) * 50
    }

    static func durationMs(outgoing: TrackStructure, incoming: TrackStructure) -> Int64 {
        let beatMs = 60_000 / outgoing.bpm
        // Un salto grande de tempo pide una mezcla mas larga. Mitad y doble de tempo cuentan como iguales.
        var ratio = incoming.bpm / outgoing.bpm
        while ratio > 1.5 { ratio /= 2 }
        while ratio < 0.67 { ratio *= 2 }
        let gapFactor = min(1 + abs(1 - ratio) * bpmGapScale, 1.3)
        let target = baseTargetMs(bpm: outgoing.bpm) * gapFactor
        let beats = beatCountOptions.min(by: { abs($0 * beatMs - target) < abs($1 * beatMs - target) }) ?? 32
        let duration = min(max(beats * beatMs, minDurationMs), maxDurationMs)
        return Int64(duration)
    }

    /// Relacion de tempos de las dos canciones llevada a un entorno de 1 (la mitad o el doble de tempo cuentan como iguales).
    static func foldedRatio(outgoingBpm: Double, incomingBpm: Double) -> Double {
        var ratio = incomingBpm / outgoingBpm
        while ratio > 1.5 { ratio /= 2 }
        while ratio < 0.67 { ratio *= 2 }
        return ratio
    }

    /// Cuanto hay que acelerar (o frenar) la saliente para igualar el tempo de la entrante; 1 si la diferencia es
    /// demasiado grande. Es el cambio total: cada cancion toma la raiz.
    static func speedRatio(outgoingBpm: Double, incomingBpm: Double) -> Double {
        // Fase 1 de la mezcla encadenada en mpv: el archivo de la mezcla se prepara por adelantado y aun no tiene un
        // estirado de tempo propio, asi que no se iguala el tempo (solo filtros, graves y volumen).
        guard tempoMatching else { return 1 }
        var ratio = incomingBpm / outgoingBpm
        while ratio > 1.5 { ratio /= 2 }
        while ratio < 0.67 { ratio *= 2 }
        guard ratio >= ratioMin, ratio <= ratioMax else { return 1 }
        return quantized(ratio)
    }

    static func quantized(_ value: Double) -> Double {
        (value / speedStep).rounded() * speedStep
    }

    /// Rampa suave (3t^2 - 2t^3) que llega a su valor en `rampPortion` de la mezcla.
    static func rampProgress(_ progress: Double) -> Double {
        let linear = min(progress / TransitionPlanner.rampPortion, 1)
        return linear * linear * (3 - 2 * linear)
    }

    /// Velocidad de la saliente en un punto de la mezcla (0...1).
    static func outgoingRate(ratio: Double, progress: Double) -> Double {
        1 + (ratio - 1) * rampProgress(progress)
    }

    /// Velocidad de la entrante: la inicial hasta el 75 % de la mezcla y despues vuelve suavemente a 1 (cuando la saliente
    /// ya casi no se oye), para que mpv la tome a velocidad normal sin que se note.
    static func incomingRate(startRatio: Double, progress: Double) -> Double {
        guard progress > incomingRampStart else { return startRatio }
        let t = min((progress - incomingRampStart) / (1 - incomingRampStart), 1)
        return startRatio + (1 - startRatio) * t * t * (3 - 2 * t)
    }

    /// Segundos de la saliente (en su propia cancion) que se recorren en `seconds` de mezcla de `duration` s, con la rampa de
    /// velocidad.
    static func outgoingAdvance(ratio: Double, duration: Double, seconds: Double? = nil) -> Double {
        let limit = min(max(seconds ?? duration, 0), duration)
        let steps = 400
        var total = 0.0
        for k in 0..<steps {
            let t = (Double(k) + 0.5) / Double(steps) * limit
            total += outgoingRate(ratio: ratio, progress: t / duration) * limit / Double(steps)
        }
        return total
    }

    /// Lo mismo para la entrante.
    static func incomingAdvance(startRatio: Double, duration: Double) -> Double {
        let steps = 400
        var total = 0.0
        for k in 0..<steps {
            let progress = (Double(k) + 0.5) / Double(steps)
            total += incomingRate(startRatio: startRatio, progress: progress) * duration / Double(steps)
        }
        return total
    }

    /// Segundos de la entrante (en su propia cancion) que se recorren durante la mezcla, con sus cambios de velocidad.
    static func incomingAdvanceMs(durationMs: Int64, startRatio: Double) -> Int64 {
        let steps = 200
        var total = 0.0
        for k in 0..<steps {
            total += incomingRate(startRatio: startRatio, progress: (Double(k) + 0.5) / Double(steps)) / Double(steps)
        }
        return Int64(Double(durationMs) * total)
    }
}
