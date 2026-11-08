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
    /// Velocidad a la que llega la saliente al final de la rampa (1 = sin cambio).
    var outgoingSpeedRatio: Double

    /// El mismo plan para una mezcla que empieza con la saliente ya `outgoingPositionMs` dentro: mantiene el
    /// final en su sitio empezando la entrante mas tarde y acortando la mezcla. `nil` si queda menos de un
    /// segundo o la posicion no esta cerca de la ventana.
    func startingAt(outgoingPositionMs: Int64) -> TransitionPlan? {
        if outgoingPositionMs < outgoingStartMs - 1_000 { return nil }
        let late = max(outgoingPositionMs - outgoingStartMs, 0)
        if durationMs - late < 1_000 { return nil }
        var copy = self
        copy.outgoingStartMs += late
        copy.durationMs -= late
        copy.incomingStartMs += late
        return copy
    }
}

enum TransitionPlanner {
    /// Parte de la mezcla en que la saliente llega a su velocidad final (suavizado), y luego la mantiene.
    static let rampPortion = 0.6

    /// Una mezcla entre dos canciones ya analizadas, con los puntos ajustados a compases. `nil` si no se puede
    /// mezclar bien (cancion saliente demasiado corta, datos raros...).
    static func plan(outgoing: TrackStructure, incoming: TrackStructure) -> TransitionPlan? {
        guard outgoing.beatMs > 0, outgoing.bpm > 0, incoming.bpm > 0 else { return nil }
        let ratio = AutoMixMath.speedRatio(outgoingBpm: outgoing.bpm, incomingBpm: incoming.bpm)
        let durationMs = AutoMixMath.durationMs(outgoing: outgoing, incoming: incoming)

        let end = outgoing.lastChorusEndMs ?? outgoing.musicEndMs
        // La saliente recorre mas (o menos) de su propia linea de tiempo de lo que dura la mezcla, porque
        // cambia de velocidad: media a mitad de rampa y luego la mantiene.
        let advance = Double(durationMs) * (1 + (ratio - 1) * (1 - rampPortion / 2))
        var start = Int64(Double(end) - advance)
        if start <= outgoing.firstSoundMs { return nil }

        // Se empieza en el inicio de compas de la saliente inmediatamente anterior, para que la mezcla quede
        // dentro de la ventana.
        if let bar = outgoing.downbeatsMs.last(where: { $0 <= start }), start - bar < Int64(outgoing.beatMs * 4) {
            start = bar
        }
        if start <= outgoing.firstSoundMs { return nil }

        // La entrante entra por el inicio de compas mas cercano al punto donde su intro acabaria con la mezcla.
        var incomingStart: Int64 = 0
        if let introEnd = incoming.introEndMs {
            incomingStart = max(introEnd - durationMs, 0)
        } else {
            incomingStart = incoming.firstSoundMs
        }
        if let bar = incoming.downbeatsMs.min(by: { abs($0 - incomingStart) < abs($1 - incomingStart) }),
           abs(bar - incomingStart) < Int64(incoming.beatMs * 4) {
            incomingStart = bar
        }
        incomingStart = max(incomingStart + beatPhaseShift(outgoing: outgoing, incoming: incoming,
                                                           durationMs: durationMs, ratio: ratio), 0)
        return TransitionPlan(
            outgoingStartMs: start,
            outgoingEndMs: end,
            durationMs: durationMs,
            incomingStartMs: incomingStart,
            outgoingSpeedRatio: ratio
        )
    }
}

extension TransitionPlanner {
    /// Cuanto hay que mover el punto de entrada de la entrante para que sus pulsos caigan sobre los de la saliente
    /// cuando esta termina de igualar su tempo. La saliente avanza mas (o menos) que la mezcla durante la rampa de
    /// velocidad, y esa diferencia descuadra los pulsos aunque los dos tempos acaben iguales.
    /// 0 si los tempos no quedan iguales (entonces no hay pulsos que casar).
    static func beatPhaseShift(outgoing: TrackStructure, incoming: TrackStructure, durationMs: Int64, ratio: Double) -> Int64 {
        // Periodo del pulso de la saliente ya acelerada/frenada. Debe ser el de la entrante, o el doble/la mitad.
        let matched = outgoing.beatMs / ratio
        let octaves = log2(matched / incoming.beatMs)
        guard abs(octaves - octaves.rounded()) < 0.05, abs(octaves) <= 1.05 else { return 0 }
        let modulus = max(matched, incoming.beatMs)
        // Tiempo (de la mezcla) en que la saliente llega a su velocidad final, y lo que ha avanzado de su cancion.
        let rampMs = Double(durationMs) * rampPortion
        let outgoingAdvanced = rampMs * (1 + (ratio - 1) / 2)
        // La entrante, que avanza al ritmo normal, debe estar en la misma fase del pulso en ese momento.
        var shift = outgoingAdvanced / ratio - rampMs
        shift -= modulus * (shift / modulus).rounded()
        return Int64(shift)
    }
}

enum AutoMixMath {
    // Duracion: los extremos de SimpMusic (20-45 s) se acortan: aqui 12-32 s, mas cerca de lo que se oye en
    // Apple Music. Sin tonalidad (no tenemos metadatos de Tidal) no hay factor de tonalidad.
    private static let minDurationMs = 8_000.0
    private static let maxDurationMs = 16_000.0
    private static let beatCountOptions: [Double] = [8, 12, 16, 24, 32]
    private static let bpmGapScale = 2.0
    /// Solo se cambia la velocidad si hace falta poco (SimpMusic permite 0,75-1,25; aqui menos para que suene natural).
    private static let ratioMin = 0.80
    private static let ratioMax = 1.25
    private static let speedStep = 0.01

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

    /// Velocidad a la que la saliente iguala el tempo de la entrante; 1 si la diferencia es demasiado grande.
    static func speedRatio(outgoingBpm: Double, incomingBpm: Double) -> Double {
        var ratio = incomingBpm / outgoingBpm
        while ratio > 1.5 { ratio /= 2 }
        while ratio < 0.67 { ratio *= 2 }
        guard ratio >= ratioMin, ratio <= ratioMax else { return 1 }
        return (ratio / speedStep).rounded() * speedStep
    }

    /// Rampa suave (3t^2 - 2t^3) que llega a su valor en `rampPortion` de la mezcla.
    static func rampProgress(_ progress: Double) -> Double {
        let linear = min(progress / TransitionPlanner.rampPortion, 1)
        return linear * linear * (3 - 2 * linear)
    }
}
