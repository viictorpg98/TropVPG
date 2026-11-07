//
//  ViewCountStore.swift
//  Trop
//

import Foundation

/// Reproducciones de una canción en YouTube, pedidas bajo demanda (solo las filas
/// visibles). Máximo 3 peticiones a la vez. Los datos se guardan en disco, así que al volver a abrir
/// la app las cifras ya conocidas salen al instante y no se vuelven a pedir.
actor ViewCountStore {
    static let shared = ViewCountStore()

    private static let maxStored = 3000
    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("view-counts.json")
    }()

    private var cache: [String: Int64]
    private var inFlight: [String: Task<Int64?, Never>] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrent = 3
    private var saveTask: Task<Void, Never>?

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let stored = try? JSONDecoder().decode([String: Int64].self, from: data) {
            cache = stored
        } else {
            cache = [:]
        }
    }

    func views(for videoId: String) async -> Int64? {
        if let cached = cache[videoId] { return cached }
        if let task = inFlight[videoId] { return await task.value }

        let task = Task<Int64?, Never> { await self.fetch(videoId) }
        inFlight[videoId] = task
        let value = await task.value
        inFlight[videoId] = nil
        if let value {
            cache[videoId] = value
            scheduleSave()
        }
        return value
    }

    private func fetch(_ videoId: String) async -> Int64? {
        await acquire()
        let response: PlayerResponse? = try? await InnerTubeClient.tropShared.playerResponse(videoId: videoId)
        release()
        guard let raw = response?.videoDetails?.viewCount, let count = Int64(raw) else { return nil }
        return count
    }

    /// Guarda en disco unos segundos despues del ultimo cambio (una sola escritura por rafaga).
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.writeToDisk()
        }
    }

    private func writeToDisk() {
        if cache.count > Self.maxStored {
            for key in cache.keys.prefix(cache.count - Self.maxStored) { cache.removeValue(forKey: key) }
        }
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
