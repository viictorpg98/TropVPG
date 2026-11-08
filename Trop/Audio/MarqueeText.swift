//
//  MarqueeText.swift
//  Trop
//

import SwiftUI

/// Titulo de una sola linea: se queda quieto, empezando por el principio, y solo se desplaza si no cabe
/// entero. Todo el movimiento sale de UN bucle atado al texto y a cuanto sobra: si cambia cualquiera de los
/// dos (otra cancion, otro ancho) el bucle se reinicia desde el principio, sin estados que se queden a medias.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var frameHeight: CGFloat = 24
    var textColor: Color = .white

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private let fadeWidth: CGFloat = 12
    private let speed: CGFloat = 24            // puntos por segundo
    private let startDelay: Double = 2         // quieto al principio antes de moverse
    private let endPause: Double = 1.2         // pausa al llegar al final
    /// Por debajo de este margen se considera que cabe (evita animar por un par de puntos).
    private let overflowThreshold: CGFloat = 2

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }
    private var shouldScroll: Bool { containerWidth > 0 && overflow > overflowThreshold }

    private struct ScrollKey: Equatable {
        let text: String
        let overflow: Int
        let scrolls: Bool
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(textColor)
                .background(
                    GeometryReader { textGeo in
                        Color.clear.preference(key: TextWidthKey.self, value: textGeo.size.width)
                    }
                )
                .offset(x: offset)
                .frame(width: width, height: geo.size.height, alignment: .leading)
                .clipped()
                .mask(fadeMask(width: width))
                .onAppear { containerWidth = width }
                .onChange(of: width) { _, newWidth in containerWidth = newWidth }
                .onPreferenceChange(TextWidthKey.self) { textWidth = $0 }
        }
        .frame(height: frameHeight)
        .accessibilityLabel(text)
        .task(id: ScrollKey(text: text, overflow: Int(overflow.rounded()), scrolls: shouldScroll)) {
            await runScroll()
        }
    }

    // MARK: - Desplazamiento

    @MainActor
    private func runScroll() async {
        setOffset(0)
        guard shouldScroll else { return }
        let distance = overflow + fadeWidth
        let duration = Double(distance / speed)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: duration)) { offset = -distance }
            try? await Task.sleep(nanoseconds: UInt64((duration + endPause) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            setOffset(0)
        }
    }

    /// Cambia la posicion sin animar (al reiniciar el texto vuelve de golpe al principio).
    private func setOffset(_ value: CGFloat) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { offset = value }
    }

    // MARK: - Difuminado de los bordes

    private func fadeMask(width: CGFloat) -> some View {
        let safe = max(width, 1)
        let trailingFade = shouldScroll ? min(fadeWidth, safe / 2) : 0
        let leadingFade = (shouldScroll && offset < -1) ? min(fadeWidth, safe / 2) : 0
        let start = leadingFade / safe
        let end = 1 - trailingFade / safe
        return LinearGradient(
            stops: [
                .init(color: leadingFade > 0 ? .clear : .black, location: 0),
                .init(color: .black, location: start),
                .init(color: .black, location: end),
                .init(color: trailingFade > 0 ? .clear : .black, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Medicion del texto

private struct TextWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
