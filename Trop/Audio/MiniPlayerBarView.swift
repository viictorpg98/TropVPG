//
//  MiniPlayerBarView.swift
//  Trop
//
//  Created by 686udjie on 18/07/2026.
//

import SwiftUI
import Nuke

/// The mini player bar, hosted as the TabView's native bottom accessory.
/// Swiping left/right pages through the queue with the artwork and text sliding
/// together, exactly tracking the drag state. When the tab bar minimizes on
/// scroll the bar collapses into a compact inline form that merges with the
/// tab bar, matching the Apple Music behavior; otherwise it renders as the
/// 48pt floating glass capsule with a bottom progress line.
struct MiniPlayerBarView: View {
    let onExpand: () -> Void

    @Environment(MiniPlayerScrollState.self) private var scrollState
    @Environment(\.colorScheme) private var colorScheme

    private let player = PlayerController.shared
    @Bindable private var np = NowPlaying.shared

    @State private var dragOffset: CGFloat = 0
    @State private var dragAxis: DragAxis?
    @State private var isCommitting = false

    private enum DragAxis {
        case horizontal
        case vertical
    }

    private var isInline: Bool {
        scrollState.isInline
    }

    private var barHeight: CGFloat {
        54
    }

    private var artworkSize: CGFloat {
        40
    }

    private var isDarkMode: Bool {
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
           let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
            return window.traitCollection.userInterfaceStyle == .dark
        }
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first {
            return window.traitCollection.userInterfaceStyle == .dark
        }
        return colorScheme == .dark
    }

    private var titleColor: Color {
        isDarkMode ? .white : .black
    }

    private var artistColor: Color {
        isDarkMode ? Color.white.opacity(0.85) : Color.black.opacity(0.80)
    }

    var body: some View {
        HStack(spacing: 0) {
            pagingArea
                .mask(textFadeMask)
            transportControls
                .padding(.trailing, 18)
        }
        .frame(height: barHeight)
        .frame(maxWidth: .infinity)
        .background(
            // Velo con el color de la caratula (cambia suavemente de cancion a cancion).
            LinearGradient(
                colors: [(np.dominantColors.first ?? .clear).opacity(0.38), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .animation(.easeInOut(duration: 0.6), value: np.dominantColors)
        )
        .overlay(alignment: .bottom) { MiniProgressLine(color: titleColor) }
        .clipShape(Capsule())
        .onChange(of: np.videoId) { _, _ in
            dragOffset = 0
            preloadLyrics()
        }
        .onChange(of: np.queueSongs.count) { _, _ in
            dragOffset = 0
            np.preloadNeighborArtwork()
        }
        .onChange(of: np.queueIndex) { _, _ in
            dragOffset = 0
            np.preloadNeighborArtwork()
        }
        .task { np.preloadNeighborArtwork() }
    }

    private func preloadLyrics() {
        guard let id = np.videoId else { return }
        let upcoming = np.upcomingSongs(prefixLimit: 3).map(\.videoId)
        Task { await LyricsService.shared.preload(videoId: id, upcoming: upcoming) }
    }

    // MARK: - Paging area

    private var pagingArea: some View {
        GeometryReader { geo in
            let pageWidth = geo.size.width
            ZStack(alignment: .center) {
                if let prev = prevSong {
                    page(for: prev, width: pageWidth)
                        .offset(x: -pageWidth)
                }
                if let current = currentSong {
                    page(for: current, width: pageWidth)
                }
                if let next = nextSong {
                    page(for: next, width: pageWidth)
                        .offset(x: pageWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .offset(x: dragOffset)
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture(pageWidth: pageWidth))
            .onTapGesture { onExpand() }
        }
        .frame(height: barHeight)
    }

    private func page(for song: SongItem, width: CGFloat) -> some View {
        HStack(spacing: 12) {
            barArtwork(for: song.videoId)

            VStack(alignment: .leading, spacing: 0) {
                if isInline {
                    Text(song.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(titleColor)
                } else {
                    MarqueeText(
                        text: song.title,
                        font: .system(size: 15, weight: .semibold),
                        frameHeight: 19,
                        textColor: titleColor
                    )
                }

                Text(artistLine(for: song))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(artistColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.leading, 14)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func barArtwork(for videoId: String) -> some View {
        let isCurrent = videoId == np.videoId
        ZStack {
            if isCurrent, let uiImage = np.thumbnailUIImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                MiniArtworkView(videoId: videoId)
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }

    private var playPauseButton: some View {
        Button(action: { player.togglePlayPause() }, label: {
            Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(isDarkMode ? Color.black : Color.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(titleColor))
        })
        .buttonStyle(.plain)
        .accessibilityLabel(np.isPlaying ? "Pause" : "Play")
    }

    /// Desvanece el texto en el borde derecho para que no se meta bajo los botones.
    private var textFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.9),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var transportControls: some View {
        HStack(spacing: 14) {
            playPauseButton
            Button(action: { np.playNext() }, label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(np.hasNext ? titleColor : titleColor.opacity(0.35))
            })
            .disabled(!np.hasNext)
            .accessibilityLabel("Next")
        }
    }

    // MARK: - Data

    private var currentSong: SongItem? {
        guard np.queueSongs.indices.contains(np.queueIndex) else { return nil }
        return np.queueSongs[np.queueIndex]
    }

    private var prevSong: SongItem? {
        guard np.queueSongs.indices.contains(np.queueIndex - 1) else { return nil }
        return np.queueSongs[np.queueIndex - 1]
    }

    /// Artist line for a queued song, falling back to the resolved author
    /// (what the big player shows via `displayArtist`) when the queued item
    /// carries no artist runs — e.g. videos or cache-repaired songs.
    private func artistLine(for song: SongItem) -> String {
        let own = artistDisplayString(from: song.artists)
        if !own.isEmpty { return own }
        if song.videoId == np.videoId { return np.displayArtist }
        return own
    }

    private var nextSong: SongItem? {
        guard np.queueSongs.indices.contains(np.queueIndex + 1) else { return nil }
        return np.queueSongs[np.queueIndex + 1]
    }

    // MARK: - Gesture

    private func dragGesture(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                guard !isCommitting else { return }
                if dragAxis == nil {
                    dragAxis = abs(value.translation.width) > abs(value.translation.height)
                        ? .horizontal
                        : .vertical
                }
                guard dragAxis == .horizontal else { return }

                let minOffset = nextSong != nil ? -pageWidth : 0
                let maxOffset = prevSong != nil ? pageWidth : 0
                dragOffset = min(max(value.translation.width, minOffset), maxOffset)
            }
            .onEnded { value in
                guard !isCommitting else { return }
                defer { dragAxis = nil }

                switch dragAxis {
                case .horizontal:
                    if dragOffset <= -pageWidth * 0.35, nextSong != nil {
                        commitSwipe(to: .next, pageWidth: pageWidth)
                    } else if dragOffset >= pageWidth * 0.35, prevSong != nil {
                        commitSwipe(to: .previous, pageWidth: pageWidth)
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            dragOffset = 0
                        }
                    }
                case .vertical:
                    if value.translation.height < -40 {
                        onExpand()
                    }
                case nil:
                    break
                }
            }
    }

    private enum SwipeDirection {
        case next
        case previous
    }

    private func commitSwipe(to direction: SwipeDirection, pageWidth: CGFloat) {
        isCommitting = true
        let target: CGFloat = direction == .next ? -pageWidth : pageWidth
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            dragOffset = target
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            switch direction {
            case .next: np.playNext()
            case .previous: np.playPrevious()
            }
            withAnimation(nil) { dragOffset = 0 }
            isCommitting = false
        }
    }
}

// MARK: - Barra de progreso fina (vista propia: solo ella se redibuja con el tiempo)

private struct MiniProgressLine: View {
    let color: Color
    private let np = NowPlaying.shared

    var body: some View {
        GeometryReader { geo in
            let track = max(0, geo.size.width - 44)
            let filled = max(0, min(track, track * CGFloat(np.progress)))
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.15))
                Capsule().fill(color.opacity(0.85)).frame(width: filled)
            }
            .frame(width: track, height: 3)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 3)
        .padding(.bottom, 4)
        .allowsHitTesting(false)
    }
}

// MARK: - Per-song artwork (memory-cache fast path)

@MainActor
private struct MiniArtworkView: View {
    let videoId: String

    @State private var uiImage: UIImage?

    var body: some View {
        ZStack {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.12)
                Image(systemName: "music.note")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .onAppear { load() }
    }

    private func load() {
        if let cached = cachedArtwork(for: videoId) {
            uiImage = cached
            return
        }
        guard let url = URL(string: NowPlaying.artworkURL(for: videoId)) else { return }
        loggedTask(Log.nowPlaying, "Mini artwork load failed") {
            let image = try await ArtworkLoader.image(for: url)
            let cropped = image.centerCroppedSquare()
            await MainActor.run { uiImage = cropped }
        }
    }
}

@MainActor
private func cachedArtwork(for videoId: String) -> UIImage? {
    guard let url = URL(string: NowPlaying.artworkURL(for: videoId)) else { return nil }
    return ArtworkLoader.cachedImage(for: url)?.centerCroppedSquare()
}
