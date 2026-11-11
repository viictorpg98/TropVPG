//
//  SyncBridge.swift
//  Trop
//
//  Created by 686udjie on 09/10/2026.
//

import Foundation

enum SyncBridge {
    static let store = TropLibraryStore()
    static let librarySync = LibrarySyncService(client: InnerTubeClient.tropShared, store: store)
    static let playlistDetail = PlaylistDetailService(client: InnerTubeClient.tropShared, store: store)
    static let mutations = MutationService(client: InnerTubeClient.tropShared, store: store)
    static let incremental = IncrementalSyncService(client: InnerTubeClient.tropShared, librarySync: librarySync)

    static var options: LibrarySyncOptions {
        let settings = SettingsStore.shared
        return LibrarySyncOptions(
            syncArtists: settings.syncArtists,
            syncPlaylists: settings.syncPlaylists,
            syncAlbums: settings.syncAlbums,
            syncPodcasts: settings.syncPodcasts,
            syncSongs: settings.syncSongs
        )
    }

    private static let staleGate = NSLock()
    nonisolated(unsafe) private static var staleCheckRunning = false

    private static func beginStaleCheck() -> Bool {
        staleGate.lock()
        defer { staleGate.unlock() }
        if staleCheckRunning { return false }
        staleCheckRunning = true
        return true
    }

    private static func endStaleCheck() {
        staleGate.lock()
        staleCheckRunning = false
        staleGate.unlock()
    }

    /// Inicio y Biblioteca la piden al abrirse: si ya hay una comprobacion en marcha, no se lanza otra.
    static func checkAndSyncIfStale() async {
        guard beginStaleCheck() else { return }
        await incremental.checkAndSyncIfStale(options: options) {
            await LikeStore.shared.refresh()
        }
        endStaleCheck()
    }

    static func forceFullSync() async {
        await incremental.forceFullSync(options: options) {
            await LikeStore.shared.refresh()
        }
    }

    // MARK: - Sincronizacion completa en segundo plano (Biblioteca, al tirar hacia abajo)

    private static let backgroundGate = NSLock()
    nonisolated(unsafe) private static var backgroundFullSyncRunning = false

    /// `true` si se puede lanzar una sincronizacion completa en segundo plano (si ya hay una en marcha, `false`).
    /// Quien la lance debe llamar a `endBackgroundFullSync()` al terminar.
    static func beginBackgroundFullSync() -> Bool {
        backgroundGate.lock()
        defer { backgroundGate.unlock() }
        if backgroundFullSyncRunning { return false }
        backgroundFullSyncRunning = true
        return true
    }

    static func endBackgroundFullSync() {
        backgroundGate.lock()
        backgroundFullSyncRunning = false
        backgroundGate.unlock()
    }
}
