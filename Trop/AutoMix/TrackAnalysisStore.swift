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
    private var queued: [String] = []
    private var running = false
    /// Canciones en streaming cuyo analisis fallo (red...): no se guardan como "no analizables", se reintentan mas tarde.
    private var retryAfter: [String: Date] = [:]

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
        guard let data = try? Data(contentsOf: fileURL(videoId)) else { return nil }
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
        guard !isSettled(videoId), !queued.contains(videoId) else { return }
        if let later = retryAfter[videoId], later > Date() { return }
        // En streaming hay que pedir su direccion a YouTube: no se hace mientras se resuelve una cancion ni en los
        // segundos siguientes a un cambio (varias peticiones a la vez dejaban sin direccion valida a la que se quiere oir).
        if !DownloadManager.shared.isDownloaded(videoId: videoId) {
            if NowPlaying.shared.isBusyResolving { return }
            if Date().timeIntervalSince(AutoMixEngine.shared.lastSongChange) < 12 { return }
        }
        queued.append(videoId)
        drain()
    }

    private func drain() {
        guard !running, !queued.isEmpty else { return }
        running = true
        let videoId = queued.removeFirst()
        Task { [weak self] in
            let started = Date()
            var result: TrackStructure?
            var isLocal = true
            if let source = await AutoMixSource.source(for: videoId) {
                isLocal = source.isLocal
                let url = source.url
                let local = source.isLocal
                result = await Task.detached(priority: .utility) { await Self.analyze(url, isLocal: local) }.value
            }
            guard let self else { return }
            self.finish(videoId, result: result, seconds: Date().timeIntervalSince(started), permanent: isLocal)
        }
    }

    private func finish(_ videoId: String, result: TrackStructure?, seconds: TimeInterval, permanent: Bool) {
        if let result {
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
        } else if permanent {
            unusable.insert(videoId)
            try? Data().write(to: fileURL(videoId), options: .atomic)
            PlaybackReport.record("automix: \(videoId) no se pudo analizar")
        } else {
            // En streaming el fallo puede ser pasajero (sin red, direccion caducada): se reintenta en un rato.
            retryAfter[videoId] = Date().addingTimeInterval(90)
            PlaybackReport.record("automix: \(videoId) no se pudo analizar en streaming, se reintentara")
        }
        running = false
        drain()
    }

    // MARK: - Lectura del audio y analisis (fuera del hilo principal)

    /// Decodifica la cancion (archivo o direccion de streaming) a mono, 16 bits, 8 kHz y la analiza.
    nonisolated private static func analyze(_ url: URL, isLocal: Bool) async -> TrackStructure? {
        let pcm: [Int16]?
        if isLocal {
            pcm = await decode(url)
        } else {
            pcm = decodeRemote(url)
        }
        guard let pcm, !pcm.isEmpty else { return nil }
        return TrackStructureAnalyzer.analyze(pcm)
    }

    /// Una cancion en streaming: FFmpeg la lee de internet y la decodifica a PCM crudo en un archivo temporal.
    nonisolated static func decodeRemote(_ url: URL) -> [Int16]? {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("automix-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let arguments = ["-y", "-v", "error"] + AutoMixSource.inputOptions(for: url) + [
            "-i", url.absoluteString,
            "-vn", "-ac", "1", "-ar", String(TrackStructureAnalyzer.sampleRate),
            "-f", "s16le", temporary.path
        ]
        let session = FFmpegKit.execute(withArguments: arguments)
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
