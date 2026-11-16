//
//  DJSettings.swift
//  Trop
//
//  Ajustes del DJ automatico. La sesion de DJ (encendido/apagado) NO se guarda: empieza apagada cada vez que se abre la app y se
//  enciende desde el reproductor, el menu de la cola o el Inicio. Lo demas se guarda aparte de `SettingsStore`.
//

import Foundation
import Observation

@MainActor
@Observable
final class DJSettings {
    static let shared = DJSettings()

    private static let sortKey = "dj.sortQueue"

    /// Hay una sesion de DJ en marcha (no se guarda: al abrir la app empieza apagada). Lo cambia `DJSession`.
    var sessionActive = false

    /// Con el DJ en marcha, ordena solo lo que queda de la cola para que las canciones encajen (tempo y tonalidad).
    var sortQueue: Bool {
        didSet { UserDefaults.standard.set(sortQueue, forKey: Self.sortKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        sortQueue = defaults.object(forKey: Self.sortKey) == nil ? true : defaults.bool(forKey: Self.sortKey)
    }
}
