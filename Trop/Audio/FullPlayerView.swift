//
//  FullPlayerView.swift
//  Trop
//
//  Created by 686udjie on 18/07/2026.
//

import SwiftUI

struct FullPlayerView: View {
    let onCollapse: () -> Void

    @Environment(SettingsStore.self) private var settings
    private let player = PlayerController.shared
    @Bindable private var np = NowPlaying.shared
    @State private var editingProgress: Float = 0
    @State private var isEditingSlider = false
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.3, dampingFraction: 0.85)))
    private var collapseOffset: CGFloat = 0

    @ObservedObject private var likeStore = LikeStore.shared
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var pendingRoute: DetailRoute?
    @State private var showSongMenu = false
    @State private var showPlaylistPicker = false
    @State private var artworkEntryOffset: CGFloat = 0
    @State private var currentLyrics: [LyricLine] = []

    private var currentSong: SongItem? {
        np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex] : nil
    }

    private var isLiked: Bool {
        guard let song = currentSong else { return false }
        return likeStore.isLiked(videoId: song.videoId)
    }

    private var isDisliked: Bool {
        guard let song = currentSong else { return false }
        return likeStore.isDisliked(videoId: song.videoId)
    }

    private var playerBackgroundColors: [Color] {
        np.dominantColors
    }

    var body: some View {
        GeometryReader { geometry in
            let horizontalPadding: CGFloat = geometry.size.width < 375 ? 24 : 28
            let isCompact = geometry.size.height < 700

            ZStack {
                background
                // Durante una mezcla de AutoMix, toda la pantalla se llena del color de las carátulas.
                AutoMixGlow()

                VStack(spacing: 0) {
                    // Por encima de la carátula, que sube hasta el borde de la pantalla.
                    grabHandle
                        .zIndex(2)

                    if showLyrics {
                        LyricsView(
                            showLyrics: $showLyrics,
                            pendingRoute: $pendingRoute,
                            progressSlider: { progressSlider(horizontalPadding: horizontalPadding) }
                        )
                    } else if np.isVideoMode && np.hasVideo {
                        musicVideoContent
                    } else {
                        // Como en YouTube Music: al abrir la cola solo cambia la parte de arriba (carátula, titulo y
                        // botones <-> cola); la barra, los controles y el pie son el mismo bloque, en el mismo sitio,
                        // y no se mueve nada.
                        ZStack(alignment: .top) {
                            if showQueue {
                                // Arriba solo queda la cancion que suena; la lista sube desde abajo.
                                QueueView(
                                    part: .header,
                                    showQueue: $showQueue,
                                    isShuffleOn: $np.isShuffleOn,
                                    isRepeatOn: $np.isRepeatOn,
                                    editingProgress: $editingProgress,
                                    isEditingSlider: $isEditingSlider,
                                    pendingRoute: $pendingRoute,
                                    progressSlider: { progressSlider(horizontalPadding: horizontalPadding) }
                                )
                                .frame(maxHeight: .infinity, alignment: .center)
                                .transition(.opacity)
                            } else {
                                VStack(spacing: 0) {
                                    mainContent(
                                        artSide: artworkSide(in: geometry, horizontalPadding: horizontalPadding),
                                        fullSize: CGSize(
                                            width: geometry.size.width,
                                            height: max(220, min(geometry.size.width, geometry.size.height - 400))
                                        ),
                                        topInset: geometry.safeAreaInsets.top,
                                        horizontalPadding: horizontalPadding,
                                        isCompact: isCompact
                                    )
                                }
                                .transition(.opacity)
                            }
                        }
                        .frame(maxHeight: .infinity)

                        playerBottom(horizontalPadding: horizontalPadding, isCompact: isCompact)

                        // Debajo de los controles: el asa de la cola (cerrada) o la lista (abierta). La altura es lo que
                        // se anima, y con ella todo el bloque de controles sube o baja con suavidad.
                        ZStack(alignment: .top) {
                            if showQueue {
                                QueueView(
                                    part: .list,
                                    showQueue: $showQueue,
                                    isShuffleOn: $np.isShuffleOn,
                                    isRepeatOn: $np.isRepeatOn,
                                    editingProgress: $editingProgress,
                                    isEditingSlider: $isEditingSlider,
                                    pendingRoute: $pendingRoute,
                                    progressSlider: { EmptyView() }
                                )
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            } else {
                                QueueHandle {
                                    withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
                                        showQueue = true
                                    }
                                }
                                .transition(.opacity)
                            }
                        }
                        .frame(height: showQueue ? max(220, geometry.size.height - 300) : 58, alignment: .top)
                        .clipped()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .offset(y: collapseOffset)
            .animation(.spring(response: 0.45, dampingFraction: 0.9), value: showQueue)
            .simultaneousGesture(collapseDrag)
            .onChange(of: np.videoId) { _, _ in
                np.isVideoMode = false
                // Si el cambio lo hizo AutoMix o el paso automatico a la siguiente, te quedas donde estabas (cola, letra...);
                // solo si lo has pedido tu se vuelve a la carátula.
                if Date().timeIntervalSince(np.lastAutomaticChange) > 8 {
                    showLyrics = false
                    showQueue = false
                }
                preloadLyrics()
            }
            .onChange(of: np.queueSongs.count) { _, _ in
                np.preloadNeighborArtwork()
                preloadLyrics()
            }
            .onChange(of: np.queueIndex) { _, _ in
                np.preloadNeighborArtwork()
            }
            .onChange(of: showQueue) { _, newValue in
                if newValue { np.preloadNeighborArtwork() }
            }
            .onAppear { PlayerController.shared.setFullPlayerVisible(true) }
            .onDisappear { PlayerController.shared.setFullPlayerVisible(false) }
            .task {
                // Se retrasa para no competir con la animacion de apertura.
                try? await Task.sleep(nanoseconds: 400_000_000)
                np.preloadNeighborArtwork()
            }
            .task(id: np.videoId) { await loadCurrentLyrics() }
            .sheet(isPresented: $showSongMenu) {
                if let song = currentSong {
                    PlayerMenuSheet(song: song, onCollapseRequest: { onCollapse() })
                }
            }
            .sheet(isPresented: $showPlaylistPicker) {
                if let song = currentSong {
                    AddSongToPlaylistSheet(song: song)
                }
            }
            .background(
                Color.clear
                    .detailRouteSheet(item: $pendingRoute)
            )
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var background: some View {
        if np.isVideoMode && np.hasVideo {
            Color.black
                .ignoresSafeArea()
        } else if settings.playerBackgroundStyle == .solid, !settings.fullWidthArtwork {
            Color.black
                .ignoresSafeArea()
        } else {
            // Su propia vista: durante una mezcla de AutoMix cambia de color con ella sin redibujar todo el reproductor.
            PlayerGradientBackground(base: playerBackgroundColors, edge: np.artworkEdgeColor, tinted: settings.fullWidthArtwork)
        }
    }

    private var grabHandle: some View {
        Capsule()
            .fill(.white.opacity(settings.fullWidthArtwork ? 0.6 : 0.3))
            .frame(width: 36, height: 5)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .contentShape(Rectangle().size(width: 60, height: 30))
            .onTapGesture {
                guard showLyrics else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    showLyrics = false
                }
            }
            .accessibilityLabel(showLyrics ? "Close lyrics" : "Collapse player")
    }

    // MARK: - Main layout

    /// La portada se calcula con la altura real disponible, para que nunca se salga de la pantalla.
    private func artworkSide(in geometry: GeometryProxy, horizontalPadding: CGFloat) -> CGFloat {
        let widthLimit = geometry.size.width - horizontalPadding * 2
        let heightLimit = geometry.size.height - 430
        return max(140, min(widthLimit, heightLimit))
    }

    @ViewBuilder
    private func mainContent(artSide: CGFloat, fullSize: CGSize, topInset: CGFloat, horizontalPadding: CGFloat, isCompact: Bool) -> some View {
        if settings.fullWidthArtwork {
            // Carátula de lado a lado que llega hasta el borde superior, por detras de la isla dinamica y la barra de
            // estado (como Apple Music), y que por abajo se funde con el fondo del color de la propia carátula. Ocupa
            // el mismo sitio que antes: lo que sube por arriba se compensa con un margen negativo.
            let handle: CGFloat = 29
            MixAwareArtwork(
                width: fullSize.width, height: fullSize.height, topExtension: topInset + handle, fullBleed: true, content: artwork
            )
            .brightness(np.isPlaying ? 0 : -0.14)
            .animation(.easeInOut(duration: 0.4), value: np.isPlaying)
            .padding(.top, -(topInset + handle))

            Spacer(minLength: isCompact ? 4 : 10)
        } else {
            Spacer(minLength: 0)

            MixAwareArtwork(width: artSide, height: artSide, fullBleed: false, content: artwork)
                .scaleEffect(np.isPlaying ? 1 : 0.88)
                .animation(.spring(response: 0.5, dampingFraction: 0.62), value: np.isPlaying)

            Spacer(minLength: isCompact ? 10 : 18)
        }

        titleAndActionsRow
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, 12)

        actionPills
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, 6)

        Group {
            if AutoMixVisuals.shared.isMixing {
                AutoMixPill()
            } else if AutoMixVisuals.shared.preparingManual {
                AutoMixPill(preparing: true)
            } else if MixFeedbackStore.shared.pending != nil {
                MixFeedbackPill()
            } else {
                ActiveLyricLine(lines: currentLyrics) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showLyrics = true
                    }
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .frame(maxWidth: .infinity)
        .frame(height: 33, alignment: .bottom)
    }

    /// Barra de progreso, controles y botones del pie: el mismo bloque con la carátula y con la cola.
    @ViewBuilder
    private func playerBottom(horizontalPadding: CGFloat, isCompact: Bool) -> some View {
        progressSlider(horizontalPadding: horizontalPadding)
            .padding(.top, 4)
            .padding(.bottom, isCompact ? 8 : 12)

        PlaybackControlsRow(
            isPlaying: np.isPlaying,
            hasPrevious: np.hasPrevious,
            hasNext: np.hasNext,
            onPrevious: { np.playPrevious() },
            onPlayPause: { player.togglePlayPause() },
            onNext: { np.playNext() },
            showsModes: true
        )
        .scaleEffect(isCompact ? 0.94 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: np.isPlaying)
        .sensoryFeedback(.impact(weight: .light), trigger: np.isPlaying)
        .padding(.bottom, isCompact ? 2 : 6)
    }

    private var titleAndActionsRow: some View {
        HStack(alignment: .center, spacing: 12) {
            MixAwareTitle(title: np.title, artist: np.displayArtist, videoId: np.videoId)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if currentSong != nil {
                PlayerAirPlayControl()
                PlayerOptionsButton {
                    showSongMenu = true
                }
            }
        }
    }

    /// Me gusta, No me gusta, Mezclar ya, Guardar y Descargar: una sola fila que se desliza entera.
    private var actionPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                PlayerPillButton(
                    systemImage: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup",
                    isActive: isLiked,
                    accessibility: "Like"
                ) {
                    guard let song = currentSong else { return }
                    Task { await likeStore.toggle(song: song) }
                }

                PlayerPillButton(
                    systemImage: isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                    isActive: isDisliked,
                    accessibility: "Dislike"
                ) {
                    guard let song = currentSong else { return }
                    let willDislike = !isDisliked
                    Task { await likeStore.toggleDislike(song: song) }
                    // Como en YouTube Music: al marcar "No me gusta" pasa a la siguiente.
                    if willDislike, np.hasNext { np.playNext() }
                }

                // Mezclar ya con la siguiente (AutoMix la prepara y empieza en unos segundos).
                if settings.autoMixEnabled, np.hasNext, !AutoMixVisuals.shared.isMixing {
                    PlayerPillButton(
                        systemImage: "wand.and.stars",
                        title: AutoMixVisuals.shared.preparingManual ? "Preparing…" : "Mix now",
                        isActive: AutoMixVisuals.shared.preparingManual,
                        accessibility: "Mix now",
                        pulses: AutoMixVisuals.shared.preparingManual
                    ) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        AutoMixEngine.shared.mixNow()
                    }
                }

                PlayerPillButton(
                    systemImage: "plus.square.on.square",
                    title: "Save",
                    isActive: false,
                    accessibility: "Add to Playlist"
                ) {
                    showPlaylistPicker = true
                }

                if let song = currentSong {
                    PlayerDownloadPill(song: song)
                }
            }
            .padding(.trailing, 18)
        }
        .frame(height: 38)
        .mask(
            LinearGradient(
                stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                startPoint: .leading, endPoint: .trailing
            )
        )
    }

    // MARK: - Gestures

    /// Swipe left/right on the artwork to skip tracks (toggleable in Settings).
    /// Blocked at the queue's ends (no movement); on skip, the incoming
    /// artwork slides in from the swipe direction.
    private var artworkSwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard settings.artworkSwipeNavigation else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -60, np.hasNext {
                    np.playNext()
                    slideInArtwork(fromLeft: false)
                } else if value.translation.width > 60, np.hasPrevious {
                    np.playPrevious()
                    slideInArtwork(fromLeft: true)
                }
            }
    }

    private func slideInArtwork(fromLeft: Bool) {
        artworkEntryOffset = fromLeft ? -600 : 600
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            artworkEntryOffset = 0
        }
    }

    /// Swipe down anywhere to collapse. Vertical-dominant drags only.
    /// `collapseOffset` es un @GestureState: vuelve solo a 0 (con animacion) cuando el gesto
    /// termina o el sistema lo cancela, asi que el reproductor nunca se queda desplazado.
    private var collapseDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($collapseOffset) { value, state, _ in
                guard value.translation.height > 0,
                      value.translation.height > abs(value.translation.width) else { return }
                state = value.translation.height
            }
            .onEnded { value in
                let isVertical = value.translation.height > abs(value.translation.width)
                if isVertical, value.translation.height > 140 {
                    onCollapse()
                }
            }
    }

    // MARK: - Lyrics

    private func preloadLyrics() {
        guard let id = np.videoId else { return }
        let upcoming = np.upcomingSongs(prefixLimit: 3).map(\.videoId)
        Task { await LyricsService.shared.preload(videoId: id, upcoming: upcoming) }
    }

    private func loadCurrentLyrics() async {
        guard let videoId = np.videoId else {
            currentLyrics = []
            return
        }
        currentLyrics = []
        guard let lines = try? await LyricsService.shared.fetchLyrics(videoId: videoId),
              !Task.isCancelled,
              np.videoId == videoId else { return }
        currentLyrics = lines
    }

    // MARK: - Video

    private var musicVideoContent: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        np.isVideoMode = false
                        showQueue = false
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.48), in: Circle())
                }
                .accessibilityLabel("Return to artwork player")

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            musicVideoStage

            QueueView(
                showQueue: $showQueue,
                isShuffleOn: $np.isShuffleOn,
                isRepeatOn: $np.isRepeatOn,
                editingProgress: $editingProgress,
                isEditingSlider: $isEditingSlider,
                pendingRoute: $pendingRoute,
                progressSlider: { progressSlider(horizontalPadding: 32) },
                isVideoMode: true
            )
            .frame(maxHeight: .infinity)
        }
    }

    private var musicVideoStage: some View {
        artwork
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipped()
    }

    @ViewBuilder
    private var artwork: some View {
        Group {
            if np.isVideoMode, np.hasVideo {
                ZStack {
                    VideoPlayerView()
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .white, location: 0.12),
                                    .init(color: .white, location: 0.95),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                    if !np.isVideoReady {
                        artworkImage
                            .transition(.opacity)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .animation(.easeOut(duration: 0.2), value: np.isVideoReady)
            } else {
                ZStack {
                    artworkImage
                    AnimatedArtworkLayer()
                }
                .onTapGesture {
                    guard np.hasVideo else { return }
                    showQueue = true
                    player.setVideoMode()
                }
            }
        }
        .offset(x: artworkEntryOffset)
        .gesture(artworkSwipe)
    }

    /// Song artwork (or placeholder), filling its container.
    private var artworkImage: some View {
        ZStack {
            if let uiImage = np.thumbnailUIImage {
                let cropped = uiImage.centerCroppedSquare()
                GeometryReader { geo in
                    Image(uiImage: cropped)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .id(np.thumbnailVersion)
                .transition(.opacity)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note")
                        .font(.system(size: 64))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: np.thumbnailVersion)
    }

    private func progressSlider(horizontalPadding: CGFloat) -> some View {
        PlayerProgressSection(
            horizontalPadding: horizontalPadding,
            editingProgress: $editingProgress,
            isEditingSlider: $isEditingSlider
        )
    }
}

// MARK: - Barra de progreso (vista propia: solo ella se redibuja con cada tic del tiempo)

private struct PlayerProgressSection: View {
    let horizontalPadding: CGFloat
    @Binding var editingProgress: Float
    @Binding var isEditingSlider: Bool

    private let player = PlayerController.shared
    private let np = NowPlaying.shared
    private let visuals = AutoMixVisuals.shared
    @State private var waveform: [Float]?
    @State private var incomingWaveform: [Float]?

    /// Donde (0...1) empezara la proxima mezcla de la cancion que suena.
    private var markerFraction: Double? {
        guard let id = np.videoId, np.duration > 0, let start = AutoMixEngine.shared.plannedMixStart(for: id) else { return nil }
        let fraction = start / np.duration
        return (0.02...0.98).contains(fraction) ? fraction : nil
    }

    var body: some View {
        Group {
            if visuals.isMixing, visuals.incomingDuration > 0 {
                // Durante una mezcla, la barra y los tiempos de la siguiente entran a la vez que su carátula.
                let amount = autoMixReveal(visuals.progress)
                ZStack {
                    currentBar
                        .opacity(1 - amount)
                        .blur(radius: 6 * amount)
                    incomingBar
                        .opacity(amount)
                        .blur(radius: 6 * (1 - amount))
                        .allowsHitTesting(false)
                }
            } else {
                currentBar
            }
        }
        .padding(.horizontal, horizontalPadding)
        .task(id: np.videoId) {
            guard SettingsStore.shared.waveformProgressBar, let id = np.videoId else {
                waveform = nil
                return
            }
            // Si la onda de esta cancion ya esta calculada (se adelanta al empezar) sale al instante, y si ya se vio
            // como la de "la siguiente" durante una mezcla se conserva; si no, mientras tanto se ve una de relleno.
            waveform = WaveformStore.shared.cached(for: id)
            guard waveform == nil else { return }
            await loadWave(id) { waveform = $0 }
        }
        .task(id: visuals.incomingVideoId) {
            guard SettingsStore.shared.waveformProgressBar, let id = visuals.incomingVideoId else {
                incomingWaveform = nil
                return
            }
            incomingWaveform = WaveformStore.shared.cached(for: id)
            guard incomingWaveform == nil else { return }
            await loadWave(id) { incomingWaveform = $0 }
        }
    }

    private func loadWave(_ id: String, assign: ([Float]) -> Void) async {
        WaveformStore.shared.request(id, urgent: true)
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            if let wave = WaveformStore.shared.cached(for: id) {
                assign(wave)
                return
            }
        }
    }

    private var currentBar: some View {
        VStack(spacing: 6) {
            ProgressBar(
                progress: Binding(
                    get: { isEditingSlider ? editingProgress : np.progress },
                    set: { editingProgress = $0 }
                ),
                accentColor: np.dominantColors.first ?? .white,
                isPlaying: np.isPlaying,
                waveform: SettingsStore.shared.waveformProgressBar
                    ? (waveform ?? WaveformStore.placeholder(for: np.videoId)) : nil,
                waveformIsPlaceholder: waveform == nil,
                markerFraction: markerFraction,
                onEditingChanged: { editing in
                    if editing {
                        editingProgress = np.progress
                    } else {
                        let target = TimeInterval(editingProgress) * np.duration
                        player.seek(to: target)
                        np.currentTime = target
                        player.updateNowPlayingProgress()
                    }
                    isEditingSlider = editing
                }
            )

            timeRow(
                elapsed: isEditingSlider ? TimeInterval(editingProgress) * np.duration : np.currentTime,
                total: np.duration
            )
        }
    }

    /// La barra de la cancion que entra (solo se ve durante la mezcla; no se puede tocar).
    private var incomingBar: some View {
        VStack(spacing: 6) {
            ProgressBar(
                progress: .constant(Float(visuals.incomingProgress)),
                accentColor: visuals.incomingColors.first ?? .white,
                isPlaying: np.isPlaying,
                waveform: SettingsStore.shared.waveformProgressBar
                    ? (incomingWaveform ?? WaveformStore.placeholder(for: visuals.incomingVideoId)) : nil,
                waveformIsPlaceholder: incomingWaveform == nil,
                onEditingChanged: { _ in }
            )
            timeRow(elapsed: visuals.incomingElapsed, total: visuals.incomingDuration)
        }
    }

    private func timeRow(elapsed: TimeInterval, total: TimeInterval) -> some View {
        HStack {
            Text(DurationFormat.playbackTime(elapsed))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))

            Spacer()

            Text(DurationFormat.playbackTime(total))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

// MARK: - Linea de letra activa (vista propia: lee el tiempo sin redibujar todo el reproductor)

private struct ActiveLyricLine: View {
    let lines: [LyricLine]
    let onTap: () -> Void

    @Environment(SettingsStore.self) private var settings
    private let np = NowPlaying.shared

    private var activeText: String? {
        let synchronizedLines = lines.filter {
            $0.startTime != nil &&
                !$0.text.trimmingCharacters(in: CharacterSet(charactersIn: "♪*· ")).isEmpty
        }
        guard let firstLine = synchronizedLines.first else { return nil }

        let lyricTime = np.currentTime + settings.lyricsOffsetSeconds
        return synchronizedLines.last { line in
            guard let startTime = line.startTime else { return false }
            return startTime <= lyricTime
        }?.text ?? firstLine.text
    }

    var body: some View {
        if let text = activeText {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    Text(text)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .foregroundStyle(.white.opacity(0.82))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
            .accessibilityLabel("Current lyric: \(text). Open lyrics")
        } else {
            Color.clear
        }
    }
}

// MARK: - Boton de descarga (vista propia: observa el gestor de descargas sin redibujar todo el reproductor)

private struct PlayerDownloadPill: View {
    let song: SongItem
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var confirmRemoval = false

    var body: some View {
        let state = downloads.state(for: song.videoId)
        Group {
            switch state {
            case .completed:
                PlayerPillButton(
                    systemImage: "checkmark.circle.fill", title: "Downloaded", isActive: true, accessibility: "Downloaded"
                ) {
                    confirmRemoval = true
                }
            case .downloading:
                PlayerPillButton(
                    systemImage: "arrow.down.circle", title: "Downloading…", isActive: false,
                    accessibility: "Downloading…", pulses: true
                ) {}
            case .notStarted, .failed:
                PlayerPillButton(
                    systemImage: "arrow.down.circle", title: "Download", isActive: false, accessibility: "Download"
                ) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { await downloads.download(song: song) }
                }
            }
        }
        .confirmationDialog("Remove Download", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) {
                Task { await downloads.delete(videoId: song.videoId) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Boton redondeado (Me gusta / No me gusta / Letra)

struct PlayerPillButton: View {
    let systemImage: String
    var title: String?
    let isActive: Bool
    let accessibility: String
    var pulses = false
    let action: () -> Void

    init(
        systemImage: String,
        title: String? = nil,
        isActive: Bool,
        accessibility: String,
        pulses: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.title = title
        self.isActive = isActive
        self.accessibility = accessibility
        self.pulses = pulses
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, isActive: pulses)
                if let title {
                    Text(LocalizedStringKey(title))
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(isActive ? Color.black : Color.white)
            .padding(.horizontal, title == nil ? 0 : 16)
            .frame(minWidth: title == nil ? 50 : nil)
            .frame(height: 38)
            .background(Capsule().fill(isActive ? Color.white : Color.clear))
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(accessibility)))
    }
}
