//
//  MixCurveEditorView.swift
//  Trop
//
//  El editor de curvas de una mezcla (como el de Spotify): arriba la saliente y abajo la entrante, cada una con su forma de onda y, encima,
//  la curva del carril elegido (volumen, graves o filtro) con puntos que se arrastran. Tocar la curva añade un punto; tocar un punto
//  intermedio lo quita. El eje horizontal es lo que dura la mezcla (la parte clara); a los lados se ve un poco de la cancion antes y despues.
//
//  No es una lista: es una sola superficie, para que arrastrar no se mezcle con desplazar.
//

import SwiftUI

struct MixCurveEditorView: View {
    @Binding var curves: MixCurves
    let outgoingWave: [Float]?
    let outgoingSeconds: Double
    let outgoingStart: Double
    let outgoingEnd: Double
    let incomingWave: [Float]?
    let incomingSeconds: Double
    let incomingStart: Double
    let incomingEnd: Double
    /// Se llama al soltar (para guardar lo elegido).
    let onCommit: () -> Void
    /// Escuchar la mezcla (o pararla si ya suena).
    let onPreview: () -> Void

    @State private var lane: MixLane = .volume
    /// El punto que se esta arrastrando: (es de la saliente, posicion en su curva).
    @State private var active: (outgoing: Bool, index: Int)?
    @State private var moved = false
    @State private var previewPlayer = MixPreviewPlayer.shared

    private let paneHeight: CGFloat = 150
    private let paneGap: CGFloat = 14
    private let verticalPadding: CGFloat = 12
    private let hitRadius: CGFloat = 26

    private var laneColor: Color {
        switch lane {
        case .volume: return .cyan
        case .bass: return .yellow
        case .filter: return .pink
        case .effect: return .purple
        }
    }

    /// El efecto solo actua sobre la saliente: en ese carril la curva de la entrante no se enseña ni se toca.
    private var visibleSides: [Bool] { lane == .effect ? [true] : [true, false] }

    var body: some View {
        VStack(spacing: 14) {
            Picker("Curve", selection: $lane) {
                Text("Volume").tag(MixLane.volume)
                Text("Bass").tag(MixLane.bass)
                Text("Filter").tag(MixLane.filter)
                Text("Effects").tag(MixLane.effect)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            GeometryReader { geometry in
                let size = geometry.size
                ZStack(alignment: .topLeading) {
                    pane(
                        wave: outgoingWave, total: outgoingSeconds, start: outgoingStart, end: outgoingEnd, tint: .orange,
                        width: size.width
                    )
                    .frame(width: size.width, height: paneHeight)
                    pane(
                        wave: incomingWave, total: incomingSeconds, start: incomingStart, end: incomingEnd, tint: .blue,
                        width: size.width
                    )
                    .frame(width: size.width, height: paneHeight)
                    .offset(y: paneHeight + paneGap)

                    Canvas { context, canvasSize in
                        drawCurves(&context, width: canvasSize.width)
                    }
                    .frame(width: size.width, height: paneHeight * 2 + paneGap)
                    .allowsHitTesting(false)
                }
                .frame(width: size.width, height: paneHeight * 2 + paneGap)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in dragChanged(value, width: size.width) }
                        .onEnded { value in dragEnded(value, width: size.width) }
                )
            }
            .frame(height: paneHeight * 2 + paneGap)

            VStack(spacing: 10) {
                Text("Drag the points to shape the curve. Tap the line to add a point, tap a point to remove it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button {
                        onPreview()
                    } label: {
                        HStack(spacing: 5) {
                            if previewPlayer.state == .preparing {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: previewPlayer.state == .playing ? "stop.fill" : "play.fill")
                            }
                            Text(LocalizedStringKey(
                                previewPlayer.state == .playing ? "Stop Preview"
                                    : (previewPlayer.state == .preparing ? "Preparing the preview…" : "Preview Mix")
                            ))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(previewPlayer.state == .preparing)

                    Button {
                        curves.set(lane, .make(lane, lane.presets[0]))
                        onCommit()
                    } label: {
                        Text("Reset This Curve")
                    }
                    .buttonStyle(.bordered)
                }
                if let status = previewPlayer.statusText {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .navigationTitle("Edit Curves")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { previewPlayer.stop() }
    }

    // MARK: Dibujo

    /// Margen a cada lado: la mezcla ocupa el centro; a los lados se ve la cancion antes y despues.
    private func margin(_ width: CGFloat) -> CGFloat { width * 0.14 }

    private func xPosition(_ progress: Double, width: CGFloat) -> CGFloat {
        margin(width) + CGFloat(progress) * (width - 2 * margin(width))
    }

    private func progress(atX x: CGFloat, width: CGFloat) -> Double {
        Double((x - margin(width)) / max(width - 2 * margin(width), 1))
    }

    private func paneTop(outgoing: Bool) -> CGFloat { outgoing ? 0 : paneHeight + paneGap }

    private func yPosition(_ value: Double, outgoing: Bool) -> CGFloat {
        paneTop(outgoing: outgoing) + verticalPadding + CGFloat(1 - value) * (paneHeight - 2 * verticalPadding)
    }

    private func value(atY y: CGFloat, outgoing: Bool) -> Double {
        Double(1 - (y - paneTop(outgoing: outgoing) - verticalPadding) / (paneHeight - 2 * verticalPadding))
    }

    private func points(outgoing: Bool) -> [MixPoint] {
        let value = curves.lane(lane)
        return outgoing ? value.outgoing : value.incoming
    }

    /// La onda de una cancion con la mezcla en el centro (la ventana mide lo que dura la mezcla mas lo que se ve a cada lado).
    @ViewBuilder
    private func pane(wave: [Float]?, total: Double, start: Double, end: Double, tint: Color, width: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.10))
            if let wave {
                let duration = max(end - start, 1)
                let central = Double(1 - 2 * 0.14)
                let side = duration * (1 - central) / 2 / central
                MixWaveformStrip(
                    wave: wave, totalSeconds: total, windowStart: start - side, windowEnd: end + side,
                    startSeconds: start, endSeconds: end, tint: tint, height: paneHeight - 2 * verticalPadding
                )
            }
            // La parte de la mezcla (clara) y sus bordes.
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: width - 2 * margin(width))
        }
    }

    private func drawCurves(_ context: inout GraphicsContext, width: CGFloat) {
        for outgoing in visibleSides {
            let list = points(outgoing: outgoing)
            guard list.count >= 2 else { continue }
            var path = Path()
            for (index, point) in list.enumerated() {
                let position = CGPoint(x: xPosition(point.x, width: width), y: yPosition(point.y, outgoing: outgoing))
                if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
            }
            // Las curvas siguen de forma plana hasta los bordes de la zona de la mezcla.
            context.stroke(path, with: .color(laneColor), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            for point in list {
                let center = CGPoint(x: xPosition(point.x, width: width), y: yPosition(point.y, outgoing: outgoing))
                let circle = Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16))
                context.fill(circle, with: .color(.black))
                context.stroke(circle, with: .color(laneColor), lineWidth: 3)
            }
        }
    }

    // MARK: Gestos

    /// El punto mas cercano (de las dos curvas del carril) a `location`, si esta a menos de `hitRadius`.
    private func nearestPoint(to location: CGPoint, width: CGFloat) -> (outgoing: Bool, index: Int)? {
        var best: (outgoing: Bool, index: Int, distance: CGFloat)?
        for outgoing in visibleSides {
            for (index, point) in points(outgoing: outgoing).enumerated() {
                let center = CGPoint(x: xPosition(point.x, width: width), y: yPosition(point.y, outgoing: outgoing))
                let distance = hypot(center.x - location.x, center.y - location.y)
                if distance <= hitRadius, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                    best = (outgoing, index, distance)
                }
            }
        }
        return best.map { ($0.outgoing, $0.index) }
    }

    private func dragChanged(_ value: DragGesture.Value, width: CGFloat) {
        if active == nil, !moved, value.translation == .zero || hypot(value.translation.width, value.translation.height) < 1 {
            active = nearestPoint(to: value.startLocation, width: width)
        }
        guard let active else { return }
        if hypot(value.translation.width, value.translation.height) > 4 { moved = true }
        guard moved else { return }
        let point = MixPoint(
            x: progress(atX: value.location.x, width: width),
            y: self.value(atY: value.location.y, outgoing: active.outgoing)
        )
        curves.move(lane, outgoing: active.outgoing, index: active.index, to: point)
    }

    private func dragEnded(_ value: DragGesture.Value, width: CGFloat) {
        defer {
            active = nil
            moved = false
        }
        if let active {
            if !moved {
                // Un toque en un punto: se quita (si es intermedio).
                curves.remove(lane, outgoing: active.outgoing, index: active.index)
            }
            onCommit()
            return
        }
        // Un toque sobre la curva (lejos de cualquier punto): se añade un punto ahi.
        guard !moved else { return }
        let location = value.startLocation
        let outgoing = location.y < paneHeight + paneGap / 2
        guard visibleSides.contains(outgoing) else { return }
        let fraction = progress(atX: location.x, width: width)
        guard fraction > 0, fraction < 1 else { return }
        let curveY = yPosition(MixCurves.value(of: points(outgoing: outgoing), at: fraction), outgoing: outgoing)
        guard abs(curveY - location.y) <= hitRadius else { return }
        curves.insert(lane, outgoing: outgoing, atX: fraction)
        onCommit()
    }
}
