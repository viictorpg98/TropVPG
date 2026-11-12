//
//  TrackAnalysisStore.swift
//  Trop
//

import AVFoundation
import Foundation
import ffmpegkit

/// Analiza las canciones descargadas (de una en una, en segundo plano) y guarda el resultado en disco
/// para no repetir el trabajo. Una cancion no analizable se guarda vacia y no se vuelve a intentar.
@MainActor
final class TrackAnalysisStore {
    static let shared = TrackAnalysisStore()

    private var memory: [String: TrackStructure] = [:]
    private var unusable: Set<String> = []
    /// Cuando se miro por ultima vez el disco sin encontrar su analisis (para no leerlo cuatro veces por segundo).
    private var missChecked: [String: Date] = [:]
    private var queued: [String] = []
    private var running = false
    /// Canciones en streaming cuyo analisis fallo (red...): no se guardan como "no analizables", se reintentan mas tarde.
    private var retryAfter: [String: Date] = [:]
    /// Cada tanda de la cola lleva un numero. Si una cancion tarda demasiado (red lenta, direccion estrangulada...) se da por
    /// perdida y la cola sigue con las demas; si su resultado llega tarde se guarda igual, pero ya no toca la cola.
    private var runID = 0
    private var runStarted: Date?
    private var watchdog: Task<Void, Never>?
    /// Fallos seguidos por cancion: los reintentos se van espaciando (1,5 min, 3, 6... hasta 30).
    private var failures: [String: Int] = [:]

    /// La cancion que se esta analizando ahora y las que el vigilante dio por perdidas pero cuya lectura sigue viva (no se
    /// vuelven a pedir hasta que termine, para no bajar el mismo audio dos veces a la vez).
    private var runningVideoId: String?
    private var abandoned: Set<String> = []

    /// La cola lleva un buen rato con OTRA cancion: esta puede sacar su onda por su propio carril sin esperar detras.
    func shouldBypassQueue(for videoId: String) -> Bool {
        running && runningVideoId != videoId && !abandoned.contains(videoId)
            && (runStarted.map { Date().timeIntervalSince($0) > 25 } ?? false)
    }

    private func nextRetryDelay(_ videoId: String) -> TimeInterval {
        let count = (failures[videoId] ?? 0) + 1
        failures[videoId] = count
        return min(1800, 90 * pow(2, Double(count - 1)))
    }

    private init() {
        removeEmptyResultsOnce()
    }

    /// Hasta ahora, una cancion en streaming cuya direccion no se pudo pedir (o cuyo analisis fallo) quedaba como "no
    /// analizable" para siempre (un archivo vacio). Una sola vez se borran esos archivos para que se vuelvan a analizar.
    private func removeEmptyResultsOnce() {
        let flag = "automix.emptyResultsCleaned.v2"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        var removed = 0
        for url in files where url.pathExtension == "json" {
            if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0 {
                try? FileManager.default.removeItem(at: url)
                removed += 1
            }
        }
        if removed > 0 { PlaybackReport.record("automix: \(removed) analisis vacios borrados para volver a analizarlos") }
    }

    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("automix", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func fileURL(_ videoId: String) -> URL {
        directory.appendingPathComponent("\(videoId).json")
    }

    /// El resultado guardado, o `nil` si aun no se ha analizado (o no se pudo).
    func structure(for videoId: String) -> TrackStructure? {
        if let cached = memory[videoId] { return cached }
        if unusable.contains(videoId) { return nil }
        if let last = missChecked[videoId], Date().timeIntervalSince(last) < 5 { return nil }
        guard let data = try? Data(contentsOf: fileURL(videoId)) else {
            missChecked[videoId] = Date()
            return nil
        }
        if data.isEmpty {
            unusable.insert(videoId)
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(TrackStructure.self, from: data),
              decoded.version == TrackStructure.currentVersion else {
            // Version antigua: se mide otra vez.
            try? FileManager.default.removeItem(at: fileURL(videoId))
            return nil
        }
        memory[videoId] = decoded
        return decoded
    }

    /// Hay resultado (valido o "no analizable") y no hace falta pedir nada.
    func isSettled(_ videoId: String) -> Bool {
        structure(for: videoId) != nil || unusable.contains(videoId)
    }

    /// Pide analizar una cancion descargada; no hace nada si ya esta hecha o en cola.
    func request(_ videoId: String) {
        guard !isSettled(videoId), !queued.contains(videoId), videoId != runningVideoId, !abandoned.contains(videoId) else {
            return
        }
        if let later = retryAfter[videoId], later > Date() { return }
        // En streaming hay que pedir su direccion a YouTube: no se hace mientras se resuelve una cancion ni en los
        // segundos siguientes a un cambio (varias peticiones a la vez dejaban sin direccion valida a la que se quiere oir).
        if !DownloadManager.shared.isDownloaded(videoId: videoId) {
            if NowPlaying.shared.isBusyResolving { return }
            // La direccion de la que suena ya esta en la cache (no cuesta otra peticion a YouTube): se puede analizar antes.
            let wait: TimeInterval = NowPlaying.shared.videoId == videoId ? 3 : 12
            if Date().timeIntervalSince(AutoMixEngine.shared.lastSongChange) < wait { return }
        }
        // La que suena va la primera: de ella dependen la onda de la barra y la mezcla que viene.
        if NowPlaying.shared.videoId == videoId { queued.insert(videoId, at: 0) } else { queued.append(videoId) }
        drain()
    }

    private func drain() {
        guard !running else { return }
        // Se descartan las que ya no hacen falta: resueltas, con la lectura anterior aun viva o con un reintento pendiente.
        while let candidate = queued.first,
              isSettled(candidate) || abandoned.contains(candidate) || (retryAfter[candidate].map { $0 > Date() } ?? false) {
            queued.removeFirst()
        }
        guard !queued.isEmpty else { return }
        running = true
        runID += 1
        let id = runID
        runStarted = Date()
        let videoId = queued.removeFirst()
        runningVideoId = videoId
        Task { [weak self] in
            let started = Date()
            var analysis: Analysis?
            var isLocal = true
            if let source = await AutoMixSource.source(for: videoId) {
                isLocal = source.isLocal
                let url = source.url
                let local = source.isLocal
                analysis = await Task.detached(priority: .utility) { await Self.analyze(url, isLocal: local) }.value
            }
            guard let self else { return }
            self.finish(videoId, analysis: analysis, isLocal: isLocal, seconds: Date().timeIntervalSince(started), run: id)
        }
        // Vigilante: una cancion no puede tener parada la cola mas de 4 minutos (antes, una tardo 27 y las siguientes se
        // quedaron sin onda ni mezcla).
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 240_000_000_000) } catch { return }
            guard let self, self.running, self.runID == id else { return }
            let delay = self.nextRetryDelay(videoId)
            self.retryAfter[videoId] = Date().addingTimeInterval(delay)
            PlaybackReport.record(String(
                format: "automix: el analisis de %@ lleva mas de 4 min, la cola sigue con las demas (se reintentara en %.0f min)",
                videoId, delay / 60
            ))
            self.abandoned.insert(videoId)
            self.runID += 1
            self.running = false
            self.runStarted = nil
            self.runningVideoId = nil
            self.drain()
        }
    }

    /// Lo que sale de leer una cancion: si se pudo decodificar, su onda y, si tiene compas claro, su estructura.
    private typealias Analysis = (structure: TrackStructure?, wave: [Float]?, decoded: Bool)

    private func finish(_ videoId: String, analysis: Analysis?, isLocal: Bool, seconds: TimeInterval, run: Int) {
        // Si el vigilante ya dio esta cancion por perdida, su resultado se guarda pero no se toca la cola.
        let stale = run != runID
        abandoned.remove(videoId)
        // La onda de la barra sale del mismo audio: asi no se baja la cancion otra vez para ella.
        if let wave = analysis?.wave { WaveformStore.shared.store(wave, for: videoId) }
        if let result = analysis?.structure {
            failures.removeValue(forKey: videoId)
            retryAfter.removeValue(forKey: videoId)
            memory[videoId] = result
            if let data = try? JSONEncoder().encode(result) {
                try? data.write(to: fileURL(videoId), options: .atomic)
            }
            PlaybackReport.record(String(
                format: "automix: analizada %@: %.0f BPM, intro %@, estribillo final %@ (%.1f s)",
                videoId, result.bpm,
                result.introEndMs.map { "\($0 / 1000)s" } ?? "-",
                result.lastChorusEndMs.map { "\($0 / 1000)s" } ?? "-",
                seconds
            ))
        } else if stale {
            // Llego tarde y sin nada util: el vigilante ya dejo apuntado el reintento.
        } else if analysis == nil {
            // No hubo direccion (sin red, permiso de datos, todos los clientes de YouTube fallan...): es pasajero, se reintenta
            // cada vez mas tarde; no se marca como imposible.
            let delay = nextRetryDelay(videoId)
            retryAfter[videoId] = Date().addingTimeInterval(delay)
            PlaybackReport.record(String(format: "automix: %@ sin direccion para analizar, se reintentara en %.0f min", videoId, delay / 60))
        } else if analysis?.decoded == false, !isLocal {
            // En streaming el fallo puede ser pasajero (sin red, direccion caducada, lectura demasiado lenta): se reintenta.
            let delay = nextRetryDelay(videoId)
            retryAfter[videoId] = Date().addingTimeInterval(delay)
            PlaybackReport.record(String(format: "automix: %@ no se pudo leer en streaming, se reintentara en %.0f min", videoId, delay / 60))
        } else {
            // Se leyo bien pero no tiene un compas que analizar (o el archivo local no se puede leer): no se vuelve a intentar.
            unusable.insert(videoId)
            try? Data().write(to: fileURL(videoId), options: .atomic)
            PlaybackReport.record("automix: \(videoId) no se pudo analizar")
        }
        if !stale {
            watchdog?.cancel()
            running = false
            runStarted = nil
            runningVideoId = nil
            drain()
        }
    }

    // MARK: - Lectura del audio y analisis (fuera del hilo principal)

    /// Decodifica la cancion (archivo o direccion de streaming) a mono, 16 bits, 8 kHz, saca su onda y la analiza.
    nonisolated private static func analyze(_ url: URL, isLocal: Bool) async -> Analysis {
        let pcm: [Int16]?
        if isLocal {
            pcm = await decode(url)
        } else {
            pcm = decodeRemote(url)
        }
        guard let pcm, !pcm.isEmpty else { return (nil, nil, false) }
        let wave: [Float]? = pcm.count > WaveformStore.buckets * 4 ? WaveformStore.envelope(pcm) : nil
        return (TrackStructureAnalyzer.analyze(pcm), wave, true)
    }

    /// Una cancion en streaming: FFmpeg la lee de internet y la decodifica a PCM crudo en un archivo temporal.
    /// `timeout`: si la lectura no ha terminado a tiempo (direccion estrangulada, red muy lenta) se corta y se da por fallida.
    nonisolated static func decodeRemote(_ url: URL, timeout: TimeInterval = 900) -> [Int16]? {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("automix-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let arguments = ["-y", "-v", "error"] + AutoMixSource.inputOptions(for: url) + [
            "-i", url.absoluteString,
            "-vn", "-ac", "1", "-ar", String(TrackStructureAnalyzer.sampleRate),
            "-f", "s16le", temporary.path
        ]
        let done = DispatchSemaphore(value: 0)
        let session = FFmpegKit.execute(
            withArgumentsAsync: arguments,
            withCompleteCallback: { _ in done.signal() },
            withLogCallback: nil,
            withStatisticsCallback: nil
        )
        if done.wait(timeout: .now() + timeout) == .timedOut {
            session?.cancel()
            _ = done.wait(timeout: .now() + 10)
            return nil
        }
        guard ReturnCode.isSuccess(session?.getReturnCode()),
              let data = try? Data(contentsOf: temporary), data.count > 2 else { return nil }
        var samples = [Int16](repeating: 0, count: data.count / 2)
        samples.withUnsafeMutableBufferPointer { buffer in _ = data.copyBytes(to: buffer) }
        return samples
    }

    nonisolated static func decode(_ url: URL) async -> [Int16]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: TrackStructureAnalyzer.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            let count = length / MemoryLayout<Int16>.size
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: count * MemoryLayout<Int16>.size,
                    destination: base.advanced(by: start * MemoryLayout<Int16>.size)
                )
            }
            if status != kCMBlockBufferNoErr { return nil }
        }
        return reader.status == .completed ? samples : nil
    }
}
