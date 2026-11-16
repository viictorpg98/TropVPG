//
//  DetailedWaveformStore.swift
//  Trop
//
//  La forma de onda con detalle (unas 1.500 barras por cancion, no las 160 de la barra de progreso) para el editor de mezclas. Se lee la
//  cancion entera una vez (a 8 kHz y en mono) cuando se abre el editor y se guarda en memoria (las ultimas 8): asi mover los ajustes no
//  vuelve a leer nada. Sin direccion que leer (sin Wi-Fi, 403...) el editor sigue con la onda normal.
//

import Foundation

@MainActor
final class DetailedWaveformStore {
    static let shared = DetailedWaveformStore()

    struct Entry {
        let wave: [Float]
        /// Lo que dura la cancion leida (lo que cubren todas las barras).
        let seconds: Double
    }

    private var cache: [String: Entry] = [:]
    private var order: [String] = []
    private var loading = Set<String>()
    private static let capacity = 8
    private static let buckets = 1_500

    private init() {}

    func entry(for videoId: String) -> Entry? { cache[videoId] }

    /// Lee la cancion y guarda su onda (no hace nada si ya esta, si se esta leyendo o si es una cancion larga). Devuelve si hay onda.
    @discardableResult
    func load(_ videoId: String) async -> Bool {
        if cache[videoId] != nil { return true }
        guard !loading.contains(videoId), !TrackAnalysisStore.shared.isLong(videoId) else { return false }
        loading.insert(videoId)
        defer { loading.remove(videoId) }
        guard let source = await AutoMixSource.source(for: videoId) else { return false }
        let url = source.url
        let buckets = Self.buckets
        let result = await Task.detached(priority: .utility) {
            MixRenderer.detailedWaveform(url: url, maxSeconds: 600, buckets: buckets)
        }.value
        guard let result, result.wave.count > 8 else {
            PlaybackReport.record("mezcla: no se pudo leer \(videoId) para su onda con detalle")
            return false
        }
        cache[videoId] = Entry(wave: result.wave, seconds: result.seconds)
        order.removeAll { $0 == videoId }
        order.append(videoId)
        while order.count > Self.capacity {
            cache[order.removeFirst()] = nil
        }
        return true
    }
}
