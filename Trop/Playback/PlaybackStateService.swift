//
// PlaybackStateService.swift
// Trop
//
// Created by 686udjie on 30/06/2026.
//

import Foundation
import GRDB

actor PlaybackStateService {
    nonisolated static let shared = PlaybackStateService()
    private let db = DatabaseService.shared
    private let innerTube = InnerTubeClient.tropShared

    private let historyDurationThreshold: TimeInterval = 30
    private var currentVideoId: String?
    private var playbackStartTime: Date?
    private var isTracking = false
    private var hasRecordedPlayback = false
    private var periodicCheckTask: Task<Void, Never>?
    private var bankedPlayTimeMs: Int64 = 0
    /// Tiempo en pausa de la cancion que suena (no cuenta como escuchado).
    private var pausedSince: Date?
    private var pausedTotal: TimeInterval = 0

    private init() {}

    /// La musica se pausa o se reanuda.
    func setPlaying(_ playing: Bool) {
        guard isTracking else { return }
        if playing {
            if let since = pausedSince {
                pausedTotal += Date().timeIntervalSince(since)
                pausedSince = nil
            }
        } else if pausedSince == nil {
            pausedSince = Date()
        }
    }

    /// Segundos sonados desde `start`, sin las pausas.
    private func playedElapsed(from start: Date) -> TimeInterval {
        var paused = pausedTotal
        if let since = pausedSince { paused += Date().timeIntervalSince(since) }
        return max(0, Date().timeIntervalSince(start) - paused)
    }

    func startTracking(videoId: String) {
        currentVideoId = videoId
        playbackStartTime = Date()
        isTracking = true
        hasRecordedPlayback = false
        bankedPlayTimeMs = 0
        pausedSince = nil
        pausedTotal = 0
        Log.playbackState.debug("Started tracking videoId=\(videoId)")

        periodicCheckTask?.cancel()
        periodicCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, let start = await self.playbackStartTime, await self.isTracking else { return }
                let elapsed = await self.playedElapsed(from: start)
                let current = await self.currentVideoId ?? ""
                // Bank every 5s chunk so skipped tracks still count toward Top 100.
                await self.bankPlayTime(videoId: current, elapsedMs: Int64(elapsed * 1000), minimumMs: 5_000)
                if elapsed >= self.historyDurationThreshold, !(await self.hasRecordedPlayback) {
                    await self.firePlayback(videoId: current, playTimeMs: Int64(elapsed * 1000))
                }
            }
        }
    }

    func stopTracking() async {
        periodicCheckTask?.cancel()
        periodicCheckTask = nil

        guard isTracking, let videoId = currentVideoId, let start = playbackStartTime else {
            Log.playbackState.debug("stopTracking called but no active tracking")
            reset()
            return
        }
        let elapsed = playedElapsed(from: start)
        Log.playbackState.debug("Stopped tracking videoId=\(videoId) totalElapsed=\(String(format: "%.1f", elapsed))s")
        defer { reset() }

        // Bank the remainder first (down to 1s) so short plays count.
        await bankPlayTime(videoId: videoId, elapsedMs: Int64(elapsed * 1000), minimumMs: 1_000)
        if elapsed >= historyDurationThreshold, !hasRecordedPlayback {
            await firePlayback(videoId: videoId, playTimeMs: Int64(elapsed * 1000))
        } else if elapsed < historyDurationThreshold {
            Log.playbackState.debug(
                "Elapsed \(String(format: "%.1f", elapsed))s below threshold \(self.historyDurationThreshold)s — skipping history recording"
            )
        }
    }

    private func firePlayback(videoId: String, playTimeMs: Int64) async {
        hasRecordedPlayback = true
        await recordPlayback(videoId: videoId, playTimeMs: playTimeMs)
    }

    @discardableResult
    private func bankPlayTime(videoId: String, elapsedMs: Int64, minimumMs: Int64) async -> Int64 {
        guard SettingsStore.shared.trackPlayHistory else { return 0 }
        let delta = elapsedMs - bankedPlayTimeMs
        guard delta >= minimumMs, delta > 0, !videoId.isEmpty else { return 0 }
        do {
            await ensureSongEntity(videoId: videoId)
            try await db.incrementTotalPlayTime(songId: videoId, playTimeMs: delta)
            bankedPlayTimeMs = elapsedMs
            return delta
        } catch {
            Log.playbackState.error("Failed to bank play time: \(error)")
            return 0
        }
    }

    /// Inserts the song row when missing (title/artwork from the queue),
    /// so banking and history never hit a missing row. No-op when present.
    private func ensureSongEntity(videoId: String) async {
        let queueSong: SongItem? = await MainActor.run {
            NowPlaying.shared.queueSongs.first(where: { $0.videoId == videoId })
        }
        do {
            try await db.write { db in
                guard try SongEntity.fetchOne(db, key: videoId) == nil else { return }
                let entity = SongEntity(
                    id: videoId,
                    title: queueSong?.title ?? videoId,
                    artistName: queueSong.flatMap { $0.artists.first?.name ?? $0.artistNamesDisplay },
                    albumName: queueSong?.album,
                    duration: queueSong?.duration ?? 0,
                    thumbnailUrl: queueSong?.thumbnailUrl ?? ArtworkURLs.fallback(for: videoId),
                    liked: false,
                    totalPlayTime: 0,
                    inLibrary: nil,
                    libraryAddToken: "",
                    libraryRemoveToken: "",
                    isEpisode: false,
                    isUploaded: false,
                    isVideo: false,
                    createDate: Date(),
                    modifyDate: Date()
                )
                try entity.insert(db, onConflict: .ignore)
                Log.playbackState.debug("Ensured SongEntity for \(videoId)")
            }
        } catch {
            Log.playbackState.error("Failed to ensure song entity: \(error)")
        }
    }

    private func recordPlayback(videoId: String, playTimeMs: Int64) async {
        guard SettingsStore.shared.trackPlayHistory else {
            Log.playbackState.debug("Play history tracking disabled — skipping recording")
            return
        }
        Log.playbackState.debug("Recording playback videoId=\(videoId) playTimeMs=\(playTimeMs)")
        await ensureSongEntity(videoId: videoId)
        do {
            try await db.write { db in
                var event = Event(id: nil, songId: videoId, timestamp: Date(), playTime: playTimeMs)
                event = try event.inserted(db, onConflict: .ignore)
                Log.playbackState.debug("Local event recorded id=\(event.id ?? 0)")
            }

            let now = Date()
            let calendar = Calendar.current
            try await db.incrementPlayCount(songId: videoId, year: calendar.component(.year, from: now), month: calendar.component(.month, from: now))
            Log.playbackState.debug("Play count incremented")

            let banked = await bankPlayTime(videoId: videoId, elapsedMs: playTimeMs, minimumMs: 0)
            if banked > 0 {
                Log.playbackState.debug("Total play time incremented (+\(banked)ms)")
            }

            let trackingUrl = await getCachedTrackingUrl(videoId: videoId)
            if let trackingUrl {
                Log.playbackState.debug("Sending playback to YTM for tracking")
                Task {
                    do {
                        try await InnerTubeClient.tropShared.registerPlayback(trackingUrl: trackingUrl)
                    } catch {
                        Log.playbackState.error("YTM playback registration failed: \(error)")
                    }
                }
            } else {
                Log.playbackState.debug("No cached tracking URL for videoId=\(videoId) — skipping YTM registration")
            }
        } catch {
            Log.playbackState.error("Failed to record playback: \(error)")
        }
    }

    private func getCachedTrackingUrl(videoId: String) async -> String? {
        if let format = try? await db.fetchOne(FormatEntity.self, key: videoId),
           let url = format.playbackUrl {
            return url
        }
        return nil
    }

    private func reset() {
        currentVideoId = nil
        playbackStartTime = nil
        isTracking = false
        bankedPlayTimeMs = 0
        pausedSince = nil
        pausedTotal = 0
    }
}
