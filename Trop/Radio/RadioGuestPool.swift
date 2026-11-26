//
//  RadioGuestPool.swift
//  Trop
//
//  Los OYENTES de la seccion de WhatsApp como personas distintas. Las voces de la biblioteca de Google suenan a centralita; las diseñadas con texto ("Voice Design",
//  POST /v1beta/voices) tienen caracter y se pueden crear desde la app. Aqui se guarda un BANCO de voces (hasta 24) con la persona de cada una (nombre, edad, pueblo,
//  como habla): cada seccion de WhatsApp coge una al azar y el texto de la nota se escribe para esa persona. Crear una voz tarda 15-20 s, asi que se hace en segundo
//  plano despues de cada seccion (o con el boton de Ajustes); con el banco lleno, de vez en cuando se crea una nueva y se borra la mas antigua. Sin banco (o con pocas
//  voces), salen los 5 oyentes de siempre.
//

import Foundation

/// Un oyente con voz propia creada con la API.
struct PooledGuest: Codable, Hashable {
    let voice: String
    let name: String
    /// "female" o "male".
    let gender: String
    let age: Int
    let town: String
    /// Como habla (castellano), para que el texto de la nota suene a el o a ella.
    let trait: String
    let created: Date
    var lastUsed: Date?
}

enum RadioGuestPool {
    private static let key = "radio.guestVoices.v1"
    /// Voces que se mantienen y maximo que se guarda (el cupo de Google es de 200 por proyecto).
    static let target = 24
    /// Con menos voces que esto se siguen usando los oyentes de siempre (la misma voz una y otra vez no es "una persona distinta").
    static let minimumToUse = 4
    nonisolated(unsafe) private static var creating = false

    /// El estilo de cada frase: lo permanente (edad, acento, timbre) va en la descripcion de la voz; aqui solo la situacion.
    private static let turnStyle = "recording a quick WhatsApp voice message on the phone, casual and natural"

    // MARK: - El banco

    static var all: [PooledGuest] {
        guard let data = UserDefaults.standard.data(forKey: key), let list = try? JSONDecoder().decode([PooledGuest].self, from: data) else { return [] }
        return list
    }

    private static func save(_ list: [PooledGuest]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func guest(from pooled: PooledGuest) -> RadioGuest {
        RadioGuest(
            name: pooled.name, voice: pooled.voice,
            profile: "\(pooled.name), \(pooled.age) años, de \(pooled.town); \(pooled.trait)", style: turnStyle
        )
    }

    /// El oyente de una nota que ya se esta diciendo (para buscar su voz por el nombre).
    static func guest(named name: String) -> RadioGuest? {
        all.first { $0.name == name }.map(guest(from:))
    }

    /// El oyente de esta seccion: uno del banco (de los menos usados) o, si el banco aun es pequeño, uno de los de siempre.
    static func pick() -> RadioGuest {
        var list = all
        guard list.count >= minimumToUse else { return RadioGuests.usual() }
        list.sort { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        guard let chosen = list.prefix(max(1, list.count / 2)).randomElement() else { return RadioGuests.usual() }
        var stored = all
        if let index = stored.firstIndex(where: { $0.voice == chosen.voice }) {
            stored[index].lastUsed = Date()
            save(stored)
        }
        return guest(from: chosen)
    }

    // MARK: - Crear voces

    private static let femaleNames = [
        "Laia", "Núria", "Carla", "Aina", "Júlia", "Sílvia", "Rosa", "Marina", "Cristina", "Anna", "Judit", "Nerea", "Berta", "Alba", "Elena", "Gemma", "Lucía", "Ona"
    ]
    private static let maleNames = [
        "Pau", "Marc", "Jordi", "Arnau", "Pol", "Oriol", "Xavi", "Joan", "Manel", "Albert", "Iván", "Toni", "Sergi", "Àlex", "Roger", "Víctor", "Ferran", "Raúl"
    ]

    /// Como habla: en ingles (para la descripcion de la voz) y en castellano (para el texto de la nota).
    private static let traits: [(en: String, es: String)] = [
        ("Fast and a little breathless, laughs easily.", "habla muy rapido, un poco sin aliento, se rie por todo"),
        ("Relaxed, lazy delivery, mumbles slightly, drawn-out filler words.", "habla despacio y arrastrando las palabras, medio dormido"),
        ("Energetic and chatty, with a smile in the voice.", "muy hablador y animado, con la risa en la voz"),
        ("Shy and a little awkward when recording a voice message.", "algo timido, se nota que no le gusta grabar audios"),
        ("Dry, sarcastic sense of humor, deadpan delivery.", "ironico y seco, suelta las cosas con cara de poker"),
        ("Warm and gentle, speaks patiently.", "carinoso y tranquilo, habla con paciencia"),
        ("Tired after a long day, sighs between sentences.", "cansado de un dia largo, suspira entre frases"),
        ("Excited and a bit scatterbrained, jumps from one idea to another.", "emocionado y disperso, salta de una idea a otra"),
        ("Confident, sounds like someone who always has the last word.", "seguro de si mismo, de los que siempre tienen la ultima palabra"),
        ("Nervous, speaks fast and repeats himself.", "nervioso, habla deprisa y se repite")
    ]

    /// El acento de la zona de la emisora, para la descripcion de la voz.
    private static var accent: String {
        switch RadioLocal.cityName {
        case "Sabadell", "Barcelona": return "a light Catalan accent"
        case "Valencia": return "a light Valencian accent"
        case "Palma": return "a light Majorcan accent"
        case "Sevilla", "Málaga": return "an Andalusian accent"
        case "Bilbao": return "a light Basque accent"
        default: return "the everyday accent of the area"
        }
    }

    /// Crea UNA voz con una persona al azar (si Google rechaza la descripcion por seguridad, se reintenta con una mas simple). `nil` si no se pudo.
    private static func createOne() async -> PooledGuest? {
        let taken = Set(all.map(\.name))
        let female = Bool.random()
        let pool = female ? femaleNames : maleNames
        guard let name = pool.filter({ !taken.contains($0) }).randomElement() ?? pool.randomElement() else { return nil }
        let age = Int.random(in: 19...62)
        let town = RadioLocal.townList.randomElement() ?? RadioLocal.cityName
        guard let trait = traits.randomElement() else { return nil }
        let person = female ? "woman" : "man"
        let rich = "A \(age)-year-old \(person) from \(town), near \(RadioLocal.cityName). Peninsular Spanish with \(accent). \(trait.en) Sounds like someone recording a WhatsApp voice message to a friend, not like a presenter."
        let simple = "A \(age)-year-old \(person) from \(town). Natural, friendly Peninsular Spanish, casual voice message tone."
        let started = Date()
        var made: String?
        for description in [rich, simple] {
            do {
                made = try await Gemini.createVoice(description: description, gender: female ? "female" : "male", displayName: "oyente-\(name)")
                break
            } catch {
                PlaybackReport.record("radio: no se pudo crear la voz de \(name) (\(error.localizedDescription))")
                // Solo una descripcion rechazada por seguridad (400) merece el reintento mas simple.
                if let failure = error as? Gemini.Failure, failure.code != 400 { break }
            }
        }
        guard let voice = made else { return nil }
        PlaybackReport.record("radio: voz de oyente creada: \(name), \(age) años, \(town) (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
        return PooledGuest(voice: voice, name: name, gender: female ? "female" : "male", age: age, town: town, trait: trait.es, created: Date(), lastUsed: nil)
    }

    private static func add(_ guest: PooledGuest) async {
        var list = all + [guest]
        if list.count > target {
            list.sort { ($0.lastUsed ?? $0.created) < ($1.lastUsed ?? $1.created) }
            let oldest = list.removeFirst()
            await Gemini.deleteVoice(oldest.voice)
            PlaybackReport.record("radio: voz de oyente borrada: \(oldest.name) (la mas antigua)")
        }
        save(list)
    }

    /// Despues de cada seccion: con el banco por llenar se crea una voz; con el banco lleno, de vez en cuando (1 de cada 4) se renueva una. En segundo plano.
    static func replenish() async {
        guard !creating, !RadioSettings.apiKey.isEmpty, !RadioSettings.capReached else { return }
        if all.count >= target, Int.random(in: 0..<4) != 0 { return }
        creating = true
        defer { creating = false }
        if let made = await createOne() { await add(made) }
    }

    /// El boton de Ajustes: crea `count` voces seguidas. Devuelve cuantas salieron.
    static func prepare(count: Int) async -> Int {
        guard !creating, !RadioSettings.apiKey.isEmpty else { return 0 }
        creating = true
        defer { creating = false }
        var made = 0
        for _ in 0..<count {
            guard let guest = await createOne() else { break }
            await add(guest)
            made += 1
        }
        return made
    }
}
