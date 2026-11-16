//
//  DJSettings.swift
//  Trop
//
//  Ajustes del DJ (el locutor que presenta las canciones): apagado por defecto. Se guardan aparte de `SettingsStore`.
//

import Foundation
import Observation

@MainActor
@Observable
final class DJSettings {
    static let shared = DJSettings()

    private static let enabledKey = "dj.enabled"
    private static let everyKey = "dj.everySongs"
    private static let voiceKey = "dj.voiceId"
    private static let modelKey = "dj.useLanguageModel"

    /// El DJ habla (apagado hasta que lo actives).
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }

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
        enabled = defaults.bool(forKey: Self.enabledKey)
        let every = defaults.integer(forKey: Self.everyKey)
        everySongs = every > 0 ? every : 3
        voiceId = defaults.string(forKey: Self.voiceKey) ?? ""
        useLanguageModel = defaults.object(forKey: Self.modelKey) == nil ? true : defaults.bool(forKey: Self.modelKey)
    }
}
