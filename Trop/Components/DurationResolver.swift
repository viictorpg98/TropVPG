//
//  DurationResolver.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import Foundation
import Observation

/// Como mucho 3 peticiones de duracion a la vez: una portada con decenas de canciones sin duracion
/// las lanzaba todas juntas, compitiendo con la reproduccion y con lo que se estaba cargando.
actor DurationGate {
    static let shared = DurationGate()

    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrent = 3

    func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Resolves unknown track durations via the shared `InnerTubeClient`,
/// shared by every song row and grid cell.
@Observable
final class DurationResolver {
    var resolved = 0

    func effectiveDuration(known: Int) -> Int {
        known > 0 ? known : resolved
    }

    func resolve(videoId: String, knownDuration: Int) async {
        guard knownDuration <= 0 else { return }
        // Si ya se conoce no hace falta esperar turno.
        if let cached = DurationCache.get(videoId), cached > 0 {
            resolved = cached
            return
        }
        await DurationGate.shared.acquire()
        var duration: Int?
        if !Task.isCancelled {
            duration = await InnerTubeClient.tropShared.resolveDuration(videoId: videoId)
        }
        await DurationGate.shared.release()
        if let duration { resolved = duration }
    }

    func handleUpdate(_ notification: Notification, videoId: String?) {
        guard let vid = notification.userInfo?["videoId"] as? String, vid == videoId else { return }
        resolved = DurationCache.get(vid) ?? 0
    }
}
