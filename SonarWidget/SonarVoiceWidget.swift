//
//  SonarVoiceWidget.swift
//  SonarWidget
//
//  Widget pequeno "Sonar · Voz": tres botones de microfono (1, 2 y 3: variantes de prueba). Al pulsarlo, Sonar pregunta por voz "¿Qué quieres escuchar?", reconoce lo que dices y
//  lo busca como en el buscador. Es un experimento para CarPlay (sin abrir la app): ver `VoiceSearch` en la app. La accion esta en
//  Shared/WidgetIntents.swift (`WidgetVoiceIntent`) y la ejecuta la app. Sale en la galeria de widgets y, en iOS 26, en CarPlay (Ajustes > General >
//  CarPlay > tu coche > Personalizar), con el mismo estilo de boton que el widget de botones.
//

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct SonarVoiceEntry: TimelineEntry {
    let date: Date
}

struct SonarVoiceProvider: TimelineProvider {
    func placeholder(in context: Context) -> SonarVoiceEntry {
        SonarVoiceEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (SonarVoiceEntry) -> Void) {
        completion(SonarVoiceEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SonarVoiceEntry>) -> Void) {
        // Se relee cada hora: con "nunca", algunos widgets interactivos dejaban de responder tras horas parados.
        completion(Timeline(entries: [SonarVoiceEntry(date: Date())], policy: .after(Date().addingTimeInterval(3600))))
    }
}

struct SonarVoiceView: View {
    @Environment(\.showsWidgetContainerBackground) private var showsBackground

    private var spanish: Bool {
        Locale.preferredLanguages.first?.hasPrefix("es") ?? false
    }

    private static let plateColor = Color(red: 0.16, green: 0.16, blue: 0.18)
    private static let iconInk = Color(red: 0.08, green: 0.08, blue: 0.09)

    /// Un boton de microfono con su numero debajo (el numero es la variante del experimento: ver Shared/WidgetIntents.swift).
    private func voiceButton<I: AppIntent>(_ intent: I, label: String) -> some View {
        VStack(spacing: 2) {
            Button(intent: intent) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color(red: 0.36, green: 0.80, blue: 1.00), Color(red: 0.22, green: 0.52, blue: 0.98)],
                            startPoint: .top, endPoint: .bottom
                        ))
                    Image(systemName: "mic.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Self.iconInk)
                }
                .frame(width: 38, height: 38)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .tint(.clear)
            // El numero va fuera del boton: asi no se encoge con el.
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                .lineLimit(1)
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            // EXPERIMENTO: tres variantes del mismo boton para ver cual no mata la app al sonar la cancion.
            HStack(spacing: 2) {
                voiceButton(WidgetVoiceIntent(), label: "1")
                voiceButton(WidgetVoiceListenIntent(), label: "2")
                voiceButton(WidgetVoicePlainIntent(), label: "3")
            }
            Text(spanish ? "Voz (prueba)" : "Voice (test)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Sin fondo del widget (CarPlay): una placa oscura opaca detras para que se vea sobre cualquier tema del coche.
        .background(showsBackground ? Color.clear : Self.plateColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(4)
        .containerBackground(Color.black, for: .widget)
    }
}

struct SonarVoiceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarVoice", provider: SonarVoiceProvider()) { _ in
            SonarVoiceView()
        }
        .configurationDisplayName("Sonar · Voz")
        .description("Di qué quieres escuchar y Sonar lo busca y lo pone. Experimento para CarPlay.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

/// La Live Activity "Escuchando…" (pantalla de bloqueo y Dynamic Island). Dura lo que dura la escucha.
struct SonarVoiceActivityWidget: Widget {
    private var spanish: Bool {
        Locale.preferredLanguages.first?.hasPrefix("es") ?? false
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceActivityAttributes.self) { context in
            HStack(spacing: 10) {
                Image(systemName: context.state.phase == "playing" ? "waveform" : "mic.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color(red: 0.36, green: 0.80, blue: 1.00))
                Text(context.state.phase == "playing"
                    ? (spanish ? "Sonar: reproduciendo…" : "Sonar: playing…")
                    : (spanish ? "Sonar: escuchando…" : "Sonar: listening…"))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(14)
            .activityBackgroundTint(Color.black)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.phase == "playing"
                        ? (spanish ? "Reproduciendo…" : "Playing…")
                        : (spanish ? "Escuchando…" : "Listening…"))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
            } compactLeading: {
                Image(systemName: "mic.fill")
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Image(systemName: "mic.fill")
            }
        }
    }
}
