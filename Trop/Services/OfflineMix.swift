//
//  OfflineMix.swift
//  Trop
//

import Foundation
import GRDB
import UIKit

/// Mantiene descargadas unas cuantas canciones de tu mezcla para que "Pon mi musica" arranque al
/// instante y funcione sin conexion, y libera espacio solo cuando hace falta.
///
/// - Solo toca las descargas que ha hecho ella (`autoIds`): lo que descargas tu a mano no se borra
///   nunca por este camino, y si descargas a mano una cancion de la mezcla, pasa a ser tuya.
/// - Rota: las canciones que ya has escuchado (y una parte de las demas) se sustituyen por otras
///   nuevas, para que no suene siempre lo mismo.
/// - Descargas inteligentes: con poco espacio libre borra las descargas que llevas meses sin
///   escuchar. Nunca las que te gustan ni la que esta sonando.
@MainActor
final class OfflineMix {
    static let shared = OfflineMix()

    private enum Keys {
        static let autoIds = "offlineMix.autoIds"
        static let lastRun = "offlineMix.lastRun"
        static let recentlyRemoved = "offlineMix.recentlyRemoved"
    }

    /// Como mucho una pasada cada tanto tiempo.
    private static let minInterval: TimeInterval = 6 * 3600
    /// Se espera un poco tras abrir la app para no competir con lo que se este haciendo.
    private static let startupDelay: Duration = .seconds(20)
    /// En cada pasada se renueva al menos 1/4 de la mezcla, aunque no se haya escuchado.
    private static let rotationDivisor = 4
    private static let maxNewPerRun = 40
    /// Debajo de esto se consideran "descargas inteligentes".
    private static let lowSpaceBytes: Int64 = 3_000_000_000
    /// Para descargar mas hace falta al menos esto libre.
    private static let minFreeToAdd: Int64 = 1_000_000_000
    private static let unusedAfter: TimeInterval = 90 * 86_400
    /// Una cancion que se quito de la mezcla no vuelve a bajarse hasta pasado este tiempo.
    private static let repeatPause: TimeInterval = 14 * 86_400

    private var autoIds: Set<String>
    private var isRunning = false

    private init() {
        autoIds = Set(UserDefaults.standard.stringArray(forKey: Keys.autoIds) ?? [])
    }

    // MARK: - Estado

    func isAuto(_ videoId: String) -> Bool {
        autoIds.contains(videoId)
    }

    /// La persona ha descargado esta cancion a mano: pasa a ser suya y la mezcla ya no la toca.
    func release(_ videoId: String) {
        if autoIds.remove(videoId) != nil { saveAutoIds() }
    }

    private func saveAutoIds() {
        UserDefaults.standard.set(Array(autoIds), forKey: Keys.autoIds)
    }

    // MARK: - Pasada

    func refreshIfNeeded(force: Bool = false) async {
        guard !isRunning else { return }
        let settings = SettingsStore.shared
        guard settings.offlineMixEnabled || settings.smartCleanupEnabled else { return }

        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: Keys.lastRun) as? Date ?? .distantPast
        if !force, Date().timeIntervalSince(last) < Self.minInterval { return }

        isRunning = true
        defer { isRunning = false }

        if !force { try? await Task.sleep(for: Self.startupDelay) }
        let manager = DownloadManager.shared
        guard manager.isLoaded else { return }

        await cleanUpUnused()

        guard settings.offlineMixEnabled else {
            defaults.set(Date(), forKey: Keys.lastRun)
            return
        }
        // Sin Wi-Fi, con el modo de bajo consumo o con poco espacio no se baja nada: se reintenta
        // la proxima vez que se abra la app (no se marca la pasada como hecha).
        guard manager.isOnWiFiNow,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              (Self.freeSpaceBytes() ?? .max) > Self.minFreeToAdd else { return }

        await rotateMix()
        defaults.set(Date(), forKey: Keys.lastRun)
    }

    // MARK: - Mezcla

    private func rotateMix() async {
        let settings = SettingsStore.shared
        let manager = DownloadManager.shared
        let target = min(max(settings.offlineMixSize, 5), 100)

        // Las descargas que quedaron a medias y ya no existen dejan de contar como de la mezcla.
        autoIds = autoIds.filter { manager.isDownloaded(videoId: $0) || manager.isPendingOrActive($0) }

        // Fuentes de variedad: la mezcla nueva de YouTube Music, la guardada, tus Me gusta y tu Top.
        let fresh = await SonarMix.refreshCache()
        let cached = SonarMix.cachedMix() ?? []
        let liked = ((try? await DatabaseService.shared.fetchLikedSongs()) ?? []).toSongItems()
        let top = ((try? await DatabaseService.shared.fetchTopSongs(limit: 100)) ?? []).toSongItems()
        let candidates = filteredCandidates(
            Self.interleaved([fresh.shuffled(), cached.shuffled(), liked.shuffled(), top.shuffled()]),
            manager: manager,
            hideExplicit: settings.hideExplicit
        )

        // Las que ya estan descargadas por la mezcla, de mas a menos "gastadas".
        let downloadedAuto = autoIds.filter { manager.isDownloaded(videoId: $0) }
        let played = await Self.lastPlayedDates()
        let downloadedAt = Dictionary(
            manager.tracks.map { ($0.id, $0.downloadedAt) },
            uniquingKeysWith: { first, _ in first }
        )
        let heard = downloadedAuto.filter { id in
            guard let when = played[id], let since = downloadedAt[id] else { return false }
            return when > since
        }
        let byAge: (String, String) -> Bool = { (downloadedAt[$0] ?? .distantPast) < (downloadedAt[$1] ?? .distantPast) }
        let orderedForRemoval = heard.sorted(by: byAge) + downloadedAuto.subtracting(heard).sorted(by: byAge)

        let free = max(0, target - downloadedAuto.count)
        let excess = max(0, downloadedAuto.count - target)
        let plannedRotation = max(heard.count, min(downloadedAuto.count, max(3, target / Self.rotationDivisor)))
        let addCount = min(candidates.count, free + plannedRotation, Self.maxNewPerRun)
        // Se quita lo justo para hacer sitio (y lo que sobre si se ha reducido el tamano), y solo si
        // hay con que sustituirlo: nunca se vacia la mezcla por no encontrar canciones nuevas.
        let removeCount = min(orderedForRemoval.count, max(excess, addCount - free))

        let playingId = NowPlaying.shared.videoId
        var removed = 0
        for id in orderedForRemoval.prefix(removeCount) where id != playingId {
            autoIds.remove(id)
            rememberRemoved(id)
            await manager.delete(videoId: id)
            removed += 1
        }
        let additions = Array(candidates.prefix(addCount))
        for song in additions {
            autoIds.insert(song.videoId)
            Task { await manager.download(song: song, fromOfflineMix: true) }
        }
        saveAutoIds()
        Log.downloadManager.notice("Offline mix: removed \(removed), queued \(additions.count), target \(target)")
    }

    private func filteredCandidates(
        _ songs: [SongItem],
        manager: DownloadManager,
        hideExplicit: Bool
    ) -> [SongItem] {
        let recentlyRemoved = loadRecentlyRemoved()
        return songs.filter { song in
            !song.videoId.isEmpty
                && !manager.isDownloaded(videoId: song.videoId)
                && !manager.isPendingOrActive(song.videoId)
                && recentlyRemoved[song.videoId] == nil
                && !(hideExplicit && song.isExplicit)
                // Mezclas y directos de horas no tienen sentido como "una cancion mas".
                && song.duration <= 12 * 60
        }
    }

    /// Reparte por turnos entre varias listas, sin repetir, para que ninguna fuente domine.
    private static func interleaved(_ lists: [[SongItem]]) -> [SongItem] {
        var result: [SongItem] = []
        var seen = Set<String>()
        let longest = lists.map(\.count).max() ?? 0
        for index in 0..<longest {
            for list in lists where index < list.count {
                if seen.insert(list[index].videoId).inserted { result.append(list[index]) }
            }
        }
        return result
    }

    // MARK: - Canciones quitadas recientemente

    private func loadRecentlyRemoved() -> [String: Double] {
        let cutoff = Date().timeIntervalSince1970 - Self.repeatPause
        let stored = UserDefaults.standard.dictionary(forKey: Keys.recentlyRemoved) as? [String: Double] ?? [:]
        return stored.filter { $0.value > cutoff }
    }

    private func rememberRemoved(_ videoId: String) {
        var stored = loadRecentlyRemoved()
        stored[videoId] = Date().timeIntervalSince1970
        UserDefaults.standard.set(stored, forKey: Keys.recentlyRemoved)
    }

    // MARK: - Descargas inteligentes

    private func cleanUpUnused() async {
        guard SettingsStore.shared.smartCleanupEnabled,
              // Sin historial no se sabe que se ha escuchado: mejor no borrar nada.
              SettingsStore.shared.trackPlayHistory,
              var free = Self.freeSpaceBytes(),
              free < Self.lowSpaceBytes else { return }

        let manager = DownloadManager.shared
        let played = await Self.lastPlayedDates()
        let liked = Set(LikeStore.shared.liked.filter { $0.value }.keys)
        let cutoff = Date().addingTimeInterval(-Self.unusedAfter)
        let playingId = NowPlaying.shared.videoId

        func lastUse(_ track: DownloadedTrackEntity) -> Date {
            max(played[track.id] ?? .distantPast, track.downloadedAt)
        }
        let candidates = manager.tracks
            .filter {
                !autoIds.contains($0.id) && !liked.contains($0.id)
                    && $0.id != playingId && lastUse($0) < cutoff
            }
            .sorted { lastUse($0) < lastUse($1) }

        var removed = 0
        for track in candidates.prefix(150) {
            free += manager.fileSize(for: track.id)
            await manager.delete(videoId: track.id)
            removed += 1
            if free >= Self.lowSpaceBytes { break }
        }
        if removed > 0 {
            Log.downloadManager.notice("Smart cleanup: removed \(removed) unused downloads")
        }
    }

    // MARK: - Utilidades

    /// Ultima vez que se escucho cada cancion, segun el historial local.
    static func lastPlayedDates() async -> [String: Date] {
        let rows: [(String, Date)] = (try? await DatabaseService.shared.read { db in
            try Row.fetchAll(db, sql: "SELECT song_id, MAX(timestamp) AS last FROM event GROUP BY song_id")
                .compactMap { row -> (String, Date)? in
                    guard let id: String = row["song_id"], let date: Date = row["last"] else { return nil }
                    return (id, date)
                }
        }) ?? []
        return Dictionary(rows, uniquingKeysWith: { max($0, $1) })
    }

    static func freeSpaceBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
