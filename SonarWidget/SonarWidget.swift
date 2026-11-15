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

    /// Colores de la marca (las barras del icono de Sonar: del naranja al rojo). Cada boton usa un tramo del degradado.
    private static let tileColor = Color(red: 0.16, green: 0.16, blue: 0.18)
    private static let iconInk = Color(red: 0.08, green: 0.08, blue: 0.09)

    private func tile<I: AppIntent>(
        _ intent: I, symbol: String, title: String, top: Color, bottom: Color
    ) -> some View {
        Button(intent: intent) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
                    Image(systemName: symbol)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Self.iconInk)
                }
                .frame(width: 42, height: 42)
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Opaco (no transparente): en CarPlay el widget pierde su fondo y el boton tiene que verse sobre cualquier tema.
            .background(Self.tileColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                tile(WidgetMixIntent(), symbol: "waveform", title: label("Mi mezcla", "My mix"),
                     top: Color(red: 1.00, green: 0.48, blue: 0.27), bottom: Color(red: 1.00, green: 0.27, blue: 0.33))
                tile(WidgetMixNowIntent(), symbol: "arrow.triangle.merge", title: label("Mezclar", "Mix now"),
                     top: Color(red: 1.00, green: 0.54, blue: 0.30), bottom: Color(red: 1.00, green: 0.35, blue: 0.29))
            }
            GridRow {
                tile(WidgetDiceIntent(), symbol: "dice.fill", title: label("Dado", "Surprise"),
                     top: Color(red: 1.00, green: 0.69, blue: 0.30), bottom: Color(red: 1.00, green: 0.48, blue: 0.27))
                tile(WidgetLikeIntent(), symbol: "hand.thumbsup.fill", title: label("Me gusta", "Like"),
                     top: Color(red: 1.00, green: 0.35, blue: 0.35), bottom: Color(red: 1.00, green: 0.23, blue: 0.42))
            }
        }
        .containerBackground(Color(red: 0.08, green: 0.08, blue: 0.09), for: .widget)
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
