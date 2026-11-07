//
//  DownloadsView.swift
//  Trop
//

import Combine
import SwiftUI

struct DownloadsView: View {
    @Environment(SettingsStore.self) private var settings
    private let downloadManager = DownloadManager.shared
    // Copias locales: esta pantalla no observa el gestor entero, asi que el progreso de cada descarga
    // no la redibuja (antes se reconstruia la lista completa con cada avance).
    @State private var tracks: [DownloadedTrackEntity] = DownloadManager.shared.tracks
    @State private var songs: [SongItem] = DownloadManager.shared.tracks.map { SongItem(entity: $0) }
    @State private var isLoaded = DownloadManager.shared.isLoaded
    @State private var hasActiveDownloads = DownloadManager.shared.hasActiveDownloads
    @State private var pendingRoute: DetailRoute?
    @State private var showMoreSheet = false

    var body: some View {
        Group {
            if !isLoaded {
                LoadingStateView("Loading downloads…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty && !hasActiveDownloads {
                emptyView
            } else {
                contentView
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await downloadManager.reload() }
        .task {
            if !downloadManager.isLoaded {
                await downloadManager.reload()
            }
        }
        .task {
            for await newTracks in downloadManager.$tracks.values {
                tracks = newTracks
                songs = newTracks.map { SongItem(entity: $0) }
            }
        }
        .task {
            for await loaded in downloadManager.$isLoaded.values { isLoaded = loaded }
        }
        .task {
            for await active in downloadManager.$hasActiveDownloads.values { hasActiveDownloads = active }
        }
        .detailRouteSheet(item: $pendingRoute)
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("No Downloads Yet", systemImage: "arrow.down.circle")
        } description: {
            Text("Save songs for offline listening from the player menu, or enable auto-download when you like a track.")
        } actions: {
            NavigationLink {
                DownloadSettingsView()
            } label: {
                Text("Download Settings")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(settings.accentColor)
        }
        .miniPlayerTracksScroll()
    }

    private var contentView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                header
                    .padding(.bottom, 8)

                if hasActiveDownloads {
                    ActiveDownloadsSection()
                }

                // Las filas van directamente en el contenedor perezoso: solo se construyen las visibles.
                ForEach(songs, id: \.videoId) { song in
                    VStack(spacing: 0) {
                        SongRowView(
                            song: song,
                            artSize: 48,
                            artRadius: 8,
                            onTap: { playSong(song) },
                            onNavigate: { pendingRoute = $0 }
                        )
                        Divider()
                            .padding(.leading, 76)
                    }
                }
            }
        }
        .scrollDisabled(!isLoaded)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .miniPlayerTracksScroll()
    }

    private var header: some View {
        PlaylistHeaderView(
            title: "Downloads",
            thumbnails: Array(tracks.prefix(4).compactMap(\.thumbnailUrl)),
            songCount: tracks.count,
            duration: tracks.reduce(0) { $0 + $1.duration },
            accentColor: settings.accentColor,
            onPlay: playAll,
            onShuffle: shufflePlay,
            onMore: { showMoreSheet = true }
        )
        .sheet(isPresented: $showMoreSheet) {
            DownloadsMoreSheet(songs: songs)
        }
    }

    private func playAll() {
        let songs = songs
        guard !songs.isEmpty else { return }
        NowPlaying.shared.setQueue(songs, startIndex: 0)
        NowPlaying.shared.update(with: songs[0])
        Task { await playLocal(songs[0]) }
    }

    private func shufflePlay() {
        let songs = songs.shuffled()
        guard !songs.isEmpty else { return }
        NowPlaying.shared.setQueue(songs, startIndex: 0)
        NowPlaying.shared.update(with: songs[0])
        Task { await playLocal(songs[0]) }
    }

    private func playSong(_ song: SongItem) {
        let songs = songs
        if let index = songs.firstIndex(where: { $0.videoId == song.videoId }) {
            NowPlaying.shared.setQueue(songs, startIndex: index)
        } else {
            NowPlaying.shared.setQueue([song], startIndex: 0)
        }
        NowPlaying.shared.update(with: song)
        Task { await playLocal(song) }
    }

    private func playLocal(_ song: SongItem) async {
        guard let localURL = await downloadManager.localURL(for: song.videoId) else { return }
        let artists = song.artists
        let displayArtist = artists.map(\.name).joined(separator: ", ")
        await PlayerController.shared.play(
            url: localURL.absoluteString,
            title: song.title,
            artist: displayArtist,
            videoId: song.videoId,
            duration: TimeInterval(song.duration),
            artists: artists
        )
        await MainActor.run {
            NowPlaying.shared.updateVideoAvailability()
        }
    }
}

/// Descargas en marcha. Es una vista aparte para que el progreso (que cambia muchas veces por
/// segundo) solo redibuje esta seccion, y muestra unas pocas filas aunque haya cientos en cola.
private struct ActiveDownloadsSection: View {
    @ObservedObject private var downloadManager = DownloadManager.shared
    private static let maxShown = 8

    var body: some View {
        let active = downloadManager.activeDownloads
        VStack(spacing: 0) {
            HStack {
                SectionLabel(title: "Downloading", systemImage: "arrow.down.circle")
                Spacer()
                Text(verbatim: "\(active.count)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            ForEach(Array(active.prefix(Self.maxShown)), id: \.videoId) { item in
                ActiveDownloadRow(videoId: item.videoId, progress: item.progress)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
        }
        .padding(.bottom, 16)
    }
}
