//
//  LikeStore.swift
//  Trop
//
//  Created by 686udjie on 28/08/2026.
//

import Combine
import Foundation
import GRDB

@MainActor
class LikeStore: ObservableObject {
    static let shared = LikeStore()

    @Published private(set) var liked: [String: Bool] = [:]
    /// Canciones marcadas con "No me gusta" (se guardan en el dispositivo).
    @Published private(set) var disliked: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "likeStore.disliked") ?? []
    )

    private init() {
        Task { await refresh() }
    }

    func isLiked(videoId: String) -> Bool {
        liked[videoId] ?? false
    }

    func isDisliked(videoId: String) -> Bool {
        disliked.contains(videoId)
    }

    private func setDisliked(_ value: Bool, videoId: String) {
        var next = disliked
        if value { next.insert(videoId) } else { next.remove(videoId) }
        disliked = next
        UserDefaults.standard.set(Array(next), forKey: "likeStore.disliked")
    }

    /// "No me gusta": si estaba en Me gusta lo quita; volver a pulsar lo deshace.
    func toggleDislike(song: SongItem) async {
        let videoId = song.videoId
        let target = !isDisliked(videoId: videoId)
        setDisliked(target, videoId: videoId)

        do {
            if target {
                if isLiked(videoId: videoId) {
                    var updated = liked
                    updated[videoId] = false
                    liked = updated
                    try await SyncBridge.mutations.unlikeSong(videoId: videoId)
                }
                _ = try await InnerTubeClient.tropShared.dislike(videoId: videoId)
            } else {
                _ = try await InnerTubeClient.tropShared.unlike(videoId: videoId)
            }
        } catch {
            setDisliked(!target, videoId: videoId)
            Log.sync.error("toggleDislike failed for videoId=\(videoId) target=\(target) error: \(error)")
        }
    }

    func refresh() async {
        let songs = (try? await DatabaseService.shared.fetchAllLikedSongs()) ?? []
        var dict: [String: Bool] = [:]
        for song in songs where song.liked {
            dict[song.id] = true
        }
        liked = dict
    }

    func toggle(song: SongItem) async {
        let videoId = song.videoId
        let target = !isLiked(videoId: videoId)

        var updated = liked
        updated[videoId] = target
        liked = updated
        if target { setDisliked(false, videoId: videoId) }

        do {
            if target {
                try await SyncBridge.mutations.likeSong(videoId: videoId)
                if SettingsStore.shared.autoDownloadOnLike {
                    await DownloadManager.shared.download(song: song)
                }
            } else {
                try await SyncBridge.mutations.unlikeSong(videoId: videoId)
            }
        } catch {
            var reverted = liked
            reverted[videoId] = !target
            liked = reverted
            Log.sync.error("toggleLike failed for videoId=\(videoId) target=\(target) error: \(error) (\(error.localizedDescription))")
        }
    }
}
