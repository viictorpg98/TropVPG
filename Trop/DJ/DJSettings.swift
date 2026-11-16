//
//  DJSettings.swift
//  Trop
//
//  Ajustes del DJ (el locutor que presenta las canciones). La sesion de DJ (encendido/apagado) NO se guarda: empieza apagada cada
//  vez que se abre la app y se enciende desde el reproductor, el menu de la cola o el Inicio. Lo demas se guarda aparte de
//  `SettingsStore`.
//

import Foundation
import Observation

@MainActor
@Observable
final class DJSettings {
    static let shared = DJSettings()

    private static let everyKey = "dj.everySongs"
    private static let voiceKey = "dj.voiceId"
    private static let modelKey = "dj.useLanguageModel"

    /// Hay una sesion de DJ en marcha (no se guarda: al abrir la app empieza apagada). Lo cambia `DJHost`.
    var sessionActive = false

    /// El DJ esta hablando ahora mismo (el boton del reproductor se anima mientras tanto). Lo cambia `DJHost`.
    var speaking = false

    /// Habla cada tantas canciones (la primera tras activarlo siempre).
    var everySongs: Int {
        didSet { UserDefaults.standard.set(everySongs, forKey: Self.everyKey) }
    }

    /// Identificador de la voz del sistema; vacio = la que el sistema da por defecto para español.
    var voiceId: String {
        didSet { UserDefaults.standard.set(voiceId, forKey: Self.voiceKey) }
    }

    /// Escribir las presentaciones con el modelo del iPhone (Apple Intelligence) cuando se pueda; si no, frases hechas.
    var useLanguageModel: Bool {
        didSet { UserDefaults.standard.set(useLanguageModel, forKey: Self.modelKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        let every = defaults.integer(forKey: Self.everyKey)
        everySongs = every > 0 ? every : 3
        voiceId = defaults.string(forKey: Self.voiceKey) ?? ""
        useLanguageModel = defaults.object(forKey: Self.modelKey) == nil ? true : defaults.bool(forKey: Self.modelKey)
    }
}
