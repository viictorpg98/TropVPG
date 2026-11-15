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

    /// En la pantalla de inicio el widget tiene fondo; en CarPlay y StandBy el sistema se lo quita.
    @Environment(\.showsWidgetContainerBackground) private var showsBackground

    /// Colores de la marca (las barras del icono de Sonar: del naranja al rojo). Cada boton usa un tramo del degradado.
    private static let plateColor = Color(red: 0.16, green: 0.16, blue: 0.18)
    private static let iconInk = Color(red: 0.08, green: 0.08, blue: 0.09)

    private func tile<I: AppIntent>(
        _ intent: I, symbol: String, title: String, top: Color, bottom: Color
    ) -> some View {
        Button(intent: intent) {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
                    Image(systemName: symbol)
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(Self.iconInk)
                }
                .frame(width: 50, height: 50)
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Con fondo (pantalla de inicio): sin cajas, los circulos van directos sobre el fondo; el casi-nada de opacidad solo
            // sirve para que toda la celda sea tocable. Sin fondo (CarPlay): una placa oscura opaca detras para que se vea sobre
            // cualquier tema del coche.
            .background(showsBackground ? Color.black.opacity(0.01) : Self.plateColor,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        Grid(horizontalSpacing: showsBackground ? 0 : 6, verticalSpacing: showsBackground ? 0 : 6) {
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
        .padding(6)
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
        // Sin los margenes por defecto (unos 16 pt): el contenido ocupa casi todo el widget, con su propio margen pequeno.
        .contentMarginsDisabled()
    }
}

@main
struct SonarWidgetBundle: WidgetBundle {
    var body: some Widget {
        SonarWidget()
    }
}
