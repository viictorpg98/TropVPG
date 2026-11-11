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
    static let levels: [Double] = [0.32, 0.54, 0.76, 1.0, 0.76, 0.54, 0.32]

    static let gradient = LinearGradient(
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

// MARK: - Pantalla de carga (la primera vez que se abre una pestaña)

/// Pantalla limpia con el logo animado en el centro, en lugar de bloques grises con brillo.
struct SonarLoadingScreen: View {
    var body: some View {
        SonarLoader(size: 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 90)
    }
}

// MARK: - Recargar tirando hacia abajo

/// Como `.refreshable`, pero con el logo animado en lugar del circulo del sistema: aparece y crece segun se tira, y sigue
/// animado mientras se recarga. (El circulo del sistema se deja transparente en `TropApp`.)
private struct SonarRefresh: ViewModifier {
    let action: @Sendable () async -> Void
    @State private var pull: CGFloat = 0
    @State private var refreshing = false

    func body(content: Content) -> some View {
        content
            .refreshable {
                refreshing = true
                await action()
                refreshing = false
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
            } action: { _, newValue in
                pull = newValue
            }
            .overlay(alignment: .top) {
                let progress = refreshing ? 1.0 : min(1.0, Double(pull) / 70)
                SonarLoader(size: 32)
                    .opacity(progress)
                    .scaleEffect(0.5 + 0.5 * progress)
                    .offset(y: refreshing ? 16 : max(0, pull * 0.45 - 6))
                    .animation(.smooth(duration: 0.25), value: refreshing)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func sonarRefreshable(_ action: @escaping @Sendable () async -> Void) -> some View {
        modifier(SonarRefresh(action: action))
    }
}

// MARK: - El logo (barras fijas)

/// Las siete barras del logo, quietas (cabecera de Ajustes...).
struct SonarLogoMark: View {
    var size: CGFloat = 40

    var body: some View {
        HStack(spacing: size * 0.09) {
            ForEach(0..<SonarLoader.levels.count, id: \.self) { index in
                Capsule()
                    .fill(SonarLoader.gradient)
                    .frame(width: size * 0.115, height: size * SonarLoader.levels[index])
            }
        }
        .frame(height: size)
        .accessibilityHidden(true)
    }
}
