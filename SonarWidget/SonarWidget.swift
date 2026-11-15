//
//  SonarWidget.swift
//  SonarWidget
//
//  Widget pequeno de Sonar con cuatro botones grandes. Sale en la galeria de widgets del iPhone y, en iOS 26, tambien en
//  CarPlay (Ajustes > General > CarPlay > tu coche > Personalizar). No muestra datos: solo botones, sin actualizaciones.
//  Las acciones estan en Shared/WidgetIntents.swift y las ejecuta la app.
//

import AppIntents
import Foundation
import SwiftUI
import WidgetKit

struct SonarWidgetEntry: TimelineEntry {
    let date: Date
}

struct SonarWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> SonarWidgetEntry {
        SonarWidgetEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (SonarWidgetEntry) -> Void) {
        completion(SonarWidgetEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SonarWidgetEntry>) -> Void) {
        // Una sola entrada que nunca se actualiza: los botones no cambian.
        completion(Timeline(entries: [SonarWidgetEntry(date: Date())], policy: .never))
    }
}

struct SonarWidgetView: View {
    /// El widget no puede leer los textos de la app: se elige aqui entre español e ingles.
    private var spanish: Bool {
        Locale.preferredLanguages.first?.hasPrefix("es") ?? false
    }

    private func label(_ es: String, _ en: String) -> String {
        spanish ? es : en
    }

    private func tile<I: AppIntent>(_ intent: I, symbol: String, title: String) -> some View {
        Button(intent: intent) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                tile(WidgetMixIntent(), symbol: "waveform", title: label("Mi mezcla", "My mix"))
                tile(WidgetMixNowIntent(), symbol: "arrow.triangle.merge", title: label("Mezclar", "Mix now"))
            }
            GridRow {
                tile(WidgetDiceIntent(), symbol: "dice.fill", title: label("Dado", "Surprise"))
                tile(WidgetLikeIntent(), symbol: "hand.thumbsup.fill", title: label("Me gusta", "Like"))
            }
        }
        .containerBackground(Color(white: 0.1), for: .widget)
    }
}

struct SonarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarWidget", provider: SonarWidgetProvider()) { _ in
            SonarWidgetView()
        }
        .configurationDisplayName("Sonar")
        .description("Mi mezcla, mezclar ahora, dado y Me gusta.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct SonarWidgetBundle: WidgetBundle {
    var body: some Widget {
        SonarWidget()
    }
}
