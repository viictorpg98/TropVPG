//
//  SonarLockWidgets.swift
//  SonarWidget
//
//  Widgets para la PANTALLA DE BLOQUEO del iPhone (con el movil bloqueado y el navegador puesto en CarPlay): un circulo por accion (Voz, Para ti,
//  Mezclar, DJ) y dos rectangulares con dos botones GRANDES cada uno (Voz + Para ti, Mezclar + DJ). Cada boton ejecuta la misma accion que su boton del widget principal
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
                .font(.system(size: 26, weight: .semibold))
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

private var lockSpanish: Bool {
    Locale.preferredLanguages.first?.hasPrefix("es") ?? false
}

/// Un boton grande con icono y nombre, para los widgets rectangulares de la pantalla de bloqueo: 2 por widget, mucho mas faciles de pulsar que 4 pequeños.
private func lockBigButton<I: AppIntent>(_ intent: I, symbol: String, title: String) -> some View {
    Button(intent: intent) {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.22)))
    }
    .buttonStyle(.plain)
}

/// Rectangular A: Voz y Para ti, grandes.
struct SonarLockPairAWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarLockPairA", provider: SonarLockProvider()) { _ in
            HStack(spacing: 6) {
                lockBigButton(WidgetVoiceIntent(), symbol: "mic.fill", title: lockSpanish ? "Voz" : "Voice")
                lockBigButton(WidgetMixIntent(), symbol: "waveform", title: lockSpanish ? "Para ti" : "For you")
            }
            .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Sonar · Voz y Para ti (bloqueo)")
        .description("Dos botones grandes para la pantalla de bloqueo: Voz y Para ti.")
        .supportedFamilies([.accessoryRectangular])
    }
}

/// Rectangular B: Mezclar y DJ (con su estado), grandes.
struct SonarLockPairBWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarLockPairB", provider: SonarLockProvider()) { entry in
            HStack(spacing: 6) {
                lockBigButton(WidgetMixNowIntent(), symbol: "arrow.triangle.merge", title: lockSpanish ? "Mezclar" : "Mix")
                lockBigButton(WidgetDJIntent(), symbol: entry.dj ? "power.circle.fill" : "power", title: entry.dj ? "DJ · ON" : "DJ · OFF")
            }
            .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Sonar · Mezclar y DJ (bloqueo)")
        .description("Dos botones grandes para la pantalla de bloqueo: Mezclar y DJ (se ve si esta encendido).")
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
        SonarLockPairAWidget()
        SonarLockPairBWidget()
    }
}
