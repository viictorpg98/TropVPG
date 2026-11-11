//
//  TropApp.swift
//  Trop
//
//  Created by 686udjie on 28/06/2026.
//

import Nuke
import SwiftUI

@main
struct TropApp: App {
    @State private var settings = SettingsStore.shared

    init() {
        _ = LaunchClock.start
        // La base de datos se abre en segundo plano al arrancar, no la primera vez que una pantalla la pide en el hilo principal.
        Task.detached(priority: .userInitiated) { _ = DatabaseService.shared }
        // El informe de reproduccion empieza de cero en cada arranque de la app.
        PlaybackReport.clear()
        PlaybackReport.record("app iniciada")
        configureNuke()
        // El circulo del sistema al recargar tirando hacia abajo se deja transparente: lo sustituye el logo (`sonarRefreshable`).
        UIRefreshControl.appearance().tintColor = .clear
        ensureDirectories()
        Log.wireSwiftyTube()
        PlayerController.registerRemoteControlSupport()
        observePlaybackSettings()
        // El informe de reproduccion se guarda a disco cada segundo; al pasar a segundo plano, de inmediato.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { _ in PlaybackReport.flush() }
        Task { await InnerTubeClient.tropShared.syncTropLocale() }
    }

    /// Re-applies mpv playback settings whenever the user changes the
    /// equalizer or the audio filters from any screen.
    private func observePlaybackSettings() {
        func register() {
            withObservationTracking {
                let settings = SettingsStore.shared
                _ = settings.equalizerEnabled
                _ = settings.equalizerGains
                _ = settings.audioNormalization
                _ = settings.gaplessPlayback
            } onChange: {
                Task { @MainActor in
                    PlayerController.shared.applyPlaybackSettings()
                    // La observacion salta una sola vez: se vuelve a registrar para el siguiente cambio.
                    register()
                }
            }
        }
        register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(settings.preferredColorScheme)
                .tint(settings.accentColor)
                .environment(settings)
                .environment(\.downloadManager, DownloadManager.shared)
        }
    }

    private func configureNuke() {
        let dataCache = try? DataCache(name: "com.trop.nuke")
        dataCache?.sizeLimit = 2 * 1024 * 1024 * 1024

        var config = ImagePipeline.Configuration()
        config.dataCache = dataCache
        config.imageCache = ImageCache(costLimit: 100 * 1024 * 1024)

        ImagePipeline.shared = ImagePipeline(configuration: config)
    }

    private func ensureDirectories() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: docs.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: docs.appendingPathComponent("Player"), withIntermediateDirectories: true)
    }
}
