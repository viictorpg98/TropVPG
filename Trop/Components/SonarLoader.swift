//
//  SonarLoader.swift
//  Trop
//
//  Indicador de carga con el logo de la app: sus siete barras (naranja a rojo), subiendo y bajando en ola desde el centro,
//  como un ecualizador. Sustituye al circulo del sistema en las pantallas que cargan.
//

import SwiftUI

struct SonarLoader: View {
    /// Alto del logo en puntos.
    var size: CGFloat = 48

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Altura relativa de cada barra en el logo (simetrico).
    private static let levels: [Double] = [0.32, 0.54, 0.76, 1.0, 0.76, 0.54, 0.32]

    private static let gradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.49, blue: 0.27), Color(red: 1.0, green: 0.27, blue: 0.32)],
        startPoint: .top, endPoint: .bottom
    )

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.09) {
                ForEach(0..<Self.levels.count, id: \.self) { index in
                    // Una ola que sale del centro hacia los lados.
                    let distance = Double(abs(index - 3))
                    let wave = reduceMotion ? 1.0 : 0.5 + 0.5 * sin(time * 4.4 - distance * 0.85)
                    let height = max(size * 0.14, size * Self.levels[index] * (0.38 + 0.62 * wave))
                    Capsule()
                        .fill(Self.gradient)
                        .frame(width: size * 0.115, height: height)
                }
            }
            .frame(height: size)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading…"))
    }
}
