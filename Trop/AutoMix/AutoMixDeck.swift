//
//  AutoMixDeck.swift
//  Trop
//
//  Un segundo mpv ("deck") para mezclar como lo hace LastWave: mientras suena la cancion actual, otro reproductor carga la
//  siguiente en su punto de entrada, en pausa y con el volumen a cero. En el solape suenan los dos, cada uno su propio
//  archivo, con volumenes de potencia constante; a mitad de la mezcla el que entra pasa a ser el reproductor principal y
//  el que sale se atenua hasta el final y se destruye. Asi la entrante nunca cambia de archivo ni de reproductor: no hay
//  empalme, ni audio duplicado, y casi nada de procesado.
//
//  Esta clase solo envuelve un mpv suelto (sin hilo de eventos: el estado se lee consultando propiedades).
//

import Foundation
import Libmpv

final class AutoMixDeck: @unchecked Sendable {
    /// Lo que se lee del mpv para saber si ya esta listo.
    struct Status {
        var timePos: Double?
        var duration: Double?
        /// Segundos de audio ya descargados por delante de la posicion.
        var cacheAhead: Double?
        /// mpv no tiene nada cargado (aun no ha empezado, o la carga fallo).
        var idle: Bool
    }

    let videoId: String
    let isLocal: Bool
    private let queue = DispatchQueue(label: "com.sonar.automix.deck")
    private var handle: OpaquePointer?

    private init(videoId: String, isLocal: Bool, handle: OpaquePointer?) {
        self.videoId = videoId
        self.isLocal = isLocal
        self.handle = handle
    }

    /// Un deck que ya existia (el mpv principal que sale): se sigue controlando su volumen hasta destruirlo.
    static func adopting(_ handle: OpaquePointer, videoId: String) -> AutoMixDeck {
        AutoMixDeck(videoId: videoId, isLocal: true, handle: handle)
    }

    /// Destruye un mpv sin esperar (puede tardar).
    static func discard(_ handle: OpaquePointer) {
        DispatchQueue.global(qos: .utility).async { mpv_destroy(handle) }
    }

    /// Crea un mpv nuevo que carga `url` en `start`, en pausa y sin sonido.
    static func create(videoId: String, url: String, isLocal: Bool, start: Double, filterChain: String) async -> AutoMixDeck? {
        await withCheckedContinuation { (continuation: CheckedContinuation<AutoMixDeck?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let handle = PlayerController.makeDeckHandle() else {
                    continuation.resume(returning: nil)
                    return
                }
                var silent = 0.0
                mpv_set_property(handle, "volume", MPV_FORMAT_DOUBLE, &silent)
                mpv_set_property_string(handle, "af", filterChain)
                mpv_set_property_string(handle, "pause", "yes")
                let command = ["loadfile", url, "replace", "-1", "start=" + String(format: "%.3f", start)]
                let result = command.withUnsafeCArg { mpv_command(handle, $0) }
                guard result >= 0 else {
                    mpv_destroy(handle)
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: AutoMixDeck(videoId: videoId, isLocal: isLocal, handle: handle))
            }
        }
    }

    // MARK: - Estado

    func status() async -> Status {
        await withCheckedContinuation { (continuation: CheckedContinuation<Status, Never>) in
            queue.async {
                guard let handle = self.handle else {
                    continuation.resume(returning: Status(timePos: nil, duration: nil, cacheAhead: nil, idle: true))
                    return
                }
                func double(_ name: String) -> Double? {
                    var value = 0.0
                    return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
                }
                var idle: Int32 = 0
                mpv_get_property(handle, "idle-active", MPV_FORMAT_FLAG, &idle)
                continuation.resume(returning: Status(
                    timePos: double("time-pos"),
                    duration: double("duration"),
                    cacheAhead: double("demuxer-cache-duration"),
                    idle: idle != 0
                ))
            }
        }
    }

    // MARK: - Control

    /// Valor de la propiedad `volume` de mpv (0...100; ojo: mpv aplica su cubo, quien llama ya lo tiene en cuenta).
    func setVolume(_ value: Double) {
        queue.async {
            guard let handle = self.handle else { return }
            var volume = value
            mpv_set_property(handle, "volume", MPV_FORMAT_DOUBLE, &volume)
        }
    }

    func setPaused(_ paused: Bool) {
        queue.async {
            guard let handle = self.handle else { return }
            var flag: Int32 = paused ? 1 : 0
            mpv_set_property(handle, "pause", MPV_FORMAT_FLAG, &flag)
        }
    }

    /// Entrega el mpv (para que pase a ser el principal); este deck deja de controlarlo.
    func releaseHandle() -> OpaquePointer? {
        queue.sync {
            let released = handle
            handle = nil
            return released
        }
    }

    func destroy() {
        queue.async {
            guard let handle = self.handle else { return }
            self.handle = nil
            Self.discard(handle)
        }
    }
}
