//
//  QueueView.swift
//  Trop
//
//  Created by 686udjie on 16/07/2026.
//

import SwiftUI
import UIKit

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
    /// Cuando se toco por ultima vez la lista (si la estas moviendo, no se desplaza sola).
    @State private var lastListTouch = Date.distantPast

    // Reordenar arrastrando el asa: la fila se levanta, las demas se apartan con muelle y al soltar se asienta.
    @State private var dragID: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var dragStartIndex = 0
    @State private var dragStartScroll: CGFloat = 0
    @State private var lastDropTarget = 0
    @State private var autoScrollTask: Task<Void, Never>?
    // Quitar deslizando una fila hacia la izquierda.
    @State private var swipeID: String?
    @State private var swipeOffset: CGFloat = 0
    @State private var scrollPosition = ScrollPosition()
    @State private var metrics = ScrollMetrics()

    /// Alto fijo de cada fila (la caratula de 44 mas el margen): asi se sabe donde cae la que se arrastra.
    private let rowHeight: CGFloat = 56

    private struct ScrollMetrics: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var viewport: CGFloat = 0
    }

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

    /// Cuanto se ha movido la fila que se arrastra, contando lo que se ha desplazado la lista debajo del dedo.
    private var dragTravel: CGFloat {
        dragTranslation + (metrics.offset - dragStartScroll)
    }

    /// El sitio donde caeria ahora mismo la fila que se arrastra.
    private func dropIndex(count: Int) -> Int {
        let moved = Int((dragTravel / rowHeight).rounded())
        return min(max(dragStartIndex + moved, 0), max(count - 1, 0))
    }

    private var queueList: some View {
        ScrollViewReader { proxy in
            let entries = queueEntries
            let target = dragID == nil ? -1 : dropIndex(count: entries.count)
            ScrollView {
                if np.queueSongs.isEmpty {
                    emptyQueueRow
                } else {
                    LazyVStack(spacing: 0) {
                        // Cada fila tiene una identidad propia que acompana a su cancion (la cancion y cuantas veces ya
                        // salio antes en la cola, por si esta repetida): al soltar, las filas se mueven de verdad.
                        ForEach(entries) { entry in
                            reorderableRow(entry, target: target)
                                .id(entry.id)
                        }
                    }
                }
            }
            .scrollPosition($scrollPosition)
            .scrollDisabled(dragID != nil)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    offset: geometry.contentOffset.y + geometry.contentInsets.top,
                    content: geometry.contentSize.height,
                    viewport: geometry.containerSize.height
                )
            } action: { _, newValue in
                metrics = newValue
            }
            .environment(\.colorScheme, .dark)
            .scrollIndicators(.hidden)
            .layoutPriority(1)
            .onAppear {
                if entries.indices.contains(np.queueIndex) {
                    proxy.scrollTo(entries[np.queueIndex].id, anchor: .center)
                }
            }
            .onDisappear {
                autoScrollTask?.cancel()
                dragID = nil
                swipeID = nil
            }
            .onScrollPhaseChange { _, phase in
                if phase != .idle { lastListTouch = Date() }
            }
            // Al cambiar de cancion (AutoMix, fin de la anterior...) la lista se desplaza a la que suena, salvo que
            // la estes moviendo.
            .onChange(of: np.queueIndex) { _, _ in
                guard dragID == nil, Date().timeIntervalSince(lastListTouch) > 4 else { return }
                let current = queueEntries
                guard current.indices.contains(np.queueIndex) else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(current[np.queueIndex].id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Filas

    private func reorderableRow(_ entry: QueueEntry, target: Int) -> some View {
        let isDragged = dragID == entry.id
        // Las demas filas se apartan para dejar sitio a la que se arrastra.
        var shift: CGFloat = 0
        if dragID != nil, !isDragged {
            if dragStartIndex < target, entry.index > dragStartIndex, entry.index <= target { shift = -rowHeight }
            if target < dragStartIndex, entry.index >= target, entry.index < dragStartIndex { shift = rowHeight }
        }
        let isSwiping = swipeID == entry.id
        return ZStack(alignment: .trailing) {
            if isSwiping {
                Color.red
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.trailing, 28)
            }
            rowContent(entry, isDragged: isDragged)
                .offset(x: isSwiping ? swipeOffset : 0)
        }
        .frame(height: rowHeight)
        .clipped(antialiased: false)
        .offset(y: isDragged ? dragTravel : shift)
        .scaleEffect(isDragged ? 1.03 : 1)
        .shadow(color: .black.opacity(isDragged ? 0.4 : 0), radius: 10, y: 4)
        .zIndex(isDragged ? 1 : 0)
        .animation(isDragged ? nil : .spring(response: 0.3, dampingFraction: 0.82), value: shift)
    }

    private func rowContent(_ entry: QueueEntry, isDragged: Bool) -> some View {
        let isCurrent = entry.index == np.queueIndex
        return Button {
            playSong(at: entry.index)
        } label: {
            QueueSongRow(
                song: entry.song,
                isCurrent: isCurrent,
                isPlayed: entry.index < np.queueIndex
            )
        }
        .buttonStyle(.plain)
        .frame(height: rowHeight)
        .background {
            if isDragged {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(white: 0.17))
                    .padding(.horizontal, 8)
            } else if isCurrent {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.08))
                    .padding(.horizontal, 12)
            }
        }
        .overlay(alignment: .trailing) {
            dragHandleArea(entry)
        }
        .simultaneousGesture(swipeGesture(entry))
    }

    // MARK: - Reordenar

    /// El asa de la derecha: mantener un momento y arrastrar.
    private func dragHandleArea(_ entry: QueueEntry) -> some View {
        Color.clear
            .frame(width: 72, height: rowHeight)
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: 0.15)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in
                        guard case .second(true, let drag) = value else { return }
                        if dragID == nil { beginDrag(entry) }
                        guard dragID == entry.id else { return }
                        dragTranslation = drag?.translation.height ?? 0
                        let target = dropIndex(count: np.queueSongs.count)
                        if target != lastDropTarget {
                            lastDropTarget = target
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                    .onEnded { _ in
                        if dragID == entry.id { endDrag() }
                    }
            )
    }

    private func beginDrag(_ entry: QueueEntry) {
        swipeID = nil
        dragStartIndex = entry.index
        dragTranslation = 0
        dragStartScroll = metrics.offset
        lastDropTarget = entry.index
        lastListTouch = Date()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            dragID = entry.id
        }
        startAutoScroll()
    }

    private func endDrag() {
        autoScrollTask?.cancel()
        let from = dragStartIndex
        let to = dropIndex(count: np.queueSongs.count)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            if to != from {
                np.moveQueueSongs(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
            }
            dragID = nil
            dragTranslation = 0
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        lastListTouch = Date()
    }

    /// Si la fila arrastrada se acerca al borde de arriba o de abajo, la lista se desplaza sola.
    private func startAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled, dragID != nil {
                let centerInView = CGFloat(dragStartIndex) * rowHeight + rowHeight / 2 + dragTravel - metrics.offset
                let edge: CGFloat = 70
                var speed: CGFloat = 0
                if centerInView < edge {
                    speed = -min(14, (edge - centerInView) / 4 + 2)
                } else if centerInView > metrics.viewport - edge {
                    speed = min(14, (centerInView - (metrics.viewport - edge)) / 4 + 2)
                }
                if speed != 0 {
                    let maxOffset = max(0, metrics.content - metrics.viewport)
                    let next = min(max(metrics.offset + speed, 0), maxOffset)
                    if next != metrics.offset {
                        scrollPosition.scrollTo(y: next)
                        metrics.offset = next
                    }
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    // MARK: - Quitar deslizando

    private func swipeGesture(_ entry: QueueEntry) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard dragID == nil else { return }
                if swipeID == nil {
                    // Solo si el gesto es claramente horizontal (si no, es para desplazar la lista).
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                    swipeID = entry.id
                }
                guard swipeID == entry.id else { return }
                swipeOffset = min(0, value.translation.width)
            }
            .onEnded { value in
                guard swipeID == entry.id else { return }
                if swipeOffset < -110 || value.predictedEndTranslation.width < -260 {
                    swipeID = nil
                    swipeOffset = 0
                    withAnimation(.spring(response: 0.3)) {
                        removeSong(at: entry.index)
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        swipeOffset = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if swipeOffset == 0 { swipeID = nil }
                    }
                }
            }
    }

    // MARK: - Queue Header

    private var queueHeader: some View {
        HStack(spacing: 12) {
            if let uiImage = np.thumbnailUIImage {
                Image(uiImage: uiImage)
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

/// El hueco bajo los controles: "Cola · cancion que suena". Tocar o deslizar hacia arriba abre la cola desde abajo.
struct QueueHandle: View {
    let onOpen: () -> Void
    private let np = NowPlaying.shared

    private var currentTitle: String? {
        np.title.isEmpty ? nil : np.title
    }

    var body: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 36, height: 4)

            HStack(spacing: 6) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                (Text("Queue") + Text(currentTitle.map { " · \($0)" } ?? ""))
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
