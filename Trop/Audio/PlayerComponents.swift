//
//  PlayerComponents.swift
//  Trop
//
//  Created by 686udjie on 13/07/2026.
//

import SwiftUI
import AVKit

// MARK: - ProgressBar
struct ProgressBar: View {
    @Binding var progress: Float
    let accentColor: Color
    let isPlaying: Bool
    /// Forma de onda de la cancion (0...1): si hay, la barra se dibuja como onda.
    var waveform: [Float]?
    /// La onda es de relleno (la real aun no esta): se dibuja con un brillo suave que la recorre.
    var waveformIsPlaceholder = false
    /// Donde (0...1) empezara la proxima mezcla de AutoMix, si se sabe.
    var markerFraction: Double?
    let onEditingChanged: (Bool) -> Void

    init(
        progress: Binding<Float>,
        accentColor: Color,
        isPlaying: Bool,
        waveform: [Float]? = nil,
        waveformIsPlaceholder: Bool = false,
        markerFraction: Double? = nil,
        onEditingChanged: @escaping (Bool) -> Void
    ) {
        _progress = progress
        self.accentColor = accentColor
        self.isPlaying = isPlaying
        self.waveform = waveform
        self.waveformIsPlaceholder = waveformIsPlaceholder
        self.markerFraction = markerFraction
        self.onEditingChanged = onEditingChanged
    }

    private var hasWaveform: Bool { !(waveform ?? []).isEmpty }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let elapsedWidth = max(0, min(width, width * CGFloat(progress)))

            ZStack(alignment: .leading) {
                if hasWaveform, let waveform {
                    Group {
                        if waveformIsPlaceholder {
                            TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
                                waveformCanvas(waveform, shimmer: timeline.date.timeIntervalSinceReferenceDate)
                            }
                        } else {
                            waveformCanvas(waveform, shimmer: nil)
                        }
                    }
                    .id(waveformIsPlaceholder)
                    .transition(.opacity)
                } else {
                    // Remaining track (unwatched)
                    Capsule()
                        .fill(.white.opacity(0.15))
                        .frame(height: 6)

                    // Elapsed track (watched, marked)
                    Capsule()
                        .fill(.white.opacity(0.8))
                        .frame(width: elapsedWidth, height: 6)
                }
            }
            .animation(.easeInOut(duration: 0.5), value: waveformIsPlaceholder)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onEditingChanged(true)
                        let loc = value.location.x
                        let percent = max(0, min(1, loc / width))
                        progress = Float(percent)
                    }
                    .onEnded { _ in
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: hasWaveform ? 34 : 12)
    }

    /// La onda: las barras ya sonadas en blanco y las que faltan apagadas; una linea marca dónde está, y un rombo dónde
    /// empezará la próxima mezcla.
    private func waveformCanvas(_ levels: [Float], shimmer: Double?) -> some View {
        Canvas { context, size in
            let count = levels.count
            let slot = size.width / CGFloat(count)
            let played = CGFloat(progress)
            for index in 0..<count {
                let height = max(3, CGFloat(levels[index]) * size.height)
                let x = CGFloat(index) * slot
                let rect = CGRect(x: x + slot * 0.2, y: (size.height - height) / 2, width: slot * 0.6, height: height)
                let isPlayed = (CGFloat(index) + 0.5) / CGFloat(count) <= played
                var opacity = isPlayed ? 0.95 : 0.27
                if let shimmer {
                    // Un brillo que recorre la onda de izquierda a derecha mientras llega la real.
                    let wave = sin((Double(index) / Double(count)) * 9 - shimmer * 3.2)
                    opacity = (isPlayed ? 0.75 : 0.28) + 0.22 * max(0, wave)
                }
                context.fill(
                    Path(roundedRect: rect, cornerRadius: slot * 0.3),
                    with: .color(Color.white.opacity(opacity))
                )
            }
            // Donde va.
            let head = size.width * played
            context.fill(
                Path(roundedRect: CGRect(x: head - 1, y: 0, width: 2, height: size.height), cornerRadius: 1),
                with: .color(accentColor)
            )
            // Donde empezara la proxima mezcla.
            if let markerFraction {
                let x = size.width * CGFloat(markerFraction)
                var diamond = Path()
                diamond.move(to: CGPoint(x: x, y: 0))
                diamond.addLine(to: CGPoint(x: x + 4, y: 4))
                diamond.addLine(to: CGPoint(x: x, y: 8))
                diamond.addLine(to: CGPoint(x: x - 4, y: 4))
                diamond.closeSubpath()
                context.fill(diamond, with: .color(accentColor))
                context.fill(
                    Path(CGRect(x: x - 0.5, y: 8, width: 1, height: size.height - 8)),
                    with: .color(accentColor.opacity(0.5))
                )
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - PlaybackControlsRow
struct PlayerPlayPauseButton: View {
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 42))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 80, height: 80)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

struct PlaybackControlsRow: View {
    let isPlaying: Bool
    let hasPrevious: Bool
    let hasNext: Bool

    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onPrevious) {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .foregroundStyle(.white)
            }
            .disabled(!hasPrevious)
            .opacity(hasPrevious ? 1 : 0.3)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Previous")

            PlayerPlayPauseButton(isPlaying: isPlaying, action: onPlayPause)
            .frame(maxWidth: .infinity)

            Button(action: onNext) {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .foregroundStyle(.white)
            }
            .disabled(!hasNext)
            .opacity(hasNext ? 1 : 0.3)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Next")
        }
        .padding(.horizontal, 24)
    }
}

struct PlayerTransportAirPlayFooter: View {
    let isPlaying: Bool
    let hasPrevious: Bool
    let hasNext: Bool
    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PlaybackControlsRow(
                isPlaying: isPlaying,
                hasPrevious: hasPrevious,
                hasNext: hasNext,
                onPrevious: onPrevious,
                onPlayPause: onPlayPause,
                onNext: onNext
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPlaying)

            HStack {
                Spacer()
                PlayerAirPlayControl()
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)
    }
}

// MARK: - SecondaryActionsRow
/// AirPlay, aleatorio y cola: botones iguales, repartidos por igual.
struct SecondaryActionsRow: View {
    @Binding var showQueue: Bool
    /// En la pantalla de la cola el aleatorio ya esta arriba: no se repite abajo.
    var showsShuffle = true

    private let np = NowPlaying.shared
    @State private var shuffleCount = 0

    var body: some View {
        HStack(spacing: 0) {
            PlayerAirPlayControl()
                .frame(maxWidth: .infinity)

            if showsShuffle {
                // Tocar baraja la cola (y vuelve a barajarla cada vez que se toca); manteniendo pulsado se puede apagar.
                Menu {
                    if np.isShuffleOn {
                        Button {
                            np.disableShuffle()
                        } label: {
                            Label("Turn Off Shuffle", systemImage: "shuffle")
                        }
                    }
                } label: {
                    SecondaryIcon(systemImage: "shuffle", isOn: np.isShuffleOn)
                        .symbolEffect(.bounce, value: shuffleCount)
                } primaryAction: {
                    np.shuffleQueue()
                    shuffleCount += 1
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.impact(weight: .light), trigger: shuffleCount)
                .accessibilityLabel(Text("Shuffle"))
                .frame(maxWidth: .infinity)
            }

            SecondaryToggleButton(
                systemImage: "list.bullet",
                isOn: showQueue,
                accessibility: "Queue"
            ) {
                showQueue.toggle()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 12)
    }
}

/// El icono redondo del pie del reproductor: apagado se ve tenue y encendido se rellena de cristal claro.
struct SecondaryIcon: View {
    let systemImage: String
    let isOn: Bool

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.7))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 46, height: 46)
            .background(Circle().fill(isOn ? Color.white.opacity(0.2) : Color.clear))
            .contentShape(Circle())
            .animation(.easeInOut(duration: 0.2), value: isOn)
    }
}

struct SecondaryToggleButton: View {
    let systemImage: String
    let isOn: Bool
    let accessibility: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SecondaryIcon(systemImage: systemImage, isOn: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(accessibility)))
    }
}

struct PlayerAirPlayControl: View {
    var body: some View {
        Button {} label: {
            Image(systemName: "airplayaudio")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 46, height: 46)
        }
        .overlay(AirPlayButton())
        .accessibilityLabel("AirPlay")
    }
}

// MARK: - AirPlayButton
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: UIViewRepresentableContext<Self>) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor.clear
        picker.activeTintColor = UIColor.clear
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: UIViewRepresentableContext<Self>) {}
}
