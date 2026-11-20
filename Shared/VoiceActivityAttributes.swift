//
//  VoiceActivityAttributes.swift
//  Trop
//
//  Los datos de la Live Activity "Escuchando…" de la busqueda por voz. Se compila en la app (que la inicia) y en la extension del widget
//  (que la dibuja). Apple exige que una accion que graba audio (`AudioRecordingIntent`) tenga una Live Activity mientras graba: si no la
//  hay, la grabacion se para. Y un `LiveActivityIntent` es lo que permite iniciarla sin abrir la app (la app arranca en segundo plano).
//

import ActivityKit
import Foundation

struct VoiceActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
    }

    var startedAt: Date
}
