//
//  HomeCache.swift
//  Trop
//

import Foundation

/// Ultima portada de YouTube Music recibida, guardada tal cual en disco: sin conexion (o si falla la peticion)
/// se vuelve a leer y se enseña con la fecha en que se guardo, en vez de dejar Inicio con un error.
enum HomeCache {
    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("home-feed.json")
    }()

    /// Guarda la respuesta en segundo plano (puede pesar unos cientos de KB).
    static func save(_ json: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(json) else { return }
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONSerialization.data(withJSONObject: json) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    static func load() -> (json: [String: Any], date: Date)? {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let date = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date.distantPast
        return (object, date)
    }
}
