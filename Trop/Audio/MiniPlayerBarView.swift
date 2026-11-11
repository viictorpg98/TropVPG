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
    private let visuals = AutoMixVisuals.shared

    @State private var dragOffset: CGFloat = 0
    @State private var dragAxis: DragAxis?
    @State private var isCommitting = false

    private enum DragAxis {
        case horizontal
        case vertical
    }

    /// La barra ya no se encoge al desplazar: siempre es la barra completa.
    private var isInline: Bool {
        false
    }

    private var feedbackInMini: Bool {
        MixFeedbackStore.shared.showInMini && MixFeedbackStore.shared.pending != nil
    }

    private var barHeight: CGFloat {
        58
    }

    /// Ancho de la carátula: ocupa toda la altura de la tarjeta, pegada a su borde izquierdo, y se difumina hacia el color
    /// de la tarjeta (como en Apple Music).
    private var artworkWidth: CGFloat {
        82
    }

    private var artworkFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.48),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    /// Sobre el color de la carátula el texto es siempre blanco, como en el reproductor grande.
    private var titleColor: Color { .white }

    private var artistColor: Color { Color.white.opacity(0.78) }

    var body: some View {
        HStack(spacing: 0) {
            pagingArea
                .mask(textFadeMask)
            transportControls
                .padding(.trailing, 6)
        }
        .frame(height: barHeight)
        .frame(maxWidth: .infinity)
        // El color de la carátula, oscurecido, para que case con la barra de pestañas de debajo.
        .background { MiniColorBackdrop() }
        // Una tarjeta redondeada con margen, separada del menu: no choca con el.
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 4)
        // Tras una mezcla (solo si no te estabas moviendo por la app) la pregunta sale justo encima del mini, centrada, como
        // si saliera de el; los botones de pausa y siguiente no se tocan.
        .overlay(alignment: .top) {
            if feedbackInMini {
                MixFeedbackPill()
                    .alignmentGuide(.top) { $0[.bottom] + 2 }
                    .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: feedbackInMini)
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
        // Durante una mezcla de AutoMix, la carátula y el titulo de la entrante entran a la vez que en el reproductor
        // grande, con un fundido, en lugar de saltar de golpe cuando la app pasa a la nueva cancion.
        let mixing = visuals.isMixing && !visuals.incomingTitle.isEmpty
            && song.videoId == np.videoId && visuals.incomingVideoId != np.videoId
        let amount: Double = mixing ? autoMixReveal(visuals.progress) : 0
        return ZStack(alignment: .leading) {
            pageContent(for: song)
                .opacity(1 - amount)
                .blur(radius: 4 * amount)
            if mixing {
                incomingPageContent
                    .opacity(amount)
                    .blur(radius: 4 * (1 - amount))
            }
        }
        // La carátula va pegada al borde izquierdo de la tarjeta (sin margen).
        .frame(width: width, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
    }

    private func pageContent(for song: SongItem) -> some View {
        HStack(spacing: 0) {
            barArtwork(for: song)

            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(
                    text: song.title,
                    font: .system(size: 15, weight: .semibold),
                    frameHeight: 19,
                    textColor: titleColor
                )

                SubtitleWithDownloadMark(videoId: song.videoId, text: artistLine(for: song))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(artistColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 2)
        }
    }

    /// La cancion que entra en una mezcla (lo que el reproductor grande ya tiene preparado).
    private var incomingPageContent: some View {
        HStack(spacing: 0) {
            ZStack {
                if let image = visuals.incomingImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.12)
                }
            }
            .frame(width: artworkWidth, height: barHeight)
            .clipped()
            .mask(artworkFade)

            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(
                    text: visuals.incomingTitle,
                    font: .system(size: 15, weight: .semibold),
                    frameHeight: 19,
                    textColor: titleColor
                )
                Text(visuals.incomingArtist)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(artistColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 2)
        }
    }

    @ViewBuilder
    private func barArtwork(for song: SongItem) -> some View {
        let isCurrent = song.videoId == np.videoId
        ZStack {
            if isCurrent, let uiImage = np.thumbnailUIImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                MiniArtworkView(song: song)
            }
        }
        .frame(width: artworkWidth, height: barHeight)
        .clipped()
        .mask(artworkFade)
    }

    private var playPauseButton: some View {
        Button(action: { player.togglePlayPause() }, label: {
            ZStack {
                // El progreso de la cancion, como un aro alrededor del boton (en una mezcla, el de la entrante entra con el
                // mismo fundido que la carátula).
                MiniProgressRing()
                Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 17))
                    .foregroundStyle(titleColor)
            }
            .frame(width: 46, height: 48)
            .contentShape(Rectangle())
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

    /// Anterior, pausa y siguiente: iconos pequeños, sin circulos.
    private var transportControls: some View {
        HStack(spacing: 0) {
            Button(action: { np.playPrevious() }, label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(np.hasPrevious ? titleColor : titleColor.opacity(0.35))
                    .frame(width: 38, height: 48)
                    .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
            .disabled(!np.hasPrevious)
            .accessibilityLabel("Previous")

            playPauseButton

            Button(action: { np.playNext() }, label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(np.hasNext ? titleColor : titleColor.opacity(0.35))
                    .frame(width: 38, height: 48)
                    .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
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

// MARK: - Fondo del mini reproductor

/// Degradado con los colores de la carátula (los mismos que el reproductor grande; durante una mezcla de AutoMix pasan a
/// los de la entrante), algo oscurecido para que el texto blanco se lea siempre.
private struct MiniColorBackdrop: View {
    private let np = NowPlaying.shared
    private let visuals = AutoMixVisuals.shared

    var body: some View {
        let colors = playerPaletteNow(base: np.dominantColors, edge: np.artworkEdgeColor)
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            .overlay(Color.black.opacity(0.5))
            .animation(.easeInOut(duration: 0.7), value: colors)
    }
}

/// Aro de progreso alrededor del boton de pausa: la pista tenue es toda la cancion y el trazo claro lo ya sonado.
private struct MiniProgressRing: View {
    private let np = NowPlaying.shared
    private let visuals = AutoMixVisuals.shared

    var body: some View {
        if visuals.isMixing, visuals.incomingDuration > 0, let incomingId = visuals.incomingVideoId, incomingId != np.videoId {
            let amount = autoMixReveal(visuals.progress)
            ZStack {
                ring(progress: Double(np.progress)).opacity(1 - amount)
                ring(progress: visuals.incomingProgress).opacity(amount)
            }
        } else {
            ring(progress: Double(np.progress))
        }
    }

    private func ring(progress: Double) -> some View {
        let clamped = min(max(progress, 0), 1)
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(max(clamped, 0.004)))
                .stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: clamped)
        }
        .frame(width: 38, height: 38)
    }
}

// MARK: - Per-song artwork (memory-cache fast path)

@MainActor
private struct MiniArtworkView: View {
    let song: SongItem

    @State private var uiImage: UIImage?

    /// La misma miniatura que enseñan las listas (la de la version de audio si el elemento es un video). El fotograma de
    /// YouTube por identificador (el del video) solo se usa si la cancion no trae ninguna.
    private var sourceURL: URL? {
        if let candidate = AudioCounterpartStore.shared.thumbnailURL(for: song), let url = URL(string: candidate) { return url }
        return URL(string: NowPlaying.artworkURL(for: song.videoId))
    }

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
        .task(id: sourceURL) { load() }
    }

    private func load() {
        guard let url = sourceURL else { return }
        if let cached = ArtworkLoader.cachedImage(for: url) {
            uiImage = cached.centerCroppedSquare()
            return
        }
        loggedTask(Log.nowPlaying, "Mini artwork load failed") {
            let image = try await ArtworkLoader.image(for: url)
            let cropped = image.centerCroppedSquare()
            // Si mientras tanto cambio la miniatura (llego la del audio), esta ya no vale.
            guard sourceURL == url else { return }
            await MainActor.run { uiImage = cropped }
        }
    }
}
