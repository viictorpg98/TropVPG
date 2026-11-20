//
//  SonarVoiceWidget.swift
//  SonarWidget
//
//  La Live Activity "Escuchando…" de la busqueda por voz (pantalla de bloqueo y Dynamic Island). Apple exige tenerla mientras se graba con un
//  `AudioRecordingIntent`. El boton de voz esta en el widget de botones (SonarWidget.swift) y su accion en Shared/WidgetIntents.swift
//  (`WidgetVoiceListenIntent`); la ejecuta la app. Dura lo que dura la escucha.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct SonarVoiceActivityWidget: Widget {
    private var spanish: Bool {
        Locale.preferredLanguages.first?.hasPrefix("es") ?? false
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceActivityAttributes.self) { _ in
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color(red: 0.36, green: 0.80, blue: 1.00))
                Text(spanish ? "Sonar: escuchando…" : "Sonar: listening…")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(14)
            .activityBackgroundTint(Color.black)
        } dynamicIsland: { _ in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text(spanish ? "Escuchando…" : "Listening…")
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
