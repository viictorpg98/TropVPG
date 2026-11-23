//
//  RadioCast.swift
//  Trop
//
//  El reparto de la radio mas alla de los dos locutores: los TONOS que puede llevar cada frase (se pide un tono por frase y el modelo de voz lo interpreta) y los
//  OYENTES INVENTADOS que mandan notas de voz al WhatsApp de la emisora. Los oyentes son personajes de ficcion con voces de la biblioteca de Google (no son
//  la voz de nadie real ni la tuya); sus mensajes se escriben a partir de la cancion que viene, nunca de datos de personas.
//

import Foundation

enum RadioTone {
    /// Clave que escribe el modelo de texto -> indicacion de estilo para el modelo de voz (en ingles, como lo entiende mejor).
    static let styles: [String: String] = [
        "susurro": "whispering conspiratorially, low and close to the microphone",
        "grito": "shouting excitedly, loud and full of energy",
        "sarcasmo": "dry, deadpan sarcasm",
        "cansado": "tired and low on energy, almost yawning",
        "emocionado": "thrilled, fast and bubbly, can't contain the excitement",
        "tierno": "warm, soft and affectionate",
        "incredulo": "disbelieving, flabbergasted, laughing in shock",
        // Tonos de locutor de radio para el dia a dia (el mas natural en cada momento).
        "animado": "upbeat, friendly radio host energy, natural and relaxed, not over the top",
        "calido": "warm, relaxed and conversational, like chatting with a friend in the studio",
        "tranquilo": "calm, easygoing and mellow, unhurried",
        "complice": "playful and conspiratorial, sharing a joke with the listener",
        "burlon": "teasing and mischievous, with a smile in the voice",
        "serio": "straight and sober, like reading the news"
    ]

    static var names: String {
        styles.keys.sorted().joined(separator: ", ")
    }

    /// Solo se aceptan los tonos de la lista (cualquier otra cosa que invente el modelo se ignora).
    static func clean(_ raw: Any?) -> String? {
        guard let text = (raw as? String)?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let folded = text.folding(options: .diacriticInsensitive, locale: nil)
        return styles[folded] != nil ? folded : nil
    }
}

struct RadioGuest {
    let name: String
    /// Voz de la biblioteca de Google (es-ES).
    let voice: String
    /// Como se la presenta al modelo de texto (edad y pueblo), para que lo que dice suene a ella.
    let profile: String
}

enum RadioGuests {
    static let all: [RadioGuest] = [
        RadioGuest(name: "Marta", voice: "es-es-concierge-3", profile: "Marta, 24 años, de Terrassa"),
        RadioGuest(name: "Dani", voice: "es-es-training-9", profile: "Dani, 23 años, de Sabadell"),
        RadioGuest(name: "Irene", voice: "es-es-techagent-5", profile: "Irene, 29 años, de Mataró"),
        RadioGuest(name: "Montse", voice: "es-es-csagent-6", profile: "Montse, 56 años, de Badalona"),
        RadioGuest(name: "Paco", voice: "es-es-assistant-3", profile: "Paco, 59 años, de Cerdanyola")
    ]

    /// Como suena una nota de voz de un oyente (se pasa como estilo al modelo de voz).
    static let style = "a regular radio listener leaving a friendly, casual voice note on their phone"

    static func guest(named name: String) -> RadioGuest? {
        all.first { $0.name == name }
    }
}
