//
//  SonarLockWidgets.swift
//  SonarWidget
//
//  Widgets para la PANTALLA DE BLOQUEO del iPhone (con el movil bloqueado y el navegador puesto en CarPlay): un circulo por accion (Voz, Para ti,
//  Mezclar, DJ) y uno rectangular con los cuatro botones juntos. Cada boton ejecuta la misma accion que su boton del widget principal
//  (Shared/WidgetIntents.swift), que corre en la app sin abrirla. Se añaden desde la pantalla de bloqueo (mantener pulsado > Personalizar).
//  El DJ se ve encendido o apagado (dato de `WidgetShared`, igual que en el widget principal).
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

/// Un boton redondo con su icono, para los widgets circulares de la pantalla de bloqueo.
private func lockCircle<I: AppIntent>(_ intent: I, symbol: String) -> some View {
    Button(intent: intent) {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
        }
    }
    .buttonStyle(.plain)
}

struct SonarLockVoiceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarLockVoice", provider: SonarLockProvider()) { _ in
            lockCircle(WidgetVoiceIntent(), symbol: "mic.fill")
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Sonar · Voz (bloqueo)")
        .description("Di qué quieres escuchar. Para la pantalla de bloqueo.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct SonarLockForYouWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarLockForYou", provider: SonarLockProvider()) { _ in
            lockCircle(WidgetMixIntent(), symbol: "waveform")
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Sonar · Para ti (bloqueo)")
        .description("Pone tu mezcla Para ti. Para la pantalla de bloqueo.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct SonarLockMixWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarLockMix", provider: SonarLockProvider()) { _ in
            lockCircle(WidgetMixNowIntent(), symbol: "arrow.triangle.merge")
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Sonar · Mezclar (bloqueo)")
        .description("Pasa a la siguiente canción con AutoMix. Para la pantalla de bloqueo.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct SonarLockDJWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarLockDJ", provider: SonarLockProvider()) { entry in
            lockCircle(WidgetDJIntent(), symbol: entry.dj ? "power.circle.fill" : "power")
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Sonar · DJ (bloqueo)")
        .description("Enciende o apaga el DJ (se ve encendido o apagado). Para la pantalla de bloqueo.")
        .supportedFamilies([.accessoryCircular])
    }
}

/// Un solo widget rectangular con los cuatro botones juntos (ocupa un hueco en vez de cuatro).
struct SonarLockRowWidget: Widget {
    private func rowButton<I: AppIntent>(_ intent: I, symbol: String) -> some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarLockRow", provider: SonarLockProvider()) { entry in
            HStack(spacing: 6) {
                rowButton(WidgetVoiceIntent(), symbol: "mic.fill")
                rowButton(WidgetMixIntent(), symbol: "waveform")
                rowButton(WidgetMixNowIntent(), symbol: "arrow.triangle.merge")
                rowButton(WidgetDJIntent(), symbol: entry.dj ? "power.circle.fill" : "power")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Sonar · Botones (bloqueo)")
        .description("Voz, Para ti, Mezclar y DJ en un solo widget de la pantalla de bloqueo.")
        .supportedFamilies([.accessoryRectangular])
    }
}

/// Los widgets de la pantalla de bloqueo, agrupados (un `WidgetBundle` admite pocos widgets directos).
struct SonarLockBundle: WidgetBundle {
    var body: some Widget {
        SonarLockVoiceWidget()
        SonarLockForYouWidget()
        SonarLockMixWidget()
        SonarLockDJWidget()
        SonarLockRowWidget()
    }
}
