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

    /// Se puede llamar desde cualquier hilo (incluido el del audio). `report: false` = solo al fichero (los latidos no llenan el informe).
    static func add(_ text: String, report: Bool = true) {
        if report { PlaybackReport.record("voz: \(text)") }
        lock.lock()
        defer { lock.unlock() }
        append("\(formatter.string(from: Date())) \(text)\n")
    }

    private static func append(_ line: String) {
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

    /// Empieza un intento nuevo: se guardan los ultimos 4 (con una linea "==== intento" cada uno) para poder probar varios botones seguidos y
    /// copiar el registro una sola vez al final.
    static func beginAttempt(source: String) {
        lock.lock()
        defer { lock.unlock() }
        let marker = "==== intento "
        let old = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let previous = old.components(separatedBy: marker).filter { !$0.isEmpty }.suffix(3)
        let kept = previous.map { marker + $0 }.joined()
        let header = "\(marker)\(source) \(formatter.string(from: Date()))\n"
        try? (kept + header).write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static var text: String {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }
}
