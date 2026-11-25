//
//  RadioSongFacts.swift
//  Trop
//
//  Datos REALES de lo que suena, sacados del historial local de escuchas del movil (la tabla `event`, que apunta una fila por cada reproduccion de 30 s o mas):
//  cuantas veces has oido una cancion este mes, cuando fue la ultima o si no consta ninguna escucha antes; y tu top 5 de la semana. Nada sale del movil salvo la
//  frase corta que se pone en el prompt, y solo con "La radio recuerda" activado. No se usa el año de las canciones (no es fiable): solo lo que se ha medido aqui.
//

import Foundation
import GRDB

enum RadioSongFacts {
    /// Una frase con lo que la radio sabe de tus escuchas de esta cancion ("«Titulo»: la has escuchado 4 veces este mes"), o `nil` si no hay nada que decir. Cuenta
    /// tambien las escuchas de otras versiones con el mismo titulo y artista (la version de audio cambia el id).
    static func line(for song: SongItem) async -> String? {
        let id = song.videoId
        let title = song.title
        let artist = song.artistNamesDisplay
        let dates: [Date] = (try? await DatabaseService.shared.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.timestamp FROM event e JOIN song s ON s.id = e.song_id
                WHERE s.id = ? OR (s.title = ? AND ifnull(s.artist_name, '') = ?)
                ORDER BY e.timestamp DESC LIMIT 500
                """, arguments: [id, title, artist])
                .compactMap { (row: Row) -> Date? in row["timestamp"] }
        }) ?? []
        let now = Date()
        let label = "«\(title)»"
        // Sin escuchas anteriores no hay nada que decir (esa linea solo daba "suena por primera vez" en todas las piezas).
        guard let last = dates.first else { return nil }
        let monthAgo = now.addingTimeInterval(-30 * 86_400)
        let month = dates.filter { $0 > monthAgo }.count
        let days = Int(now.timeIntervalSince(last) / 86_400)
        var options: [String] = []
        if month >= 2 { options.append("\(label): segun el historial de la app, la has escuchado \(month) veces el ultimo mes.") }
        if days >= 14 { options.append("\(label): segun el historial de la app, la ultima vez que la escuchaste fue hace \(describe(days: days)).") }
        if dates.count >= 8 { options.append("\(label): segun el historial de la app, en total la has escuchado \(dates.count) veces.") }
        return options.randomElement()
    }

    private static func describe(days: Int) -> String {
        if days >= 60 { return "\(days / 30) meses" }
        if days >= 14 { return "\(days / 7) semanas" }
        return "\(days) dias"
    }

    /// Lo que mas has escuchado esta semana, de mas a menos ("1. Titulo - Artista (5 veces)"), sin musica de dormir ni podcasts. `nil` si no hay al menos 3 canciones
    /// con 2 escuchas o mas.
    static func weeklyTop(limit: Int = 5) async -> [String]? {
        let since = Date().addingTimeInterval(-7 * 86_400)
        let rows: [(entity: SongEntity, count: Int)] = (try? await DatabaseService.shared.read { db -> [(entity: SongEntity, count: Int)] in
            let counts = try Row.fetchAll(db, sql: """
                SELECT song_id, COUNT(*) AS n FROM event WHERE timestamp > ? GROUP BY song_id HAVING n >= 2 ORDER BY n DESC LIMIT 30
                """, arguments: [since])
            let ids = counts.compactMap { (row: Row) -> String? in row["song_id"] }
            let songs = try DatabaseService.fetchSongMapByIds(ids, db: db)
            return counts.compactMap { (row: Row) -> (entity: SongEntity, count: Int)? in
                guard let id: String = row["song_id"], let entity = songs[id], let n: Int = row["n"] else { return nil }
                return (entity: entity, count: n)
            }
        }) ?? []
        let usable = rows.filter { entry in
            !entry.entity.isEpisode && entry.entity.duration < 900 && !SleepFilter.shared.isSleep(videoId: entry.entity.id)
        }
        guard usable.count >= 3 else { return nil }
        return usable.prefix(limit).enumerated().map { index, entry in
            let artist = (entry.entity.artistName ?? "").isEmpty ? "" : " - \(entry.entity.artistName ?? "")"
            return "\(index + 1). \(entry.entity.title)\(artist) (\(entry.count) veces)"
        }
    }
}
