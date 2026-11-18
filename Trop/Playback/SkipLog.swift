//
//  SkipLog.swift
//  Trop
//
//  Los saltos (una cancion que se deja de oir antes de los 20 s). El historial (`event`) solo guarda reproducciones de 30 s o mas, asi que
//  hasta ahora no quedaba rastro de lo que saltas; "Para ti" lo usa para no volver a poner lo que has saltado dos veces.
//

import Foundation

enum SkipLog {
    private static let key = "playback.skips.v1"
    private static let windowSeconds: Double = 60 * 86_400

    static func record(videoId: String) {
        guard !videoId.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]]) ?? [:]
        var times = (all[videoId] ?? []).filter { now - $0 < windowSeconds }
        times.append(now)
        all[videoId] = Array(times.suffix(6))
        if all.count > 600 {
            // Se conservan los 500 saltos mas recientes.
            let oldest = all.sorted { ($0.value.last ?? 0) < ($1.value.last ?? 0) }.prefix(all.count - 500)
            for entry in oldest { all.removeValue(forKey: entry.key) }
        }
        UserDefaults.standard.set(all, forKey: key)
    }

    /// Cuantas veces se ha saltado cada cancion en los ultimos 60 dias.
    static func recentCounts() -> [String: Int] {
        let now = Date().timeIntervalSince1970
        let all = (UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]]) ?? [:]
        var counts: [String: Int] = [:]
        for (videoId, times) in all {
            let recent = times.filter { now - $0 < windowSeconds }.count
            if recent > 0 { counts[videoId] = recent }
        }
        return counts
    }
}
