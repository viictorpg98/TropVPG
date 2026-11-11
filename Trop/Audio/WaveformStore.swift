//
//  WaveformStore.swift
//  Trop
//
//  La onda de la barra de progreso. Se calcula aparte del analisis de AutoMix (que es lento y a veces no encuentra compas):
//  solo hace falta el volumen de cada trozo de la cancion. Se guarda en disco (160 bytes por cancion) y se prepara por
//  adelantado para la que suena y las siguientes, de modo que al abrir el reproductor ya esta.
//

import Foundation

@MainActor
final class WaveformStore {
    static let shared = WaveformStore()

    nonisolated static let buckets = 160

    private var memory: [String: [Float]] = [:]
    private var queued: [String] = []
    private var urgentQueue: [String] = []
    private var urgentRunning: String?
    private var backgroundRunning: String?
    private var failed: [String: Date] = [:]

    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("waveform", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func fileURL(_ videoId: String) -> URL {
        directory.appendingPathComponent("\(videoId).bin")
    }

    /// La onda si ya esta (memoria, disco o analisis de AutoMix); nunca calcula nada.
    func cached(for videoId: String) -> [Float]? {
        if let wave = memory[videoId] { return wave }
        if let data = try? Data(contentsOf: fileURL(videoId)), data.count == Self.buckets {
            let wave = data.map { Float($0) / 255 }
            memory[videoId] = wave
            return wave
        }
        if let wave = TrackAnalysisStore.shared.structure(for: videoId)?.waveform, wave.count == Self.buckets {
            store(wave, for: videoId)
            return wave
        }
        return nil
    }

    /// Una onda de relleno (siempre igual para la misma cancion) para enseñar algo al instante mientras llega la real.
    static func placeholder(for videoId: String?) -> [Float] {
        var seed = UInt64(5381)
        for byte in (videoId ?? "sonar").utf8 { seed = seed &* 33 &+ UInt64(byte) }
        return (0..<buckets).map { index in
            let x = Double(index) / Double(buckets)
            // Suave, con un par de "estribillos" mas altos; nada que parezca una forma real de la cancion.
            let phase = Double(seed % 997) / 997 * 6.28
            let base = 0.38 + 0.16 * sin(x * 9 + phase) + 0.1 * sin(x * 23 + phase * 1.7)
            return Float(min(0.9, max(0.18, base)))
        }
    }

    /// Pide la onda de una cancion. La de la que suena tiene su propio carril: no espera a las que solo se adelantan.
    func request(_ videoId: String, urgent: Bool) {
        guard cached(for: videoId) == nil else { return }
        if let later = failed[videoId], later > Date() { return }
        // Una cancion en streaming cuesta datos (hay que bajarla entera para sacar su onda):
        if !DownloadManager.shared.isDownloaded(videoId: videoId) {
            // Con AutoMix, el analisis de la cancion (que ya la baja) saca tambien la onda: no se baja dos veces.
            if SettingsStore.shared.autoMixEnabled, AutoMixSource.isAvailable(videoId: videoId) {
                TrackAnalysisStore.shared.request(videoId)
                return
            }
            // Sin AutoMix, solo con el reproductor grande abierto (es lo unico que la enseña) y con Wi-Fi o con los datos
            // moviles permitidos.
            guard PlayerController.shared.fullPlayerVisible, AutoMixSourceGate.allowsPrefetch else { return }
        }
        if urgent {
            guard !urgentQueue.contains(videoId), urgentRunning != videoId else { return }
            queued.removeAll { $0 == videoId }
            urgentQueue.append(videoId)
        } else {
            guard !queued.contains(videoId), !urgentQueue.contains(videoId),
                  urgentRunning != videoId, backgroundRunning != videoId else { return }
            queued.append(videoId)
        }
        drain()
    }

    /// Una cancion empieza a sonar: se prepara su onda y la de las proximas.
    func songStarted(current: String, upcoming: [String]) {
        guard SettingsStore.shared.waveformProgressBar else { return }
        request(current, urgent: true)
        for id in upcoming.prefix(2) { request(id, urgent: false) }
    }

    private func drain() {
        if urgentRunning == nil, !urgentQueue.isEmpty {
            let videoId = urgentQueue.removeFirst()
            urgentRunning = videoId
            run(videoId, isCurrent: true)
        }
        if backgroundRunning == nil, !queued.isEmpty {
            let videoId = queued.removeFirst()
            backgroundRunning = videoId
            run(videoId, isCurrent: false)
        }
    }

    private func run(_ videoId: String, isCurrent: Bool) {
        Task { [weak self] in
            let wave = await Self.compute(videoId, isCurrent: isCurrent)
            guard let self else { return }
            if let wave {
                self.store(wave, for: videoId)
            } else {
                self.failed[videoId] = Date().addingTimeInterval(60)
            }
            if isCurrent { self.urgentRunning = nil } else { self.backgroundRunning = nil }
            self.drain()
        }
    }

    func store(_ wave: [Float], for videoId: String) {
        memory[videoId] = wave
        let data = Data(wave.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) })
        try? data.write(to: fileURL(videoId), options: .atomic)
    }

    // MARK: - Calculo

    private static func compute(_ videoId: String, isCurrent: Bool) async -> [Float]? {
        var url: URL?
        var local = false
        if let file = await DownloadManager.shared.localURL(for: videoId) {
            url = file
            local = true
        } else {
            guard NetworkMonitor.shared.hasConnection else { return nil }
            // En streaming hace falta la direccion de YouTube: la de la que suena ya esta pedida (no se pide otra vez); las
            // demas esperan unos segundos a que el cambio de cancion termine, para no estorbarle.
            if isCurrent {
                for _ in 0..<20 where NowPlaying.shared.isBusyResolving {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            } else {
                guard AutoMixSourceGate.allowsPrefetch else { return nil }
                for _ in 0..<40 where NowPlaying.shared.isBusyResolving
                    || Date().timeIntervalSince(AutoMixEngine.shared.lastSongChange) < 6 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            if let resolved = try? await PlaybackManager.shared.resolve(videoId: videoId) {
                url = URL(string: resolved.streamUrl)
            }
        }
        guard let url else { return nil }
        let isLocal = local
        return await Task.detached(priority: isCurrent ? .userInitiated : .utility) {
            let pcm = isLocal ? await TrackAnalysisStore.decode(url) : TrackAnalysisStore.decodeRemote(url)
            guard let pcm, pcm.count > buckets * 4 else { return nil }
            return Self.envelope(pcm)
        }.value
    }

    /// Volumen (raiz de la energia media) de cada trozo, de 0 a 1 y realzado para que se vea bien.
    nonisolated static func envelope(_ pcm: [Int16]) -> [Float] {
        let per = Double(pcm.count) / Double(buckets)
        var levels = [Float](repeating: 0, count: buckets)
        var peak: Float = 0.0001
        for bucket in 0..<buckets {
            let low = Int(Double(bucket) * per)
            let high = max(low + 1, min(pcm.count, Int(Double(bucket + 1) * per)))
            var sum = 0.0
            for index in low..<high {
                let value = Double(pcm[index]) / 32768
                sum += value * value
            }
            let level = Float((sum / Double(high - low)).squareRoot())
            levels[bucket] = level
            peak = max(peak, level)
        }
        return levels.map { Float(pow(Double($0 / peak), 0.55)) }
    }
}

/// Adelantar la onda de las siguientes (en streaming) gasta datos: se respeta el mismo permiso que AutoMix.
@MainActor
private enum AutoMixSourceGate {
    static var allowsPrefetch: Bool {
        DownloadManager.shared.isOnWiFiNow || SettingsStore.shared.autoMixUsesMobileData
    }
}
