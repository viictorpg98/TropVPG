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
                            // El destello de la onda de relleno solo se mueve si suena algo (y a 15 fps basta).
                            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !NowPlaying.shared.isPlaying)) { timeline in
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
            drawWave(&context, size: size, levels: levels, shimmer: shimmer)
        }
        .allowsHitTesting(false)
    }

    /// Opacidad de una barra: sonada o no, y con el brillo que recorre la onda de relleno si lo hay.
    private func barOpacity(index: Int, count: Int, isPlayed: Bool, shimmer: Double?) -> Double {
        guard let shimmer else { return isPlayed ? 0.95 : 0.27 }
        let position: Double = Double(index) / Double(count)
        let wave: Double = sin(position * 9.0 - shimmer * 3.2)
        let base: Double = isPlayed ? 0.75 : 0.28
        return base + 0.22 * max(0.0, wave)
    }

    private func drawWave(_ context: inout GraphicsContext, size: CGSize, levels: [Float], shimmer: Double?) {
        let count: Int = levels.count
        guard count > 0 else { return }
        let slot: CGFloat = size.width / CGFloat(count)
        let played: CGFloat = CGFloat(progress)
        for index in 0..<count {
            let level: CGFloat = CGFloat(levels[index])
            let height: CGFloat = max(3, level * size.height)
            let x: CGFloat = CGFloat(index) * slot + slot * 0.2
            let y: CGFloat = (size.height - height) / 2
            let rect = CGRect(x: x, y: y, width: slot * 0.6, height: height)
            let middle: CGFloat = (CGFloat(index) + 0.5) / CGFloat(count)
            let opacity: Double = barOpacity(index: index, count: count, isPlayed: middle <= played, shimmer: shimmer)
            let bar = Path(roundedRect: rect, cornerRadius: slot * 0.3)
            context.fill(bar, with: .color(Color.white.opacity(opacity)))
        }
        // Donde va.
        let head: CGFloat = size.width * played
        let headRect = CGRect(x: head - 1, y: 0, width: 2, height: size.height)
        context.fill(Path(roundedRect: headRect, cornerRadius: 1), with: .color(accentColor))
        // Donde empezara la proxima mezcla.
        if let markerFraction {
            let x: CGFloat = size.width * CGFloat(markerFraction)
            var diamond = Path()
            diamond.move(to: CGPoint(x: x, y: 0))
            diamond.addLine(to: CGPoint(x: x + 4, y: 4))
            diamond.addLine(to: CGPoint(x: x, y: 8))
            diamond.addLine(to: CGPoint(x: x - 4, y: 4))
            diamond.closeSubpath()
            context.fill(diamond, with: .color(accentColor))
            let stem = CGRect(x: x - 0.5, y: 8, width: 1, height: size.height - 8)
            context.fill(Path(stem), with: .color(accentColor.opacity(0.5)))
        }
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
    /// Aleatorio a la izquierda del todo y repetir a la derecha del todo, como en YouTube Music.
    var showsModes = false

    private let np = NowPlaying.shared

    private var previousButton: some View {
        Button(action: onPrevious) {
            Image(systemName: "backward.fill")
                .font(.title)
                .foregroundStyle(.white)
        }
        .disabled(!hasPrevious)
        .opacity(hasPrevious ? 1 : 0.3)
        .accessibilityLabel("Previous")
    }

    private var nextButton: some View {
        Button(action: onNext) {
            Image(systemName: "forward.fill")
                .font(.title)
                .foregroundStyle(.white)
        }
        .disabled(!hasNext)
        .opacity(hasNext ? 1 : 0.3)
        .accessibilityLabel("Next")
    }

    var body: some View {
        if showsModes {
            HStack(spacing: 0) {
                ShuffleModeButton()
                Spacer(minLength: 4)
                previousButton
                Spacer(minLength: 4)
                PlayerPlayPauseButton(isPlaying: isPlaying, action: onPlayPause)
                Spacer(minLength: 4)
                nextButton
                Spacer(minLength: 4)
                SecondaryToggleButton(
                    systemImage: np.isRepeatOn ? "repeat.1" : "repeat",
                    isOn: np.isRepeatOn,
                    accessibility: np.isRepeatOn ? "Repeat one" : "Repeat all"
                ) {
                    np.isRepeatOn.toggle()
                }
            }
            .padding(.horizontal, 14)
        } else {
            HStack(spacing: 0) {
                previousButton
                    .frame(maxWidth: .infinity)

                PlayerPlayPauseButton(isPlaying: isPlaying, action: onPlayPause)
                    .frame(maxWidth: .infinity)

                nextButton
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
        }
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

// MARK: - Aleatorio
/// Tocar baraja la cola (y la vuelve a barajar cada vez que se toca); manteniendo pulsado se puede apagar.
struct ShuffleModeButton: View {
    private let np = NowPlaying.shared
    @State private var shuffleCount = 0

    var body: some View {
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
