//
//  RadioSettings.swift
//  Trop
//
//  Ajustes de la radio (Sónar FM): clave de Gemini (en el llavero del movil, nunca en el repositorio), si esta activada, cada cuantas canciones hablan,
//  el tope de gasto diario y el gasto estimado de hoy. Los modelos y las voces se pueden cambiar (por si Google los renombra).
//

import Foundation
import Security

enum RadioSettings {
    static let enabledKey = "radio.enabled"
    static let talkEveryKey = "radio.talkEvery"
    static let rhythmKey = "radio.rhythm"
    static let humorKey = "radio.humor"
    static let sportsKey = "radio.sports"
    static let sectionsOffKey = "radio.sectionsOff"
    static let defaultSports = "FC Barcelona, pádel, fútbol sala"
    static let dailyCapKey = "radio.dailyCap"
    static let voiceGainKey = "radio.voiceGain"
    static let duckKey = "radio.duckLevel"
    static let memoryKey = "radio.memory"
    static let fallbackKey = "radio.voiceFallback"
    static let fallbackModelKey = "radio.voiceFallbackModel"
    private static let voiceCountKey = "radio.voiceCount.v1"
    static let sectionsKey = "radio.sections"
    static let cityKey = "radio.city"
    static let textModelKey = "radio.textModel"
    static let humorModelKey = "radio.humorModel"
    static let voiceModelKey = "radio.voiceModel"
    static let pitirreVoiceKey = "radio.voice.pitirre"
    static let chuletaVoiceKey = "radio.voice.chuleta"
    private static let statusKey = "radio.status"
    private static let spendKey = "radio.spend.v1"
    private static let keyService = "sonar.radio"
    private static let keyFallbackKey = "radio.key.fallback"

    static let defaultTextModel = "gemini-3.1-flash-lite"
    /// El modelo que escribe las charlas y las secciones con humor picante o negro: mucho mas gracioso que el barato (probado en el PC) y unas 3 veces mas caro.
    static let defaultHumorModel = "gemini-3.8-flash"
    static let defaultVoiceModel = "gemini-3.8-flash-lite-tts"
    /// La voz de reserva (cuesta un 50 % mas por audio): se usa cuando el modelo barato llega a su limite.
    static let defaultFallbackModel = "gemini-3.8-flash-tts"
    /// Las dos voces diseñadas en el proyecto de Google del usuario (solo valen con su clave).
    static let defaultPitirreVoice = "voice_8d1n4bt63iki"
    static let defaultChuletaVoice = "voice_vs6u7blphdqv"

    // MARK: - Ajustes

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Hablan entre una de cada N canciones (1 a 5).
    static var talkEvery: Int {
        let saved = UserDefaults.standard.integer(forKey: talkEveryKey)
        return saved == 0 ? 2 : min(max(saved, 1), 5)
    }

    /// Que tan regular es el ritmo: 0 = exacto (siempre cada N), 1 = natural (pequeña variacion), 2 = imprevisible (mas variacion, con algun silencio).
    static var rhythm: Int {
        let saved = UserDefaults.standard.object(forKey: rhythmKey) as? Int ?? 0
        return min(max(saved, 0), 2)
    }

    /// El nivel de humor (ver `RadioHumor`): 0 = suave, 1 = picante (por defecto), 2 = negro.
    static var humor: Int {
        let saved = UserDefaults.standard.object(forKey: humorKey) as? Int ?? 1
        return min(max(saved, 0), 2)
    }

    /// Las secciones apagadas una a una (nombres separados por comas; vacio = todas encendidas).
    static func disabledSections(from raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Las secciones que pueden salir (todas menos las apagadas en Ajustes).
    static var enabledSections: [RadioSectionKind] {
        let off = disabledSections(from: UserDefaults.standard.string(forKey: sectionsOffKey) ?? "")
        return RadioSectionKind.allCases.filter { !off.contains($0.name) }
    }

    /// Los deportes y equipos del oyente (hasta 4, separados por comas) para la seccion de deportes.
    static var sportsTopics: [String] {
        let saved = UserDefaults.standard.string(forKey: sportsKey) ?? defaultSports
        let list = saved.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return Array(list.prefix(4))
    }

    /// Tope diario en euros; 0 = sin tope.
    static var dailyCap: Double {
        UserDefaults.standard.object(forKey: dailyCapKey) as? Double ?? 0.30
    }

    /// Cuanto se sube la voz (las de Gemini salen mucho mas bajas que las canciones).
    static var voiceGain: Double {
        let saved = UserDefaults.standard.object(forKey: voiceGainKey) as? Double ?? 2.6
        return min(max(saved, 1.0), 5.0)
    }

    /// Cuanto queda la musica mientras hay voz (0,45 = al 45 % del volumen); en las pausas entre frases sube hacia el 85 %.
    static var duckLevel: Double {
        let saved = UserDefaults.standard.object(forKey: duckKey) as? Double ?? 0.45
        return min(max(saved, 0.15), 0.8)
    }

    /// Si la radio recuerda entre dias (diario local + resumen a Gemini para las bromas con tus datos).
    static var memoryEnabled: Bool {
        UserDefaults.standard.object(forKey: memoryKey) as? Bool ?? true
    }

    /// Si hay secciones (noticiero, tiempo, anuncios, top 5, un dia como hoy, mensajes de oyentes, deportes) entre las canciones.
    static var sectionsEnabled: Bool {
        UserDefaults.standard.object(forKey: sectionsKey) as? Bool ?? true
    }

    struct City {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    /// Ciudades para el tiempo (sin GPS: se elige aqui).
    static let cities: [City] = [
        City(name: "Sabadell", latitude: 41.5463, longitude: 2.1086),
        City(name: "Barcelona", latitude: 41.3874, longitude: 2.1686),
        City(name: "Madrid", latitude: 40.4168, longitude: -3.7038),
        City(name: "Valencia", latitude: 39.4699, longitude: -0.3763),
        City(name: "Sevilla", latitude: 37.3891, longitude: -5.9845),
        City(name: "Bilbao", latitude: 43.2630, longitude: -2.9350),
        City(name: "Zaragoza", latitude: 41.6488, longitude: -0.8891),
        City(name: "Málaga", latitude: 36.7213, longitude: -4.4214),
        City(name: "Palma", latitude: 39.5696, longitude: 2.6502)
    ]

    static var city: City {
        let saved = UserDefaults.standard.string(forKey: cityKey) ?? "Sabadell"
        return cities.first { $0.name == saved } ?? cities[0]
    }

    /// Si al llegar al limite del modelo de voz se prueba con el de reserva (que tiene su propia cuota).
    static var fallbackEnabled: Bool {
        UserDefaults.standard.object(forKey: fallbackKey) as? Bool ?? true
    }

    static var fallbackModel: String { stored(fallbackModelKey, default: defaultFallbackModel) }

    static var textModel: String { stored(textModelKey, default: defaultTextModel) }
    static var humorModel: String { stored(humorModelKey, default: defaultHumorModel) }
    static var voiceModel: String { stored(voiceModelKey, default: defaultVoiceModel) }
    static var pitirreVoice: String { stored(pitirreVoiceKey, default: defaultPitirreVoice) }
    static var chuletaVoice: String { stored(chuletaVoiceKey, default: defaultChuletaVoice) }

    private static func stored(_ key: String, default value: String) -> String {
        let saved = (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.isEmpty ? value : saved
    }

    // MARK: - Clave (llavero)

    static var apiKey: String {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keyService,
                kSecAttrAccount as String: "gemini",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            let result = SecItemCopyMatching(query as CFDictionary, &item)
            if result == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                return text
            }
            return UserDefaults.standard.string(forKey: keyFallbackKey) ?? ""
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keyService,
                kSecAttrAccount as String: "gemini"
            ]
            SecItemDelete(base as CFDictionary)
            UserDefaults.standard.removeObject(forKey: keyFallbackKey)
            guard !trimmed.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(trimmed.utf8)
            // Legible con el movil bloqueado (la radio sigue generando frases con la pantalla apagada).
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            // Si el llavero no deja guardarla (algunas firmas de sideload), se guarda en los ajustes de la app.
            if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
                UserDefaults.standard.set(trimmed, forKey: keyFallbackKey)
            }
        }
    }

    static var isConfigured: Bool {
        enabled && !apiKey.isEmpty
    }

    // MARK: - Estado y gasto

    /// Lo ultimo que paso con Gemini (para enseñarlo en Ajustes).
    static var status: String {
        get { UserDefaults.standard.string(forKey: statusKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: statusKey) }
    }

    private static var dayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// Gasto estimado de hoy en euros (por lo que se genero desde esta app; no es lo que cobra Google exactamente).
    static var spentToday: Double {
        let saved = UserDefaults.standard.dictionary(forKey: spendKey)
        guard saved?["day"] as? String == dayString else { return 0 }
        return saved?["euros"] as? Double ?? 0
    }

    static func addSpend(_ euros: Double) {
        UserDefaults.standard.set(["day": dayString, "euros": spentToday + euros] as [String: Any], forKey: spendKey)
    }

    /// Peticiones de voz que ha hecho la app hoy (el limite diario de Google las cuenta desde las 9:00 de España, tambien las de las pruebas del PC).
    static var voiceRequestsToday: Int {
        let saved = UserDefaults.standard.dictionary(forKey: voiceCountKey)
        guard saved?["day"] as? String == dayString else { return 0 }
        return saved?["count"] as? Int ?? 0
    }

    static func addVoiceRequest() {
        UserDefaults.standard.set(["day": dayString, "count": voiceRequestsToday + 1] as [String: Any], forKey: voiceCountKey)
    }

    static var capReached: Bool {
        let cap = dailyCap
        return cap > 0 && spentToday >= cap
    }
}
