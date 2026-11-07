//
//  ViewCountStore.swift
//  Trop
//

import Foundation

/// Reproducciones de una canción en YouTube, pedidas bajo demanda (solo las filas
/// visibles) y guardadas en memoria. Máximo 3 peticiones a la vez.
actor ViewCountStore {
    static let shared = ViewCountStore()

    private var cache: [String: Int64] = [:]
    private var inFlight: [String: Task<Int64?, Never>] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrent = 3

    func views(for videoId: String) async -> Int64? {
        if let cached = cache[videoId] { return cached }
        if let task = inFlight[videoId] { return await task.value }

        let task = Task<Int64?, Never> { await self.fetch(videoId) }
        inFlight[videoId] = task
        let value = await task.value
        inFlight[videoId] = nil
        if let value { cache[videoId] = value }
        return value
    }

    private func fetch(_ videoId: String) async -> Int64? {
        await acquire()
        let response: PlayerResponse? = try? await InnerTubeClient.tropShared.playerResponse(videoId: videoId)
        release()
        guard let raw = response?.videoDetails?.viewCount, let count = Int64(raw) else { return nil }
        return count
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
