//
//  AutoMixSource.swift
//  Trop
//

import Foundation

/// De donde sale el audio de una cancion para AutoMix: el archivo descargado o, si no lo esta (y hay Wi-Fi), su
/// direccion de streaming, que FFmpeg decodifica directamente (misma linea de tiempo que mpv, que la reproduce igual).
@MainActor
enum AutoMixSource {
    struct Source {
        let url: URL
        let isLocal: Bool
    }

    /// Se puede mezclar con esta cancion: descargada, o con Wi-Fi para decodificarla en streaming (no se gastan datos
    /// moviles en esto).
    static func isAvailable(videoId: String) -> Bool {
        DownloadManager.shared.isDownloaded(videoId: videoId)
            || (NetworkMonitor.shared.hasConnection && DownloadManager.shared.isOnWiFiNow)
    }

    static func source(for videoId: String) async -> Source? {
        if let local = await DownloadManager.shared.localURL(for: videoId) {
            return Source(url: local, isLocal: true)
        }
        guard NetworkMonitor.shared.hasConnection, DownloadManager.shared.isOnWiFiNow else { return nil }
        guard let result = try? await PlaybackManager.shared.resolve(videoId: videoId),
              let url = URL(string: result.streamUrl) else { return nil }
        return Source(url: url, isLocal: false)
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
