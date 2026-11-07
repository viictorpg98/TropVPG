//
//  PlayerDiagnostics.swift
//  Trop
//

import AVFoundation
import Libmpv

extension PlayerController {
    /// Estado resumido del reproductor y de la sesion de audio, para el informe de Sonar.
    func diagnosticSnapshot() -> String {
        let player = withMpv { mpv -> String in
            func flag(_ name: String) -> String {
                var value = Int32(0)
                guard mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &value) >= 0 else { return "?" }
                return value != 0 ? "si" : "no"
            }
            var position = Double(0)
            let positionText = mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &position) >= 0
                ? String(format: "%.1f", position) : "-"
            return "pos \(positionText) s, pausa \(flag("pause")), parado \(flag("core-idle")), "
                + "esperando red \(flag("paused-for-cache"))"
        } ?? "mpv no listo"

        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        return "\(player); salida \(outputs.isEmpty ? "ninguna" : outputs), "
            + "otra app con audio \(session.isOtherAudioPlaying ? "si" : "no")"
    }

    /// `true` cuando el audio esta avanzando de verdad (no solo ordenado).
    var isAudioAdvancing: Bool {
        currentTime > 0.3
    }
}
