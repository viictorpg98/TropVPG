//
//  AutoMixSource.swift
//  Trop
//

import AVFoundation
import Foundation

/// De donde sale el audio de una cancion para AutoMix: el archivo descargado o, si no lo esta (y hay Wi-Fi), su
/// direccion de streaming, que FFmpeg decodifica directamente (misma linea de tiempo que mpv, que la reproduce igual).
@MainActor
enum AutoMixSource {
    struct Source {
        let url: URL
        let isLocal: Bool
        /// Cuanto dura, en segundos, si se sabe (la respuesta de YouTube o el propio archivo).
        var duration: TimeInterval?
    }

    /// Se puede decodificar una cancion en streaming: hay red y, si no es Wi-Fi, el usuario ha permitido los datos moviles.
    private static var streamingAllowed: Bool {
        NetworkMonitor.shared.hasConnection
            && (DownloadManager.shared.isOnWiFiNow || SettingsStore.shared.autoMixUsesMobileData)
    }

    /// Se puede mezclar con esta cancion: descargada, o en streaming si la red lo permite.
    static func isAvailable(videoId: String) -> Bool {
        DownloadManager.shared.isDownloaded(videoId: videoId) || streamingAllowed
    }

    static func source(for videoId: String) async -> Source? {
        if let local = await DownloadManager.shared.localURL(for: videoId) {
            let seconds = (try? await AVURLAsset(url: local).load(.duration))?.seconds
            return Source(url: local, isLocal: true, duration: seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
        }
        guard streamingAllowed else { return nil }
        guard let result = try? await PlaybackManager.shared.resolve(videoId: videoId),
              let url = URL(string: result.streamUrl) else { return nil }
        return Source(url: url, isLocal: false, duration: result.duration.flatMap { $0 > 0 ? TimeInterval($0) : nil })
    }

    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15" +
        " (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// Opciones de FFmpeg para leer una direccion de internet (para archivos locales no hacen falta).
    nonisolated static func inputOptions(for url: URL) -> [String] {
        guard !url.isFileURL else { return [] }
        var options = ["-rw_timeout", "20000000", "-user_agent", userAgent]
        if let caPath = Bundle.main.path(forResource: "cacert", ofType: "pem") {
            options += ["-cafile", caPath]
        }
        return options
    }
}
