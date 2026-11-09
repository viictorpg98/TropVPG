//
//  QueueView.swift
//  Trop
//
//  Created by 686udjie on 16/07/2026.
//

import SwiftUI

struct QueueView<ProgressSlider: View>: View {
    private let np = NowPlaying.shared
    private let player = PlayerController.shared
    @ObservedObject private var likeStore = LikeStore.shared

    /// Que parte se dibuja: todo junto (solo en modo video), la cabecera con la cancion o el panel con la lista.
    enum Part { case all, header, list }
    var part: Part = .all

    @Binding var showQueue: Bool
    @Binding var isShuffleOn: Bool
    @Binding var isRepeatOn: Bool
    @Binding var editingProgress: Float
    @Binding var isEditingSlider: Bool
    let pendingRoute: Binding<DetailRoute?>
    @ViewBuilder var progressSlider: () -> ProgressSlider
    var isVideoMode: Bool = false

    @State private var showSongMenu = false

    var body: some View {
        queueContent
            .simultaneousGesture(backSwipeGesture)
    }

    private var backSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onEnded { value in
                let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                guard value.startLocation.x <= 28,
                      isHorizontal,
                      value.translation.width > 80 else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    if isVideoMode {
                        np.isVideoMode = false
                        showQueue = false
                    } else {
                        showQueue = false
                    }
                }
            }
    }

    /// Una fila de la cola con identidad estable.
    private struct QueueEntry: Identifiable {
        let id: String
        let index: Int
        let song: SongItem
    }

    private var queueEntries: [QueueEntry] {
        var seen: [String: Int] = [:]
        return np.queueSongs.enumerated().map { index, song in
            let occurrence = seen[song.videoId, default: 0]
            seen[song.videoId] = occurrence + 1
            return QueueEntry(id: "\(song.videoId)#\(occurrence)", index: index, song: song)
        }
    }

    // MARK: - Queue Content

    private var queueContent: some View {
        VStack(spacing: 0) {
            if part == .header {
                queueHeader
                    .padding(.horizontal, 20)
            } else {
                if part == .all, !isVideoMode {
                    queueHeader
                        .padding(.horizontal, 20)
                    playbackPillsRow
                }

                queueListHeaderRow

                queueList

                if isVideoMode {
                    playbackPillsRow
                    PlayerTransportAirPlayFooter(
                        isPlaying: np.isPlaying,
                        hasPrevious: np.hasPrevious,
                        hasNext: np.hasNext,
                        onPrevious: { np.playPrevious() },
                        onPlayPause: { player.togglePlayPause() },
                        onNext: { np.playNext() }
                    )
                }
            }
        }
    }

    private var queueList: some View {
            ScrollViewReader { proxy in
                let entries = queueEntries
                List {
                    if np.queueSongs.isEmpty {
                        emptyQueueRow
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        // Cada fila tiene una identidad propia que acompaña a su cancion (la cancion y cuantas veces ya
                        // salio antes en la cola, por si esta repetida). Antes era la posicion: al soltar una cancion en
                        // otro sitio las filas no se movian, cambiaban de contenido, y se veia un "refresco" en vez del
                        // movimiento.
                        ForEach(entries) { entry in
                            queueRow(song: entry.song, index: entry.index)
                        }
                        .onMove(perform: np.moveQueueSongs)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.colorScheme, .dark)
                .scrollIndicators(.hidden)
                .layoutPriority(1)
                .onAppear {
                    if entries.indices.contains(np.queueIndex) {
                        proxy.scrollTo(entries[np.queueIndex].id, anchor: .center)
                    }
                }
            }
    }

    // MARK: - Queue Header

    private var queueHeader: some View {
        HStack(spacing: 12) {
            if let uiImage = np.thumbnailUIImage {
                let cropped = uiImage.centerCroppedSquare()
                Image(uiImage: cropped)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 64, height: 64)
            }

            PlayerTitleBlock(title: np.title, artist: np.displayArtist, videoId: np.videoId)

            Spacer()

            if let song = np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex] : nil {
                let liked = likeStore.isLiked(videoId: song.videoId)
                PlayerPillButton(
                    systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                    isActive: liked,
                    accessibility: "Like"
                ) {
                    Task { await likeStore.toggle(song: song) }
                }
                PlayerAirPlayControl()
                PlayerOptionsButton(color: .white.opacity(0.6)) {
                    showSongMenu = true
                }
                .sheet(isPresented: $showSongMenu) {
                    SongMenuSheet(
                        song: song,
                        onNavigate: { pendingRoute.wrappedValue = $0 }
                    )
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
                showQueue = false
            }
        }
    }

    // MARK: - Queue Sub-Views

    private var playbackPillsRow: some View {
        HStack(spacing: 10) {
            pillButton(isOn: $isShuffleOn, icon: "shuffle") {
                if isShuffleOn {
                    np.shuffleQueue()
                } else {
                    np.disableShuffle()
                }
            }
            pillButton(isOn: $isRepeatOn, icon: isRepeatOn ? "repeat.1" : "repeat")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    /// Aleatorio / repetir: misma estetica que los botones del reproductor (cristal; encendido, relleno blanco).
    private func pillButton(isOn: Binding<Bool>, icon: String, action: (() -> Void)? = nil) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            action?()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? Color.black : Color.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Capsule().fill(isOn.wrappedValue ? Color.white : Color.clear))
                .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isOn.wrappedValue)
    }

    private var queueListHeaderRow: some View {
        VStack(spacing: 6) {
            if part == .list {
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(width: 36, height: 4)
                    .padding(.top, 2)
            }
            queueListTitleRow
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard part == .list else { return }
            closeQueue()
        }
        .gesture(
            DragGesture(minimumDistance: 10).onEnded { value in
                guard part == .list, value.translation.height > 24 else { return }
                closeQueue()
            }
        )
    }

    private func closeQueue() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
            showQueue = false
        }
    }

    private var queueListTitleRow: some View {
        HStack {
            Text("Queue")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .textCase(.uppercase)

            if np.queueSongs.count > 1 {
                Text("\(np.queueSongs.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var emptyQueueRow: some View {
        HStack {
            Spacer()
            Text("Queue is empty")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
        }
        .padding(.vertical, 24)
    }

    // MARK: - Actions

    private func queueRow(song: SongItem, index: Int) -> some View {
        let isCurrent = index == np.queueIndex

        return Button {
            playSong(at: index)
        } label: {
            QueueSongRow(
                song: song,
                isCurrent: isCurrent,
                isPlayed: index < np.queueIndex
            )
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowBackground(
            Group {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.08))
                        .padding(.horizontal, 12)
                }
            }
        )
        .listRowSeparator(.hidden)
        .onDrag {
            NSItemProvider(object: song.videoId as NSString)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                withAnimation(.spring(response: 0.3)) {
                    removeSong(at: index)
                }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func playSong(at index: Int) {
        guard np.queueSongs.indices.contains(index) else { return }
        np.lastManualSkipTime = Date()
        np.queueIndex = index
        np.playCurrentSong(logContext: "resolveAndPlay", manageResolvingFlag: false)
    }

    private func removeSong(at index: Int) {
        guard np.queueSongs.indices.contains(index) else { return }
        let wasCurrent = index == np.queueIndex
        let removedVideoId = np.queueSongs[index].videoId
        np.queueSongs.remove(at: index)
        if wasCurrent {
            if np.queueSongs.isEmpty {
                np.queueIndex = 0
                np.isPlaying = false
                np.persistQueueState()
                Task { @MainActor in PlayerController.shared.setPaused(true) }
                return
            }
            let nextIndex = min(index, np.queueSongs.count - 1)
            np.queueIndex = nextIndex
            let song = np.queueSongs[nextIndex]
            np.update(with: song)
            loggedTask(Log.nowPlaying, "removeSong auto-play failed") {
                try await PlaybackManager.shared.resolveAndPlay(videoId: song.videoId)
            }
        } else {
            np.repairQueueIndex()
        }
        np.persistQueueState()
        if !wasCurrent && removedVideoId == np.videoId {
            np.repairQueueIndex()
        }
    }
}

// MARK: - Queue Song Row

struct QueueSongRow: View {
    let song: SongItem
    var isCurrent = false
    var isPlayed = false
    @State private var network = NetworkMonitor.shared

    var body: some View {
        HStack(spacing: 12) {
            AsyncImageView(url: AudioCounterpartStore.shared.thumbnailURL(for: song))
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isPlayed ? 0.5 : 1)
                .overlay {
                    if isCurrent {
                        // Esta es la que suena (como el ecualizador de YouTube Music).
                        ZStack {
                            RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45))
                            Image(systemName: "waveform")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .symbolEffect(.variableColor.iterative, isActive: NowPlaying.shared.isPlaying)
                        }
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(
                    text: song.title,
                    font: .subheadline.weight(isCurrent ? .semibold : .medium),
                    frameHeight: 20,
                    textColor: titleColor
                )

                let artistStr = song.artists.map(\.name).joined(separator: ", ")
                let subtitle = song.duration > 0
                    ? (artistStr.isEmpty ? "" : artistStr + " · ") + DurationFormat.playbackTime(TimeInterval(song.duration))
                    : artistStr
                if !subtitle.isEmpty {
                    HStack(spacing: 4) {
                        if song.isExplicit { ExplicitBadge() }
                        SubtitleWithDownloadMark(videoId: song.videoId, text: subtitle)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(isPlayed ? 0.35 : 0.6))
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.leading, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.25), value: isCurrent)
        // Sin conexion, lo que no esta descargado se ve apagado (la actual no).
        .opacity(!network.isOnline && !isCurrent && !DownloadManager.shared.isDownloaded(videoId: song.videoId) ? 0.4 : 1)
    }

    private var titleColor: Color {
        isPlayed && !isCurrent ? Color.white.opacity(0.45) : .white
    }
}

// MARK: - Asa de la cola (cerrada)

/// El hueco bajo los controles: "Cola · siguiente cancion". Tocar o deslizar hacia arriba abre la cola desde abajo.
struct QueueHandle: View {
    let onOpen: () -> Void
    private let np = NowPlaying.shared

    private var nextTitle: String? {
        np.queueSongs.indices.contains(np.queueIndex + 1) ? np.queueSongs[np.queueIndex + 1].title : nil
    }

    var body: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 36, height: 4)

            HStack(spacing: 6) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                (Text("Queue") + Text(nextTitle.map { " · \($0)" } ?? ""))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .gesture(
            DragGesture(minimumDistance: 8).onEnded { value in
                if value.translation.height < -20 { onOpen() }
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("Queue"))
    }
}
