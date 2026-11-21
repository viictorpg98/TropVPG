//
//  SonarLockWidgets.swift
//  SonarWidget
//
//  Widgets para la PANTALLA DE BLOQUEO del iPhone (con el movil bloqueado y el navegador puesto en CarPlay): uno por accion (Voz, Para ti, Mezclar,
//  DJ), cada uno en dos tamaños: circular (cuatro caben en una fila) o rectangular (dos caben en una fila, mucho mas grande). En los dos el boton
//  OCUPA TODO el widget: en la primera version el rectangular llevaba cuatro botones pequeños dentro y los toques fallaban y abrian la app (cualquier
//  toque fuera de un boton abre la app). Cada boton ejecuta la misma accion que su boton del widget principal (Shared/WidgetIntents.swift), que
//  corre en la app sin abrirla. Se añaden desde la pantalla de bloqueo (mantener pulsado > Personalizar). El DJ se ve encendido o apagado.
//

import AppIntents
import Foundation
import SwiftUI
import WidgetKit

struct SonarLockEntry: TimelineEntry {
    let date: Date
    /// El DJ esta encendido (dato de la app).
    let dj: Bool
}

struct SonarLockProvider: TimelineProvider {
    private func entry() -> SonarLockEntry {
        SonarLockEntry(date: Date(), dj: WidgetShared.loadButtonState()?.dj ?? false)
    }

    func placeholder(in context: Context) -> SonarLockEntry {
        SonarLockEntry(date: Date(), dj: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (SonarLockEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SonarLockEntry>) -> Void) {
        // La app recarga estos widgets cuando el DJ cambia; ademas se relee cada hora (como el resto, para que no dejen de responder).
        completion(Timeline(entries: [entry()], policy: .after(Date().addingTimeInterval(3600))))
    }
}

/// El boton de un widget de la pantalla de bloqueo: circular o rectangular segun el tamaño elegido, y siempre con el boton ocupando TODO el widget.
private struct LockButton<I: AppIntent>: View {
    @Environment(\.widgetFamily) private var family
    let intent: I
    let symbol: String
    let title: String

    var body: some View {
        switch family {
        case .accessoryRectangular:
            Button(intent: intent) {
                HStack(spacing: 8) {
                    // `widgetAccentable`: con un color elegido para la pantalla de bloqueo, el icono y el nombre lo toman (el fondo queda translucido).
                    Image(systemName: symbol)
                        .font(.system(size: 30, weight: .semibold))
                        .widgetAccentable()
                    Text(title)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .widgetAccentable()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.22)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        default:
            Button(intent: intent) {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .widgetAccentable()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private var lockSpanish: Bool {
    Locale.preferredLanguages.first?.hasPrefix("es") ?? false
}

struct SonarLockVoiceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarLockVoice", provider: SonarLockProvider()) { _ in
            LockButton(intent: WidgetVoiceIntent(), symbol: "mic.fill", title: lockSpanish ? "Voz" : "Voice")
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Sonar · Voz (bloqueo)")
        .description("Di qué quieres escuchar. Para la pantalla de bloqueo.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct SonarLockForYouWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarLockForYou", provider: SonarLockProvider()) { _ in
            LockButton(intent: WidgetMixIntent(), symbol: "waveform", title: lockSpanish ? "Para ti" : "For you")
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Sonar · Para ti (bloqueo)")
        .description("Pone tu mezcla Para ti. Para la pantalla de bloqueo.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct SonarLockMixWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarLockMix", provider: SonarLockProvider()) { _ in
            LockButton(intent: WidgetMixNowIntent(), symbol: "arrow.triangle.merge", title: lockSpanish ? "Mezclar" : "Mix")
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Sonar · Mezclar (bloqueo)")
        .description("Pasa a la siguiente canción con AutoMix. Para la pantalla de bloqueo.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct SonarLockDJWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarLockDJ", provider: SonarLockProvider()) { entry in
            LockButton(intent: WidgetDJIntent(), symbol: entry.dj ? "power.circle.fill" : "power", title: entry.dj ? "DJ · ON" : "DJ · OFF")
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Sonar · DJ (bloqueo)")
        .description("Enciende o apaga el DJ (se ve encendido o apagado). Para la pantalla de bloqueo.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

/// Los widgets de la pantalla de bloqueo, agrupados (un `WidgetBundle` admite pocos widgets directos).
struct SonarLockBundle: WidgetBundle {
    var body: some Widget {
        SonarLockVoiceWidget()
        SonarLockForYouWidget()
        SonarLockMixWidget()
        SonarLockDJWidget()
    }
}
