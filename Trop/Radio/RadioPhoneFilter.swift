//
//  RadioPhoneFilter.swift
//  Trop
//
//  El filtro de "audio de WhatsApp" de la nota de voz del oyente: sin graves ni agudos (el micro y el codec de un movil), compresion y un limite suave. Probado en el PC
//  (speechify-prueba\whatsapp-prueba.py): con eso la nota deja de sonar a estudio y suena a un audio de verdad. Sin ruido ni codec (no se notaba la diferencia).
//

import Foundation

enum RadioPhoneFilter {
    /// El mismo clip pasado por el filtro; si no se pueden leer las muestras, el clip tal cual.
    static func apply(_ clip: RadioClip) -> RadioClip {
        guard let parsed = RadioAudio.samples(from: clip.wav), parsed.rate > 0, !parsed.samples.isEmpty else { return clip }
        let rate = Double(parsed.rate)
        var highpass = Biquad.make(.highpass, frequency: 150, rate: rate)
        var lowpass = Biquad.make(.lowpass, frequency: 5200, rate: rate)

        // Compresor: umbral -24 dB, relacion 3,5:1, ataque 4 ms, suelta 90 ms, 4 dB de ganancia de compensacion.
        let attack = exp(-1.0 / (0.004 * rate))
        let release = exp(-1.0 / (0.090 * rate))
        let threshold = -24.0
        let ratio = 3.5
        let makeup = 4.0
        var envelope = 0.0

        var output: [Int16] = []
        output.reserveCapacity(parsed.samples.count)
        for sample in parsed.samples {
            var value = Double(sample) / 32768
            value = lowpass.process(highpass.process(value))
            let level = abs(value)
            envelope = level > envelope ? attack * envelope + (1 - attack) * level : release * envelope + (1 - release) * level
            let decibels = 20 * log10(max(envelope, 1e-5))
            let over = decibels - threshold
            let gain = over > 0 ? -over * (1 - 1 / ratio) + makeup : makeup
            value *= pow(10, gain / 20)
            // Limite suave en 0,92.
            value = 0.92 * tanh(value / 0.92)
            output.append(Int16(max(-1, min(1, value)) * 32767))
        }
        return RadioClip(wav: RadioAudio.wav(output, rate: parsed.rate), seconds: clip.seconds, needsBoost: clip.needsBoost, label: clip.label)
    }
}

/// Un filtro de segundo orden (formulas de Robert Bristow-Johnson), de paso alto o bajo con Q = 0,707.
private struct Biquad {
    enum Kind { case lowpass, highpass }

    var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    static func make(_ kind: Kind, frequency: Double, rate: Double) -> Biquad {
        let w0 = 2 * Double.pi * min(frequency, rate / 2 - 1) / rate
        let alpha = sin(w0) / (2 * 0.7071)
        let cosine = cos(w0)
        var filter = Biquad()
        let a0 = 1 + alpha
        switch kind {
        case .lowpass:
            filter.b0 = (1 - cosine) / 2 / a0
            filter.b1 = (1 - cosine) / a0
            filter.b2 = (1 - cosine) / 2 / a0
        case .highpass:
            filter.b0 = (1 + cosine) / 2 / a0
            filter.b1 = -(1 + cosine) / a0
            filter.b2 = (1 + cosine) / 2 / a0
        }
        filter.a1 = -2 * cosine / a0
        filter.a2 = (1 - alpha) / a0
        return filter
    }

    mutating func process(_ input: Double) -> Double {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }
}
