//
//  SonarControls.swift
//  SonarWidget
//
//  Controles de Sonar (iOS 18+): botones para el Centro de Control, las dos esquinas de abajo de la pantalla de bloqueo y el BOTON DE ACCION del
//  iPhone (Ajustes > Boton de accion > Controles). Cada uno ejecuta la misma accion que su boton del widget (Shared/WidgetIntents.swift) en la
//  app, sin abrirla. Voz es el mas util en el coche: con una pulsacion, sin mirar, y por voz se hace casi todo ("mezcla", "activa el DJ"...).
//

import AppIntents
import Foundation
import SwiftUI
import WidgetKit

private var controlsInSpanish: Bool {
    Locale.preferredLanguages.first?.hasPrefix("es") ?? false
}

struct SonarVoiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "SonarVoiceControl") {
            ControlWidgetButton(action: WidgetVoiceIntent()) {
                Label(controlsInSpanish ? "Voz" : "Voice", systemImage: "mic.fill")
            }
        }
        .displayName("Sonar · Voz")
        .description("Pregunta qué quieres escuchar y lo pone.")
    }
}

struct SonarForYouControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "SonarForYouControl") {
            ControlWidgetButton(action: WidgetMixIntent()) {
                Label(controlsInSpanish ? "Para ti" : "For you", systemImage: "waveform")
            }
        }
        .displayName("Sonar · Para ti")
        .description("Pone tu mezcla Para ti.")
    }
}

struct SonarMixControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "SonarMixControl") {
            ControlWidgetButton(action: WidgetMixNowIntent()) {
                Label(controlsInSpanish ? "Mezclar" : "Mix now", systemImage: "arrow.triangle.merge")
            }
        }
        .displayName("Sonar · Mezclar")
        .description("Pasa a la siguiente canción con AutoMix.")
    }
}

struct SonarDJControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "SonarDJControl") {
            ControlWidgetButton(action: WidgetDJIntent()) {
                Label("DJ", systemImage: "power")
            }
        }
        .displayName("Sonar · DJ")
        .description("Enciende o apaga el DJ.")
    }
}

/// Los controles, agrupados.
struct SonarControlsBundle: WidgetBundle {
    var body: some Widget {
        SonarVoiceControl()
        SonarForYouControl()
        SonarMixControl()
        SonarDJControl()
    }
}
