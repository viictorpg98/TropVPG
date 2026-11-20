//
//  VoiceLog.swift
//  Trop
//
//  El registro de la ultima busqueda por voz. Cada linea se escribe en un fichero y se fuerza a disco EN EL ACTO (la app puede cerrarse en mitad de
//  la escucha, y el informe normal se guarda cada medio minuto y no llega a salir). Ajustes > Reproduccion lo enseña y lo copia. Cada linea tambien
//  va al informe con el prefijo "voz:".
//

import Foundation

enum VoiceLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("voice-last-run.txt")
    }

    /// Se puede llamar desde cualquier hilo (incluido el del audio).
    static func add(_ text: String) {
        PlaybackReport.record("voz: \(text)")
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) \(text)\n"
        let file = fileURL
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.synchronize()
        } else {
            try? line.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Empieza un intento nuevo (borra el anterior).
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static var text: String {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }
}
