//
//  AutoPlaylistMenuSheet.swift
//  Trop
//

import SwiftUI

/// Menu de las tres tarjetas fijas de la Biblioteca (Me gusta, Descargas y Mi Top 100) al mantener pulsado.
struct AutoPlaylistMenuSheet: View {
    let info: AutoPlaylistInfo

    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsStore) private var settings

    @State private var songs: [SongItem] = []
    @State private var isLoading = true
    @State private var showClearConfirmation = false

    private var isDownloads: Bool { info.id == "downloads" }
    private var hasSongs: Bool { !songs.isEmpty }

    var body: some View {
        SheetChrome {
            headerCard
            MenuCard {
                songRow(icon: "play.fill", title: "Play") { playAll() }
                Divider()
                songRow(icon: "shuffle", title: "Shuffle") { shuffleAll() }
                Divider()
                songRow(icon: "text.insert", title: "Play Next", subtitle: "Add to the queue, next in line") { playNext() }
                Divider()
                songRow(icon: "list.bullet", title: "Add to Queue", subtitle: "Add to the end of the queue") { addToQueue() }
                if isDownloads {
                    Divider()
                    MenuRow(
                        icon: "trash",
                        title: "Remove All Downloads",
                        subtitle: "Delete all offline tracks",
                        destructive: true
                    ) {
                        showClearConfirmation = true
                    }
                } else {
                    Divider()
                    songRow(
                        icon: "arrow.down.circle",
                        title: "Download",
                        subtitle: "Download all songs for offline playback"
                    ) { downloadAll() }
                }
            }
        }
        .task { await load() }
        .destructiveConfirm(
            "Remove All Downloads?",
            isPresented: $showClearConfirmation,
            message: Text("This permanently deletes all offline tracks from your device."),
            confirmTitle: "Remove All"
        ) {
            Task {
                await DownloadManager.shared.deleteAll()
                dismiss()
            }
        }
    }

    // MARK: - Cabecera

    private var headerCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [settings.accentColor.opacity(0.55), settings.accentColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: info.icon)
                    .font(.title2)
                    .foregroundColor(.white)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(info.title))
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let subtitle = info.subtitle {
                        Text(LocalizedStringKey(subtitle))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func songRow(
        icon: String,
        title: String,
        subtitle: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        MenuRow(icon: icon, title: title, subtitle: subtitle, action: action)
            .disabled(!hasSongs)
            .opacity(hasSongs ? 1 : 0.4)
    }

    // MARK: - Carga

    private func load() async {
        switch info.id {
        case "liked":
            songs = ((try? await DatabaseService.shared.fetchLikedSongs()) ?? []).toSongItems()
        case "top100":
            songs = ((try? await DatabaseService.shared.fetchTopSongs(limit: 100)) ?? []).toSongItems()
        default:
            songs = DownloadManager.shared.tracks.map { SongItem(entity: $0) }
        }
        isLoading = false
    }

    // MARK: - Acciones

    private func playAll() {
        PlaybackQueue.play(songs, log: Log.libraryView, context: "Library card play")
        dismiss()
    }

    private func shuffleAll() {
        PlaybackQueue.playShuffled(songs, log: Log.libraryView, context: "Library card shuffle")
        dismiss()
    }

    private func playNext() {
        let np = NowPlaying.shared
        let insertIndex = min(np.queueIndex + 1, np.queueSongs.count)
        np.queueSongs.insert(contentsOf: songs, at: insertIndex)
        np.repairQueueIndex()
        np.persistQueueState()
        dismiss()
    }

    private func addToQueue() {
        let np = NowPlaying.shared
        np.queueSongs.append(contentsOf: songs)
        np.persistQueueState()
        dismiss()
    }

    private func downloadAll() {
        for song in songs {
            Task { await DownloadManager.shared.download(song: song) }
        }
        dismiss()
    }
}
