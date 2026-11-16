//
//  DJSpeech.swift
//  Trop
//
//  La voz del DJ: sintesis de voz del sistema (AVSpeechSynthesizer), gratis y sin conexion. La calidad depende de la voz que tenga
//  el movil: las "Mejorada" y "Premium" (Ajustes > Accesibilidad > Contenido hablado > Voces) suenan bastante mejor que la basica.
//  La voz se elige por su identificador (en iOS 26 la que se elige en Ajustes a veces no se respeta).
//

import AVFoundation
import Foundation

@MainActor
final class DJSpeech {
    static let shared = DJSpeech()

    struct VoiceInfo: Identifiable, Hashable {
        let id: String
        let name: String
        let language: String
        let quality: String
        let rank: Int
    }

    private var synthesizer = AVSpeechSynthesizer()
    /// Si el sintetizador usa la sesion de audio de la app (lo normal) o la suya. Si con una no se oye, se prueba la otra.
    private var usesAppSession = true

    private init() {}

    /// Las voces en español del movil, las de mejor calidad primero.
    static func spanishVoices() -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("es") }
            .map { voice -> VoiceInfo in
                let (label, rank) = describe(voice.quality)
                return VoiceInfo(id: voice.identifier, name: voice.name, language: voice.language, quality: label, rank: rank)
            }
            .sorted { lhs, rhs in
                lhs.rank != rhs.rank ? lhs.rank > rhs.rank : lhs.name < rhs.name
            }
    }

    private static func describe(_ quality: AVSpeechSynthesisVoiceQuality) -> (String, Int) {
        switch quality {
        case .premium: return ("Premium", 3)
        case .enhanced: return ("Enhanced", 2)
        default: return ("Standard", 1)
        }
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// La voz elegida; si no esta (p. ej. una Premium a medio descargar devuelve `nil`), la mejor en español que haya.
    private func resolveVoice(_ voiceId: String) -> AVSpeechSynthesisVoice? {
        if !voiceId.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
            PlaybackReport.record("dj: voz \(voice.name) (\(Self.describe(voice.quality).0))")
            return voice
        }
        if !voiceId.isEmpty {
            PlaybackReport.record("dj: la voz elegida (\(voiceId)) no esta disponible; se usa otra en español")
        }
        if let best = Self.spanishVoices().first, let voice = AVSpeechSynthesisVoice(identifier: best.id) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: "es-ES")
    }

    /// Estado de la sesion de audio, para el informe: cuando no se oye nada, esto dice si el movil lo tenia callado o desviado.
    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        var activation = "ok"
        do {
            try session.setActive(true)
        } catch {
            activation = "fallo: \(error)"
        }
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        PlaybackReport.record(
            "dj: audio: categoria \(session.category.rawValue), activar \(activation), otro audio sonando \(session.isOtherAudioPlaying),"
                + " salida [\(outputs)], volumen del sistema \(String(format: "%.2f", session.outputVolume))"
        )
    }

    /// Dice el texto y no vuelve hasta que termina (o hasta que se cancela la tarea, que corta la voz).
    /// Si en 2 s no ha empezado a sonar, se rehace el sintetizador cambiando de sesion de audio y se reintenta una vez.
    func speak(_ text: String, voiceId: String) async {
        stop()
        activateSession()
        let voice = resolveVoice(voiceId)
        for attempt in 1...2 {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.volume = 1
            synthesizer.usesApplicationAudioSession = usesAppSession
            synthesizer.speak(utterance)

            // `speak` es asincrono: hasta 2 s para que empiece.
            var started = false
            var waited = 0
            while waited < 20 {
                if synthesizer.isSpeaking { started = true; break }
                if Task.isCancelled {
                    stop()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            if started {
                PlaybackReport.record("dj: la voz empezo en \(waited * 100) ms (intento \(attempt), sesion de la app: \(usesAppSession))")
                while synthesizer.isSpeaking || synthesizer.isPaused {
                    if Task.isCancelled {
                        stop()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                return
            }
            PlaybackReport.record("dj: la voz NO empezo en 2 s (intento \(attempt), sesion de la app: \(usesAppSession))")
            synthesizer.stopSpeaking(at: .immediate)
            synthesizer = AVSpeechSynthesizer()
            usesAppSession.toggle()
            activateSession()
        }
    }
}
