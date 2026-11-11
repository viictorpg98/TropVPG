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
    /// Las lineas en memoria; se vuelcan a disco cada segundo (antes se reescribian las 200 en cada apunte).
    nonisolated(unsafe) private static var buffer: [String]?
    nonisolated(unsafe) private static var flushScheduled = false

    private static func loadLocked() -> [String] {
        if let buffer { return buffer }
        let lines = UserDefaults.standard.stringArray(forKey: key) ?? []
        buffer = lines
        return lines
    }

    /// Se puede llamar desde cualquier hilo.
    static func record(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        var lines = loadLocked()
        lines.append("\(formatter.string(from: Date())) \(text)")
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        buffer = lines
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { flush() }
    }

    /// Vuelca el informe a disco (tambien al pasar la app a segundo plano).
    static func flush() {
        lock.lock()
        defer { lock.unlock() }
        flushScheduled = false
        if let buffer { UserDefaults.standard.set(buffer, forKey: key) }
    }

    static var text: String {
        lock.lock()
        defer { lock.unlock() }
        let lines = loadLocked()
        return lines.isEmpty ? "" : lines.joined(separator: "\n")
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Milisegundos desde que arranco la app (se anota en el Informe para ver cuanto tarda cada paso del inicio).
enum LaunchClock {
    static let start = Date()

    static func ms() -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
