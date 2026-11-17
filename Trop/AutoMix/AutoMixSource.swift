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

    /// Canciones cuya direccion de reproduccion no se pudo leer con FFmpeg (p. ej. "403 Forbidden"): para ellas se prueba la direccion de
    /// DESCARGA (otra cadena de clientes de YouTube), una sola vez por sesion y cancion (cada intento cuesta una tanda de peticiones).
    private static var useDownloadAddress = Set<String>()
    private static var triedDownloadAddress = Set<String>()
    /// La direccion de descarga ya pedida de cada cancion (cada peticion cuesta una tanda de llamadas a YouTube); se reutiliza 20 minutos.
    private static var downloadAddressCache: [String: (source: Source, date: Date)] = [:]
    private static let downloadAddressLifetime: TimeInterval = 20 * 60

    /// El analisis o la preparacion de una mezcla no pudo leer esta cancion en streaming.
    static func noteReadFailure(videoId: String) {
        if useDownloadAddress.contains(videoId) {
            useDownloadAddress.remove(videoId)
            downloadAddressCache[videoId] = nil
            PlaybackReport.record("automix: \(videoId) direccion de descarga: tampoco se pudo leer")
            return
        }
        guard !triedDownloadAddress.contains(videoId) else { return }
        triedDownloadAddress.insert(videoId)
        useDownloadAddress.insert(videoId)
        PlaybackReport.record("automix: \(videoId) no se pudo leer; la proxima vez se prueba la direccion de descarga")
    }

    static func source(for videoId: String) async -> Source? {
        if let local = await DownloadManager.shared.localURL(for: videoId) {
            let seconds = (try? await AVURLAsset(url: local).load(.duration))?.seconds
            return Source(url: local, isLocal: true, duration: seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
        }
        guard streamingAllowed else { return nil }
        let wantsDownloadAddress = useDownloadAddress.contains(videoId)
        if wantsDownloadAddress, let cached = downloadAddressCache[videoId],
           Date().timeIntervalSince(cached.date) < downloadAddressLifetime {
            return cached.source
        }
        guard let result = try? await PlaybackManager.shared.resolve(videoId: videoId, forDownload: wantsDownloadAddress),
              let url = URL(string: result.streamUrl) else { return nil }
        let source = Source(url: url, isLocal: false, duration: result.duration.flatMap { $0 > 0 ? TimeInterval($0) : nil })
        if wantsDownloadAddress {
            PlaybackReport.record("automix: \(videoId) direccion de descarga obtenida, se intenta leer con ella")
            downloadAddressCache[videoId] = (source, Date())
        }
        return source
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
