//
//  RadioVoice.swift
//  Trop
//
//  Audio de las frases de la radio con cache en el movil: el mismo texto, con las mismas voces y el mismo modelo, no se vuelve a generar. Las frases
//  fijas (preguntas, rellenos, cuñas) se guardan sin caducidad.
//

import Foundation

enum RadioVoice {
    /// El audio de unos turnos: de la cache o generado ahora (`nil` si no se puede: sin clave, sin red, tope de gasto...).
    static func clip(_ turns: [RadioTurn], style: String? = nil, fixed: Bool = false, timeout: Double = 15) async -> RadioClip? {
        await attempt(turns, style: style, fixed: fixed, timeout: timeout).clip
    }

    /// Lo mismo, pero diciendo tambien si Google se ha negado a decirlo (`blocked`): quien lo llama puede reescribir el texto mas suave.
    static func attempt(_ turns: [RadioTurn], style: String? = nil, fixed: Bool = false, timeout: Double = 15) async -> (clip: RadioClip?, blocked: Bool) {
        guard !turns.isEmpty else { return (nil, false) }
        let key = cacheKey(turns, style: style)
        if let cached = RadioAudio.cached(key: key, fixed: fixed) { return (cached, false) }
        do {
            let generated: RadioClip
            do {
                generated = try await Gemini.speech(turns, style: style, timeout: timeout)
            } catch let failure as Gemini.Failure where failure.code == -1 {
                // Sin respuesta (el tiempo se agoto o se corto la red un instante): una pieza perdida es una peticion de voz tirada, asi que se reintenta una vez.
                PlaybackReport.record("radio: voz sin respuesta; se reintenta una vez")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                generated = try await Gemini.speech(turns, style: style, timeout: timeout)
            }
            RadioAudio.store(generated, key: key, fixed: fixed)
            return (generated, false)
        } catch {
            PlaybackReport.record("radio: voz fallo (\(error.localizedDescription))")
            return (nil, (error as? Gemini.Failure)?.isBlocked ?? false)
        }
    }

    /// Solo lo que ya esta guardado (para no esperar red en el momento).
    static func cachedClip(_ turns: [RadioTurn], style: String? = nil, fixed: Bool = false) -> RadioClip? {
        RadioAudio.cached(key: cacheKey(turns, style: style), fixed: fixed)
    }

    /// Las frases sin tono (las fijas) dan la misma clave de siempre, asi las ya guardadas siguen valiendo; con tono, el tono forma parte de la clave.
    private static func cacheKey(_ turns: [RadioTurn], style: String?) -> String {
        let lines = turns.map { turn in
            "\(turn.speaker):\(turn.text)" + (turn.tone.map { "~\($0)" } ?? "")
        }.joined(separator: "|")
        return [RadioSettings.voiceModel, RadioSettings.pitirreVoice, RadioSettings.chuletaVoice, style ?? "", lines].joined(separator: "#")
    }
}
