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

    private let synthesizer = AVSpeechSynthesizer()

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

    /// Dice el texto y no vuelve hasta que termina (o hasta que se cancela la tarea, que corta la voz).
    func speak(_ text: String, voiceId: String) async {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceId) ?? AVSpeechSynthesisVoice(language: "es-ES")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1
        synthesizer.speak(utterance)

        // `speak` es asincrono: hasta 2 s para que empiece, y luego hasta que acabe.
        var waited = 0
        while !synthesizer.isSpeaking, waited < 20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        while synthesizer.isSpeaking || synthesizer.isPaused {
            if Task.isCancelled {
                stop()
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
