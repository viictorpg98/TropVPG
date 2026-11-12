//
//  WaveformStore.swift
//  Trop
//
//  La onda de la barra de progreso. Se calcula aparte del analisis de AutoMix (que es lento y a veces no encuentra compas):
//  solo hace falta el volumen de cada trozo de la cancion. Se guarda en disco (160 bytes por cancion) y se prepara por
//  adelantado para la que suena y las siguientes, de modo que al abrir el reproductor ya esta.
//

import AVFoundation
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
    private var missChecked: [String: Date] = [:]

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
        if missChecked[videoId].map({ Date().timeIntervalSince($0) >= 3 }) ?? true {
            if let data = try? Data(contentsOf: fileURL(videoId)), data.count == Self.buckets {
                let wave = data.map { Float($0) / 255 }
                memory[videoId] = wave
                return wave
            }
            missChecked[videoId] = Date()
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
    func request(_ videoId: String, urgent wantsUrgent: Bool) {
        // Solo la que suena tiene el carril urgente (la entrante de una mezcla lo pedia cada 0,5 s y se cortaba al instante).
        let urgent = wantsUrgent && NowPlaying.shared.videoId == videoId
        guard cached(for: videoId) == nil else { return }
        if let later = failed[videoId], later > Date() { return }
        // Una cancion larga (mezclas, directos de horas) no se baja entera: su onda sale de unas 80 muestras repartidas por
        // ella. Solo la de la que suena, y en streaming solo con el reproductor grande abierto (es lo unico que la enseña).
        let long = TrackAnalysisStore.shared.isLong(videoId)
        if long && !urgent { return }
        // Una cancion en streaming cuesta datos (hay que bajarla entera para sacar su onda):
        if !DownloadManager.shared.isDownloaded(videoId: videoId) {
            if long {
                guard PlayerController.shared.fullPlayerVisible, AutoMixSourceGate.allowsPrefetch else { return }
            // Con AutoMix, el analisis de la cancion (que ya la baja) saca tambien la onda: no se baja dos veces.
            } else if SettingsStore.shared.autoMixEnabled, AutoMixSource.isAvailable(videoId: videoId) {
                TrackAnalysisStore.shared.request(videoId)
                // Salvo que la cola de analisis lleve un rato atascada con otra cancion: la que suena saca su onda por su
                // propio carril, sin esperar detras.
                guard urgent, TrackAnalysisStore.shared.shouldBypassQueue(for: videoId), AutoMixSourceGate.allowsPrefetch else { return }
            } else {
                // Sin AutoMix, solo con el reproductor grande abierto (es lo unico que la enseña) y con Wi-Fi o con los datos
                // moviles permitidos.
                guard PlayerController.shared.fullPlayerVisible, AutoMixSourceGate.allowsPrefetch else { return }
            }
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
                // Si se corto porque la cancion ya no es la actual, no es un fallo: solo se espera un poco para no repetirlo sin parar.
                let stillWanted = !isCurrent || NowPlaying.shared.videoId == videoId
                self.failed[videoId] = Date().addingTimeInterval(stillWanted ? 60 : 10)
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
        var knownLength: TimeInterval?
        if let file = await DownloadManager.shared.localURL(for: videoId) {
            url = file
            local = true
            knownLength = (try? await AVURLAsset(url: file).load(.duration))?.seconds
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
                knownLength = resolved.duration.flatMap { $0 > 0 ? TimeInterval($0) : nil }
            }
        }
        guard let url else { return nil }
        let isLocal = local
        let analysis = TrackAnalysisStore.shared
        let length = knownLength.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? analysis.knownDuration(videoId)
        if analysis.isLong(videoId) || (length ?? 0) > TrackAnalysisStore.longSeconds {
            // Larga: por muestras. Si no se sabe cuanto dura aun, se intentara mas tarde (el reproductor la sabra).
            guard let length, length > TrackAnalysisStore.longSeconds else { return nil }
            let started = Date()
            PlaybackReport.record(String(format: "onda de %@ por muestras (%.0f min): empieza", videoId, length / 60))
            // Fuera del hilo principal: una funcion `nonisolated async` llamada desde aqui se ejecutaba en el principal y sus
            // 80 lecturas de FFmpeg (que esperan) dejaban la app parada varios segundos.
            let wave = await Task.detached(priority: .utility) {
                await Self.sampledEnvelope(url, isLocal: isLocal, duration: length, videoId: videoId, isCurrent: isCurrent)
            }.value
            PlaybackReport.record(String(
                format: "onda de %@ por muestras: %@ (%.0f s)", videoId, wave == nil ? "cortada o sin datos" : "lista",
                Date().timeIntervalSince(started)
            ))
            return wave
        }
        let unknownLength = length == nil
        return await Task.detached(priority: isCurrent ? .userInitiated : .utility) {
            let pcm = isLocal ? await TrackAnalysisStore.decode(url) : TrackAnalysisStore.decodeRemote(url)
            guard let pcm, pcm.count > buckets * 4 else { return nil }
            // Sin saber cuanto dura y con la lectura en su tope: es larga y esto no seria su onda.
            if unknownLength, Double(pcm.count) / Double(TrackStructureAnalyzer.sampleRate) >= TrackAnalysisStore.longSeconds + 15 {
                return nil
            }
            return Self.envelope(pcm)
        }.value
    }

    /// La onda de una cancion larga: 40 trozos de 1,5 s repartidos por ella (unos pocos MB en total, en vez de bajarla entera),
    /// leidos de 6 en 6 a la vez y estirados a las 160 barras. Si cambias de cancion antes de llegar a la mitad se corta; si
    /// ya la pasaste, termina igualmente (queda guardada para otra vez).
    nonisolated private static func sampledEnvelope(
        _ url: URL, isLocal: Bool, duration: TimeInterval, videoId: String, isCurrent: Bool
    ) async -> [Float]? {
        let count = 40
        let batchSize = 4
        let box = LevelBox(count: count)
        var start = 0
        while start < count {
            if isCurrent, start < count / 2 {
                let wanted = await MainActor.run { NowPlaying.shared.videoId == videoId }
                guard wanted else { return nil }
            }
            let end = min(start + batchSize, count)
            let first = start
            DispatchQueue.concurrentPerform(iterations: end - first) { slot in
                let index = first + slot
                let center = duration * (Double(index) + 0.5) / Double(count)
                guard let pcm = TrackAnalysisStore.decodePCM(
                    url, isLocal: isLocal, start: max(0, center - 0.75), length: 1.5, timeout: 15, isWave: true
                ), pcm.count > 400 else { return }
                var sum = 0.0
                for value in pcm {
                    let x = Double(value) / 32768
                    sum += x * x
                }
                box.set(index, Float((sum / Double(pcm.count)).squareRoot()))
            }
            start = end
        }
        // Las muestras que no se pudieron leer toman el valor de la conocida mas cercana; si faltan mas de la mitad, sin onda.
        let known = box.all
        guard known.compactMap({ $0 }).count >= count / 2 else { return nil }
        var levels = [Float](repeating: 0, count: count)
        for index in 0..<count {
            if let value = known[index] {
                levels[index] = value
                continue
            }
            var offset = 1
            while offset < count {
                if index - offset >= 0, let value = known[index - offset] {
                    levels[index] = value
                    break
                }
                if index + offset < count, let value = known[index + offset] {
                    levels[index] = value
                    break
                }
                offset += 1
            }
        }
        let peak = max(levels.max() ?? 0, 0.0001)
        return (0..<buckets).map { bucket in
            let position = (Double(bucket) + 0.5) / Double(buckets) * Double(count) - 0.5
            let low = min(max(Int(position.rounded(.down)), 0), count - 1)
            let high = min(low + 1, count - 1)
            let fraction = Float(min(max(position - Double(low), 0), 1))
            let level = levels[low] * (1 - fraction) + levels[high] * fraction
            return Float(pow(Double(level / peak), 0.55))
        }
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

/// Los niveles de las muestras de una onda, que se rellenan desde varios hilos a la vez.
private final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Float?]

    init(count: Int) { values = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ value: Float) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }

    var all: [Float?] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
