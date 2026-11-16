//
//  SonarWidget.swift
//  SonarWidget
//
//  Widget pequeno de Sonar con cuatro botones: un circulo de color con su nombre debajo. Sale en la galeria de widgets del iPhone
//  y, en iOS 26, tambien en CarPlay (Ajustes > General > CarPlay > tu coche > Personalizar).
//  Las acciones estan en Shared/WidgetIntents.swift y las ejecuta la app. "Me gusta" cambia de aspecto cuando la cancion que
//  suena ya te gusta (la app deja ese dato en la carpeta compartida: Shared/WidgetShared.swift).
//
//  El efecto de pulsar es el del sistema: el boton se encoge. Para que se encoja SOLO el circulo (y no un bloque entero con su
//  nombre), el boton es solo el circulo y el nombre va debajo, fuera del boton. El boton usa `.bordered` con tinte transparente:
//  asi el sistema da el efecto de pulsar pero no pinta ningun aro ni bloque en reposo (se compararon varios estilos en pruebas).
//

import AppIntents
import Foundation
import SwiftUI
import WidgetKit

struct SonarWidgetEntry: TimelineEntry {
    let date: Date
    /// La cancion que suena ya te gusta (dato de la app).
    let liked: Bool
}

struct SonarWidgetProvider: TimelineProvider {
    private func entry() -> SonarWidgetEntry {
        SonarWidgetEntry(date: Date(), liked: WidgetShared.loadNowPlaying()?.liked ?? false)
    }

    func placeholder(in context: Context) -> SonarWidgetEntry {
        SonarWidgetEntry(date: Date(), liked: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (SonarWidgetEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SonarWidgetEntry>) -> Void) {
        // La app recarga el widget cuando cambia la cancion o su Me gusta; ademas se relee cada hora: con "nunca", algunos widgets
        // interactivos dejaban de responder tras horas parados (un hilo del foro de Apple lo cuenta).
        completion(Timeline(entries: [entry()], policy: .after(Date().addingTimeInterval(3600))))
    }
}

struct SonarWidgetView: View {
    let entry: SonarWidgetEntry

    /// El widget no puede leer los textos de la app: se elige aqui entre español e ingles.
    private var spanish: Bool {
        Locale.preferredLanguages.first?.hasPrefix("es") ?? false
    }

    private func label(_ es: String, _ en: String) -> String {
        spanish ? es : en
    }

    /// En la pantalla de inicio el widget tiene fondo; en CarPlay y StandBy el sistema se lo quita.
    @Environment(\.showsWidgetContainerBackground) private var showsBackground

    private static let plateColor = Color(red: 0.16, green: 0.16, blue: 0.18)
    private static let iconInk = Color(red: 0.08, green: 0.08, blue: 0.09)

    /// Lo que se encoge al pulsar: el circulo de color con su icono. Sin margen invisible de mas: el propio estilo del boton ya
    /// añade su zona tocable, y asi el nombre de debajo cabe entero.
    private func circle(symbol: String, top: Color, bottom: Color, inverted: Bool) -> some View {
        ZStack {
            Circle()
                .fill(
                    inverted
                        ? AnyShapeStyle(Color.white)
                        : AnyShapeStyle(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
                )
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(inverted ? bottom : Self.iconInk)
        }
        .frame(width: 42, height: 42)
    }

    private func tile<I: AppIntent>(
        _ intent: I, symbol: String, title: String, top: Color, bottom: Color, inverted: Bool = false
    ) -> some View {
        VStack(spacing: 0) {
            Button(intent: intent) {
                circle(symbol: symbol, top: top, bottom: bottom, inverted: inverted)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .tint(.clear)
            // El nombre va fuera del boton: asi no se encoge con el.
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Sin fondo del widget (CarPlay): una placa oscura opaca detras para que se vea sobre cualquier tema del coche.
        .background(showsBackground ? Color.clear : Self.plateColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    var body: some View {
        Grid(horizontalSpacing: showsBackground ? 0 : 6, verticalSpacing: showsBackground ? 0 : 6) {
            GridRow {
                tile(WidgetMixIntent(), symbol: "waveform", title: label("Para ti", "For you"),
                     top: Color(red: 1.00, green: 0.48, blue: 0.27), bottom: Color(red: 1.00, green: 0.27, blue: 0.33))
                tile(WidgetMixNowIntent(), symbol: "arrow.triangle.merge", title: label("Mezclar", "Mix now"),
                     top: Color(red: 1.00, green: 0.54, blue: 0.30), bottom: Color(red: 1.00, green: 0.35, blue: 0.29))
            }
            GridRow {
                tile(WidgetRadioIntent(), symbol: "dot.radiowaves.left.and.right", title: "Radio",
                     top: Color(red: 1.00, green: 0.69, blue: 0.30), bottom: Color(red: 1.00, green: 0.48, blue: 0.27))
                // Si la cancion que suena ya te gusta: circulo blanco con el pulgar relleno y "Te gusta".
                tile(WidgetLikeIntent(),
                     symbol: entry.liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                     title: entry.liked ? label("Te gusta", "Liked") : label("Me gusta", "Like"),
                     top: Color(red: 1.00, green: 0.35, blue: 0.35), bottom: Color(red: 1.00, green: 0.23, blue: 0.42),
                     inverted: entry.liked)
            }
        }
        .padding(4)
        .containerBackground(Color.black, for: .widget)
    }
}

struct SonarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarWidget", provider: SonarWidgetProvider()) { entry in
            SonarWidgetView(entry: entry)
        }
        .configurationDisplayName("Sonar")
        .description("Para ti, mezclar ahora, radio de la canción y Me gusta.")
        .supportedFamilies([.systemSmall])
        // Sin los margenes por defecto (unos 16 pt): el contenido ocupa casi todo el widget, con su propio margen pequeno.
        .contentMarginsDisabled()
    }
}

@main
struct SonarWidgetBundle: WidgetBundle {
    var body: some Widget {
        SonarWidget()
        SonarQuickPicksWidget()
        SonarSpeedDialWidget()
        SonarEpisodesWidget()
    }
}
