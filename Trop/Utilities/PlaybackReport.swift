//
//  PlaybackReport.swift
//  Trop
//

import Foundation

/// Registro corto de lo que pasa al reproducir (que cliente de YouTube dio la direccion, que dijo el
/// reproductor...). Se consulta en Ajustes > Acerca de > Informe de reproduccion, para poder ver que falla
/// cuando algo no suena sin necesidad de un Mac.
enum PlaybackReport {
    private static let key = "playback.report"
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Se puede llamar desde cualquier hilo.
    static func record(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        var lines = UserDefaults.standard.stringArray(forKey: key) ?? []
        lines.append("\(formatter.string(from: Date())) \(text)")
        UserDefaults.standard.set(Array(lines.suffix(40)), forKey: key)
    }

    static var text: String {
        lock.lock()
        defer { lock.unlock() }
        let lines = UserDefaults.standard.stringArray(forKey: key) ?? []
        return lines.isEmpty ? "" : lines.joined(separator: "\n")
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: key)
    }
}
