//
//  SongRowView.swift
//  Trop
//
// Created by 686udjie on 12/09/2026.
//

import Combine
import SwiftUI

/// Trailing ⋮ button shared by every song row.
struct MoreButton: View {
    @Environment(SettingsStore.self) private var settings
    let action: () -> Void

    var body: some View {
        Button(action: action, label: {
            Text("⋮")
                .font(.body.weight(.black))
                .foregroundStyle(settings.accentColor)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        })
        .buttonStyle(.plain)
        .accessibilityLabel("More")
    }
}

/// Unified song row: artwork + title + artists • duration + overflow menu.
/// Replaces AlbumSongRow, PlaylistSongRow, PodcastEpisodeRow, DownloadedSongRow
/// and the song branch of YouTubeListItemView.
struct SongRowView: View {
    let song: SongItem
    var artSize: CGFloat = DesignTokens.thumbSmall
    var artRadius: CGFloat = DesignTokens.thumbRadius
    var onTap: () -> Void
    var onNavigate: ((DetailRoute) -> Void)?
    /// Fila ancha: anade reproducciones y la marca de descargada.
    var detailed: Bool = false

    @State private var durations = DurationResolver()
    @State private var showSongMenu = false
    @State private var fetchedViews: Int64?
    /// Estado de descarga de ESTA cancion; solo cambia cuando cambia el de esta cancion.
    @State private var downloadState: DownloadManager.DownloadState
    @State private var network = NetworkMonitor.shared

    /// Sin conexion, lo que no esta descargado se ve apagado y avisa al pulsarlo.
    private var isUnavailableOffline: Bool {
        if case .completed = downloadState { return false }
        return !network.isOnline
    }

    private func handleTap() {
        if case .completed = downloadState {
            onTap()
        } else if network.requireConnection(NSLocalizedString("No connection: this song isn't downloaded.", comment: "")) {
            onTap()
        }
    }

    init(
        song: SongItem,
        artSize: CGFloat = DesignTokens.thumbSmall,
        artRadius: CGFloat = DesignTokens.thumbRadius,
        onTap: @escaping () -> Void,
        onNavigate: ((DetailRoute) -> Void)? = nil,
        detailed: Bool = false
    ) {
        self.song = song
        self.artSize = artSize
        self.artRadius = artRadius
        self.onTap = onTap
        self.onNavigate = onNavigate
        self.detailed = detailed
        _downloadState = State(initialValue: DownloadManager.shared.state(for: song.videoId))
    }

    private var subtitleText: String {
        let duration = durations.effectiveDuration(known: song.duration)
        guard detailed else { return song.subtitleLine(duration: duration) }
        var parts: [String] = []
        if !song.artistNamesDisplay.isEmpty { parts.append(song.artistNamesDisplay) }
        if let views = song.viewCount ?? fetchedViews, views > 0 { parts.append(CountText.plays(views)) }
        let length = duration.formattedDuration
        if !length.isEmpty { parts.append(length) }
        return parts.joined(separator: " • ")
    }

    var body: some View {
        HStack(spacing: DesignTokens.rowSpacing) {
            AsyncImageView(url: song.thumbnailUrl, keepsVideoFrame: song.isVideo == true)
                .frame(width: artSize, height: artSize)
                .clipShape(RoundedRectangle(cornerRadius: artRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(detailed ? Font.body : Font.subheadline)
                    .fontWeight(detailed ? .semibold : .medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if case .completed = downloadState {
                        DownloadedBadge()
                    }
                    if detailed, song.isExplicit {
                        ExplicitBadge()
                    }
                    Text(subtitleText)
                        .font(detailed ? Font.subheadline : Font.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 2) {
                MoreButton {
                    showSongMenu = true
                }
            }
            .sheet(isPresented: $showSongMenu) {
                SongMenuSheet(
                    song: song,
                    onNavigate: { onNavigate?($0) }
                )
            }
        }
        .background(DownloadCellProgressView(state: downloadState))
        .padding(.horizontal, detailed ? 0 : DesignTokens.screenHPadding)
        .padding(.vertical, DesignTokens.rowVPadding)
        .opacity(isUnavailableOffline ? 0.4 : 1)
        .pressable(onTap: handleTap, onLongPress: { showSongMenu = true })
        .task { await durations.resolve(videoId: song.videoId, knownDuration: song.duration) }
        .task(id: song.videoId) {
            guard detailed, song.viewCount == nil else { return }
            fetchedViews = await ViewCountStore.shared.views(for: song.videoId)
        }
        .task(id: song.videoId) {
            for await state in DownloadManager.shared.statePublisher(for: song.videoId).values {
                downloadState = state
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .durationDidUpdate)) { notification in
            durations.handleUpdate(notification, videoId: song.videoId)
        }
    }
}

/// Icono de "descargada" junto al subtitulo de una fila.
struct DownloadedBadge: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

/// Insignia "E" de contenido explicito.
struct ExplicitBadge: View {
    var body: some View {
        Text(verbatim: "E")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.75))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary))
    }
}

/// Full-cell progress background shown while a song is downloading.
struct DownloadCellProgressView: View {
    let state: DownloadManager.DownloadState

    var body: some View {
        GeometryReader { geo in
            if case .downloading(let fraction) = state {
                Color.accentColor.opacity(0.25)
                    .frame(
                        width: geo.size.width * CGFloat(min(max(fraction, 0), 1)),
                        height: geo.size.height
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: state)
    }
}
