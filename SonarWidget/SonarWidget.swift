//
//  SonarWidget.swift
//  SonarWidget
//
//  Widget pequeno de Sonar con cuatro botones: un circulo de color con su nombre debajo. Sale en la galeria de widgets del iPhone
//  y, en iOS 26, tambien en CarPlay (Ajustes > General > CarPlay > tu coche > Personalizar).
//  Botones: Para ti (tu mezcla), Mezclar (pasar a la siguiente con AutoMix), DJ (encender o apagar) y Voz (di que quieres escuchar). El boton
//  de actualizar las portadas de los demas widgets esta en su propio widget (SonarRefreshWidget.swift). Las acciones estan en Shared/WidgetIntents.swift y las ejecuta la app.
//
//  El boton DJ se ve ENCENDIDO o APAGADO sin lugar a dudas, y no solo por el color (en los modos tintado o transparente del iPhone
//  el color se aplana): encendido es un circulo verde relleno con un aro blanco alrededor y el texto "DJ · ON"; apagado es un circulo
//  oscuro con borde fino, el simbolo apagado y el texto "DJ · OFF" en gris. El dato lo deja la app en la carpeta compartida
//  (Shared/WidgetShared.swift).
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
    /// El DJ esta encendido (dato de la app).
    let dj: Bool
}

struct SonarWidgetProvider: TimelineProvider {
    private func entry() -> SonarWidgetEntry {
        SonarWidgetEntry(date: Date(), dj: WidgetShared.loadButtonState()?.dj ?? false)
    }

    func placeholder(in context: Context) -> SonarWidgetEntry {
        SonarWidgetEntry(date: Date(), dj: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (SonarWidgetEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SonarWidgetEntry>) -> Void) {
        // La app recarga el widget cuando el DJ se enciende o se apaga; ademas se relee cada hora: con "nunca", algunos widgets
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
    private static let djOnTop = Color(red: 0.30, green: 0.88, blue: 0.48)
    private static let djOnBottom = Color(red: 0.10, green: 0.68, blue: 0.40)

    /// Lo que se encoge al pulsar: el circulo de color con su icono. Sin margen invisible de mas: el propio estilo del boton ya
    /// añade su zona tocable, y asi el nombre de debajo cabe entero.
    private func circle(symbol: String, top: Color, bottom: Color) -> some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Self.iconInk)
        }
        .frame(width: 42, height: 42)
    }

    /// El circulo del boton DJ. Encendido: aro blanco grueso + circulo verde relleno dentro. Apagado: circulo oscuro con un borde fino y
    /// el simbolo atenuado. Se distinguen por forma (aro o no) y por brillo, no solo por el tono.
    private func djCircle(on: Bool) -> some View {
        ZStack {
            if on {
                Circle().strokeBorder(Color.white, lineWidth: 3)
                Circle()
                    .fill(LinearGradient(colors: [Self.djOnTop, Self.djOnBottom], startPoint: .top, endPoint: .bottom))
                    .padding(6)
            } else {
                Circle().fill(Color(red: 0.24, green: 0.24, blue: 0.27))
                Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            }
            Image(systemName: "power")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(on ? Self.iconInk : Color.white.opacity(0.8))
        }
        .frame(width: 42, height: 42)
    }

    private func tile<I: AppIntent, Face: View>(
        _ intent: I, title: String, titleColor: Color = .white, @ViewBuilder face: () -> Face
    ) -> some View {
        VStack(spacing: 0) {
            Button(intent: intent) {
                face()
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .tint(.clear)
            // El nombre va fuera del boton: asi no se encoge con el.
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(titleColor)
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
                tile(WidgetMixIntent(), title: label("Para ti", "For you")) {
                    circle(symbol: "waveform",
                           top: Color(red: 1.00, green: 0.48, blue: 0.27), bottom: Color(red: 1.00, green: 0.27, blue: 0.33))
                }
                tile(WidgetMixNowIntent(), title: label("Mezclar", "Mix now")) {
                    circle(symbol: "arrow.triangle.merge",
                           top: Color(red: 1.00, green: 0.54, blue: 0.30), bottom: Color(red: 1.00, green: 0.35, blue: 0.29))
                }
            }
            GridRow {
                tile(
                    WidgetDJIntent(),
                    title: entry.dj ? "DJ · ON" : "DJ · OFF",
                    titleColor: entry.dj ? .white : Color.white.opacity(0.78)
                ) {
                    djCircle(on: entry.dj)
                }
                tile(WidgetVoiceIntent(), title: label("Voz", "Voice")) {
                    circle(symbol: "mic.fill",
                           top: Color(red: 0.36, green: 0.80, blue: 1.00), bottom: Color(red: 0.22, green: 0.52, blue: 0.98))
                }
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
        .description("Para ti, mezclar ahora, DJ (encendido o apagado) y voz: di qué quieres escuchar.")
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
        SonarQuickPicksBWidget()
        SonarSpeedDialWidget()
        SonarRefreshWidget()
        SonarVoiceActivityWidget()
        SonarLockBundle().body
        SonarControlsBundle().body
    }
}
