//
//  PlayerController.swift
//  Trop
//
//  Created by 686udjie on 28/06/2026.
//

import Foundation
import Libmpv
import MediaPlayer
import Combine
import AVFoundation
import UIKit
import Metal

// MARK: - DetectedCrop (parsed from mpv log)

struct DetectedCrop {
    let width: Int
    let height: Int
    let x: Int
    let y: Int
}

// MARK: - PlayerController

@MainActor
final class PlayerController {
    static let shared = PlayerController()

    nonisolated(unsafe) private var _mpv: OpaquePointer?
    /// Serial queue for all mpv property read/write calls
    let mpvAccessQueue = DispatchQueue(label: "com.686udjie.PlayerController.mpvAccess")

    nonisolated(unsafe) private var eventLoopThread: Thread?

    nonisolated(unsafe) var isRunning = false
    nonisolated(unsafe) var currentVideoId: String?
    nonisolated(unsafe) var pendingVideoId: String?
    /// AutoMix (mezcla encadenada dentro de mpv): 0 = nada; 1 = la saliente suena y mpv ya tiene detras el archivo de la
    /// mezcla y la entrante; 2 = suena el archivo de la mezcla; 3 = mpv esta cargando la entrante.
    nonisolated(unsafe) var gaplessStage = 0
    nonisolated(unsafe) var gaplessIncomingId: String?
    nonisolated(unsafe) var gaplessMixLoaded = false
    private var lastDetectedCrop: String?
    private var detectedCropRepeatCount = 0
    var currentLoudnessDb: Double?
    var pendingURL: String?
    nonisolated(unsafe) var desiredPlaying = false
    private var wasPlayingBeforeInterruption = false

    /// Video-mode state. Reads happen on the event loop thread from event handlers;
    /// writes happen on the main actor from `setVideoMode` / `loadFileReplacing`.
    /// Cross-thread access is serialized by the event loop reading these values
    /// synchronously before dispatching work to the main actor.
    nonisolated(unsafe) var videoModeSwitchInFlight = false
    nonisolated(unsafe) var loadedMuxedURL: String?
    nonisolated(unsafe) var loadedVideoOnlyURL: String?
    nonisolated(unsafe) var voWarmedVideoId: String?
    nonisolated(unsafe) var muxedActive = false
    nonisolated(unsafe) var muxedVideoId: String?
    nonisolated(unsafe) var hasPresentedVideo = false
    nonisolated(unsafe) var voInitDrawableSize: CGSize = .zero
    private var lastGeometryRefreshAt = Date.distantPast
    nonisolated(unsafe) var videoFlipAwaitingRestart = false
    private var videoAttachTask: Task<Bool, Never>?
    private var videoAttachTaskId: String?

    var videoLayer: CAMetalLayer = {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.contentsScale = 1
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = UIColor.clear.cgColor
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 180)
        layer.frame = bounds
        layer.drawableSize = CGSize(
            width: bounds.width * layer.contentsScale,
            height: bounds.height * layer.contentsScale
        )
        return layer
    }()

    let playState = CurrentValueSubject<State, Never>(.stopped)
    var pendingResumeAt: TimeInterval = 0
    /// Multiplicador del volumen de mpv (1 = normal): AutoMix lo baja y sube durante las mezclas.
    var volumeScale: Double = 1
    /// AutoMix: mete en la cadena de audio un filtro paso bajo con etiqueta `dj` (abierto) que luego se cierra
    /// con `setDJLowpass`.
    var djFilterActive = false
    var nowPlayingInfo = [String: Any]()
    private var pendingSeek: (target: TimeInterval, deadline: Date)?
    private var remoteStateCancellable: AnyCancellable?

    /// AutoMix: mientras suena el tramo preparado de la saliente (mpv callado y en pausa), la posicion que ve el
    /// resto de la app (barra de progreso, pantalla de bloqueo) es la de ese tramo.
    var positionOverride: TimeInterval?
    /// AutoMix: mientras suena el archivo de la mezcla, la duracion que se ve es la de la cancion saliente.
    var durationOverride: TimeInterval?

    /// Posicion que da mpv, sin los cambios de AutoMix (durante la mezcla es la del archivo de la mezcla).
    func rawTimePos() -> TimeInterval {
        withMpv { mpv in
            var val = Double(0)
            mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &val)
            return val
        } ?? 0
    }

    var currentTime: TimeInterval {
        if let positionOverride { return positionOverride }
        return withMpv { mpv in
            var val = Double(0)
            mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &val)
            return val
        } ?? 0
    }

    var duration: TimeInterval {
        if let durationOverride { return durationOverride }
        return withMpv { mpv in
            var val = Double(0)
            mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &val)
            return val
        } ?? 0
    }

    enum State: Equatable { case stopped, playing, paused }

    private init() {
        assertAudioSession()
        setupRemoteCommands()
        observeInterruptions()
        observeAudioSessionReset()
        startMpv()
    }

    deinit {
        isRunning = false
        if let mpv = _mpv { mpv_wakeup(mpv) }
    }

    nonisolated func withMpv<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) -> T) -> T? {
        var result: T?
        mpvAccessQueue.sync {
            guard let handle = _mpv else { return }
            result = body(handle)
        }
        return result
    }

    // MARK: - Layer helper

    func clearVideoLayer() {
        guard let device = videoLayer.device,
              let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer(),
              let drawable = videoLayer.nextDrawable() else { return }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    @MainActor
    func applyPendingResumeIfNeeded() {
        guard pendingResumeAt > 0 else { return }
        let target = pendingResumeAt
        pendingResumeAt = 0
        seek(to: target)
    }
}

// MARK: - Playback

extension PlayerController {
    @MainActor
    func play(
        url: String,
        title: String? = nil,
        artist: String? = nil,
        videoId: String? = nil,
        duration: TimeInterval? = nil,
        artists: [YTArtist] = [],
        loudnessDb: Double? = nil,
        thumbnailUrl: String? = nil,
        startAt: TimeInterval = 0
    ) async {
        currentLoudnessDb = loudnessDb
        guard let url = URL(string: url) else {
            Log.player.error("Invalid URL: \(url)")
            return
        }

        if let videoId, let title, videoId != NowPlaying.shared.videoId {
            NowPlaying.shared.update(title: title, artist: artist, videoId: videoId, artists: artists, thumbnailUrl: thumbnailUrl)
        }

        let skipStart = await SponsorBlockIntegration.shared.preloadedStartOffset(for: videoId)
        guard NowPlaying.shared.videoId == videoId else {
            return
        }

        let prevVideoId = currentVideoId
        let isNewSong = prevVideoId != nil && videoId != prevVideoId

        desiredPlaying = true
        assertAudioSession()
        loadedMuxedURL = nil
        loadedVideoOnlyURL = nil
        voWarmedVideoId = nil
        muxedActive = false
        muxedVideoId = nil
        pendingResumeAt = 0
        pendingSeek = nil
        videoModeSwitchInFlight = false
        videoFlipAwaitingRestart = false
        NowPlaying.shared.isVideoMode = false
        NowPlaying.shared.isVideoReady = false
        if hasPresentedVideo { clearVideoLayer() }
        let isReady = withMpv { _ in true } ?? false
        guard isReady else {
            Log.player.info("mpv not ready yet, parking URL for deferred load")
            pendingURL = url.absoluteString
            pendingVideoId = videoId
            return
        }

        applyPlaybackSettings()
        setVideoCrop(.none)

        pendingVideoId = videoId
        let loadStart: Double = startAt > 0 ? startAt : (skipStart > 0 ? Double(Int(skipStart.rounded(.up))) : 0)
        let loadArguments = loadStart > 0
            ? ["loadfile", url.absoluteString, "replace", "-1", "start=\(String(format: "%.3f", loadStart))"]
            : ["loadfile", url.absoluteString, "replace"]
        Log.player.info(
            "TRANSITION play videoId=\(videoId ?? "nil") isNewSong=\(isNewSong) muxedActive=\(muxedActive) "
                + "url=\(url.absoluteString.prefix(80))"
        )
        // Una carga normal borra cualquier mezcla encadenada que hubiera preparada.
        resetGaplessMix()
        let cmdResult = withMpv { mpv -> Int32 in
            mpv_set_property_string(mpv, "pause", "no")
            mpv_set_property_string(mpv, "end", "none")
            return loadArguments.withUnsafeCArg { mpv_command(mpv, $0) }
        } ?? -1
        if cmdResult != 0 {
            Log.player.error("mpv_command loadfile failed result=\(cmdResult)")
            pendingVideoId = nil
            return
        }
        if isNewSong {
            await PlaybackStateService.shared.stopTracking()
        }
        if let videoId { await PlaybackStateService.shared.startTracking(videoId: videoId) }
        playState.send(.playing)
        NowPlaying.shared.isPlaying = true
        NowPlaying.shared.currentTime = max(0, startAt)
        NowPlaying.shared.duration = max(0, duration ?? 0)
        setNowPlayingMetadata()
    }

    func seek(to time: TimeInterval) {
        // Con una mezcla encadenada preparada o sonando, la posicion que se pide es de la saliente: AutoMix la deshace
        // primero (y, si ya sonaba el archivo de la mezcla, vuelve a cargar la saliente en ese punto).
        if gaplessStage == 1 || gaplessStage == 2, AutoMixEngine.shared.userSeek(to: time) { return }
        pendingSeek = (time, Date().addingTimeInterval(1.5))
        NowPlaying.shared.currentTime = time
        withMpv { mpv in
            var val = time
            let result = mpv_set_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &val)
            if result < 0 { Log.player.error("seek failed: mpv error \(result)") }
        }
    }

    func setPaused(_ paused: Bool) {
        desiredPlaying = !paused
        let currentlyPaused = playState.value != .playing
        guard currentlyPaused != paused else {
            updateNowPlayingProgress()
            return
        }
        withMpv { mpv in
            var flag: Int32 = paused ? 1 : 0
            mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
        }
        playState.send(paused ? .paused : .playing)
        NowPlaying.shared.isPlaying = !paused
        if !paused { assertAudioSession() }
        updateNowPlayingProgress()
    }

    func togglePlayPause() {
        setPaused(playState.value == .playing)
    }

    func applyPlayerVolume() {
        let vol = SettingsStore.shared.playerVolume * volumeScale
        withMpv { mpv in
            var val = Double(vol * 100)
            mpv_set_property(mpv, "volume", MPV_FORMAT_DOUBLE, &val)
        }
    }

    /// Pausa o reanuda mpv sin tocar el estado de reproduccion de la app (AutoMix lo calla mientras suenan sus tramos).
    func setRawPause(_ paused: Bool) {
        withMpv { mpv in
            var flag: Int32 = paused ? 1 : 0
            mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
        }
    }

    /// Velocidad de reproduccion de mpv (sin cambiar el tono): AutoMix la usa para igualar tempos.
    func setPlaybackSpeed(_ speed: Double) {
        withMpv { mpv in
            var val = speed
            mpv_set_property(mpv, "speed", MPV_FORMAT_DOUBLE, &val)
        }
    }

    /// Filtro paso bajo de AutoMix. El FFmpeg de MPVKit solo incluye una lista cerrada de filtros (hay `firequalizer`
    /// y `volume`, pero no `lowpass`), asi que se hace con un ecualizador FIR cuya curva se cambia en caliente.
    private static let djFilterSpec = "@dj:firequalizer=gain_entry=\"entry(0,0);entry(22000,0)\":delay=0.03:accuracy=10"

    /// Cambia la frecuencia de corte (Hz) del filtro `dj`: sin cambios por encima de ~0,8 de la frecuencia y una
    /// bajada de hasta 42 dB mas arriba. Devuelve el codigo de mpv (<0 = fallo).
    @discardableResult
    func setDJLowpass(_ hz: Double) -> Int32 {
        let cutoff = min(max(hz, 100), 20_000)
        // Casi abierto del todo: sin atenuacion. Cerrandose: hasta 42 dB.
        let depth = 42 * min(1, max(0, (20_000 - cutoff) / 12_000))
        let upper = min(cutoff * 2.5, 21_000)
        let flat = min(cutoff * 0.8, upper * 0.6)
        let curve = String(
            format: "entry(0,0);entry(%.0f,0);entry(%.0f,-%.1f);entry(22000,-%.1f)",
            flat, upper, depth, depth
        )
        let command = ["af-command", "dj", "gain_entry", curve]
        return withMpv { mpv in
            command.withUnsafeCArg { mpv_command(mpv, $0) }
        } ?? -1
    }

    func applyPlaybackSettings() {
        let settings = SettingsStore.shared
        let loudness = currentLoudnessDb
        let eqEnabled = settings.equalizerEnabled
        let eqGains = settings.equalizerGains
        let gapless = settings.gaplessPlayback
        let norm = settings.audioNormalization

        let djActive = djFilterActive
        let baseFilters: [String] = {
            var filters: [String] = []
            if eqEnabled {
                let entries = zip(equalizerFrequencies, eqGains)
                    .map { "entry(\(Self.fmt($0.0)),\(Self.fmt($0.1)))" }
                    .joined(separator: ";")
                if !entries.isEmpty {
                    filters.append("firequalizer=gain_entry=\"\(entries)\"")
                }
            }
            if norm, let loudness, loudness.isFinite {
                let gain = max(-12, min(12, -14 - loudness))
                filters.append("volume=\(Self.fmt(gain))dB")
            }
            return filters
        }()
        let baseChain = baseFilters.joined(separator: ",")
        let chain = (baseFilters + (djActive ? [Self.djFilterSpec] : [])).joined(separator: ",")

        let fellBack: Bool? = withMpv { mpv in
            mpv_set_property_string(mpv, "gapless-audio", gapless ? "yes" : "no")
            var result = mpv_set_property_string(mpv, "af", chain.isEmpty ? "" : chain)
            var droppedDJ = false
            if result < 0, djActive {
                // Sin el filtro de DJ, para no perder el ecualizador ni la normalizacion.
                droppedDJ = true
                result = mpv_set_property_string(mpv, "af", baseChain.isEmpty ? "" : baseChain)
            }
            if result < 0 { Log.player.error("Failed to set af chain '\(chain)': mpv error \(result)") }
            return droppedDJ
        }
        if fellBack == true {
            djFilterActive = false
            PlaybackReport.record("automix: mpv rechazo el filtro de DJ, la mezcla sigue sin el")
        }
        applyPlayerVolume()
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

// MARK: - mpv lifecycle & event loop

extension PlayerController {
    fileprivate func startMpv() {
        mpvAccessQueue.async { [weak self] in
            guard let self else { return }
            guard let mpv = mpv_create() else {
                Log.player.error("mpv_create failed")
                return
            }

            _ = setenv("MVK_CONFIG_LOG_LEVEL", "1", 1)

            mpv_request_log_messages(mpv, "warn")
            Self.applyMpvStartupOptions(mpv)

            Log.player.info("mpv initializing...")
            let initResult = mpv_initialize(mpv)
            guard initResult >= 0 else {
                let errStr = String(cString: mpv_error_string(initResult))
                Log.player.error("mpv_initialize failed: \(initResult) (\(errStr))")
                mpv_destroy(mpv)
                return
            }
            Log.player.info("mpv initialized successfully")

            Self.applyPostInitProperties(mpv)
            Self.applyObservedProperties(mpv)

            self._mpv = mpv
            Log.player.info("mpv handle published — event loop starting")

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyPlaybackSettings()
                if let url = self.pendingURL {
                    self.pendingURL = nil
                    Log.player.info("mpv ready: loading deferred URL \(url.prefix(80))")
                    _ = self.withMpv { mpv in
                        mpv_set_property_string(mpv, "pause", "no")
                        return ["loadfile", url, "replace"].withUnsafeCArg { mpv_command(mpv, $0) }
                    }
                }
            }

            let thread = Thread { [weak self] in
                guard let self else { return }
                self.isRunning = true
                self.eventLoop(mpv)
            }
            self.eventLoopThread = thread
            thread.name = "com.686udjie.PlayerController.eventLoop"
            thread.start()
        }
    }

    nonisolated private static func applyMpvStartupOptions(_ mpv: OpaquePointer) {
        mpv_set_option_string(mpv, "vo", "null")
        mpv_set_option_string(mpv, "vid", "no")
        mpv_set_option_string(mpv, "force-window", "no")
        mpv_set_option_string(mpv, "msg-level", "all=error")

        #if targetEnvironment(simulator)
        mpv_set_option_string(mpv, "hwdec", "no")
        mpv_set_option_string(mpv, "audio-exclusive", "no")
        #else
        mpv_set_option_string(mpv, "hwdec", "videotoolbox")
        mpv_set_option_string(mpv, "audio-exclusive", "yes")
        #endif

        mpv_set_option_string(mpv, "keep-open", "no")
        mpv_set_option_string(mpv, "cache", "yes")
        mpv_set_option_string(mpv, "cache-secs", "120")
        mpv_set_option_string(mpv, "demuxer-max-bytes", "200M")
        mpv_set_option_string(mpv, "gapless-audio", "yes")
    }

    nonisolated private static func applyPostInitProperties(_ mpv: OpaquePointer) {
        if let caPath = Bundle.main.path(forResource: "cacert", ofType: "pem") {
            mpv_set_property_string(mpv, "tls-ca-file", caPath)
            Log.player.info("mpv tls-ca-file set: \(caPath)")
        } else {
            Log.player.warning("mpv cacert.pem not found in main bundle")
        }
        let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15" +
            " (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        mpv_set_property_string(mpv, "user-agent", userAgent)
        mpv_set_property_string(mpv, "video-unscaled", "no")
        mpv_set_property_string(mpv, "keepaspect", "no")
    }

    nonisolated private static func applyObservedProperties(_ mpv: OpaquePointer) {
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 1, "video-params/w", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 2, "video-out-params", MPV_FORMAT_NODE)
    }

    nonisolated fileprivate func eventLoop(_ mpv: OpaquePointer) {
        while isRunning {
            guard let event = mpv_wait_event(mpv, 0.2) else { continue }
            switch event.pointee.event_id {
            case MPV_EVENT_NONE:
                break
            case MPV_EVENT_LOG_MESSAGE:
                handleLogMessage(event)
            case MPV_EVENT_FILE_LOADED:
                handleFileLoaded(mpv)
            case MPV_EVENT_PROPERTY_CHANGE:
                handlePropertyChange(event)
            case MPV_EVENT_START_FILE:
                Log.player.debug("TRANSITION START_FILE")
            case MPV_EVENT_END_FILE:
                handleEndFile(event)
            case MPV_EVENT_VIDEO_RECONFIG:
                handleVideoReconfig()
            case MPV_EVENT_PLAYBACK_RESTART:
                handlePlaybackRestart()
            default:
                break
            }
        }
        mpvAccessQueue.sync { self._mpv = nil }
        mpv_destroy(mpv)
    }

    nonisolated private func handleLogMessage(_ event: UnsafeMutablePointer<mpv_event>) {
        if let prop = event.pointee.data?.load(as: mpv_event_log_message.self),
           let textPtr = prop.text {
            let text = String(cString: textPtr)
            let prefix = prop.prefix.map { String(cString: $0) } ?? ""
            let level = prop.level.map { String(cString: $0) } ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if trimmed.range(of: "primitive restart", options: .caseInsensitive) != nil { return }
                Log.mpv.debug("[\(prefix)] [\(level)] \(trimmed)")
                PlaybackReport.record("mpv [\(prefix)] \(trimmed.prefix(160))")
                if let crop = detectedCrop(from: trimmed) {
                    Task { @MainActor in self.applyDetectedCrop(crop) }
                }
            }
        }
    }

    nonisolated private func handleFileLoaded(_ mpv: OpaquePointer) {
        // AutoMix: el archivo de la mezcla se carga sin cambiar la cancion que se ve; al cargarse la entrante todo vuelve
        // a ser normal.
        if gaplessStage == 2, !gaplessMixLoaded {
            gaplessMixLoaded = true
            PlaybackReport.record("automix: archivo de la mezcla cargado")
            return
        }
        var cameFromMix = false
        if gaplessStage == 3 {
            cameFromMix = true
            gaplessStage = 0
            mpv_set_property_string(mpv, "prefetch-playlist", "no")
        }
        var pauseFlag = Int32(1)
        mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &pauseFlag)
        if pauseFlag != 0, desiredPlaying {
            var unpause = Int32(0)
            mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &unpause)
            mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &pauseFlag)
        }
        let actuallyPlaying = pauseFlag == 0
        let pendingVideoId = self.pendingVideoId
        // Tras una mezcla de AutoMix la entrante llega con el audio ya sonando: no se vuelve a tocar la sesion de audio.
        let arrivedByMix = cameFromMix
        Task { @MainActor [weak self] in
            guard let self else { return }
            Log.player.debug("TRANSITION FILE_LOADED videoId=\(pendingVideoId ?? "nil") playing=\(actuallyPlaying)")
            PlaybackReport.record("reproductor: archivo cargado \(pendingVideoId ?? "?") (suena: \(actuallyPlaying))")
            self.playState.send(actuallyPlaying ? .playing : .paused)
            NowPlaying.shared.isPlaying = actuallyPlaying
            self.currentVideoId = pendingVideoId
            self.pendingVideoId = nil
            if !arrivedByMix { self.assertAudioSession() }
            self.setNowPlayingMetadata()
            self.applyPendingResumeIfNeeded()
            let checkId = pendingVideoId
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.currentVideoId == checkId else { return }
                self.updateNowPlayingArtwork()
                self.updateNowPlayingProgress()
            }
        }
    }

    nonisolated private func handlePropertyChange(_ event: UnsafeMutablePointer<mpv_event>) {
        guard let prop = event.pointee.data?.load(as: mpv_event_property.self),
              let namePtr = prop.name else { return }
        let name = String(cString: namePtr)

        if name == "duration", prop.format == MPV_FORMAT_DOUBLE {
            let newDur: Double = prop.data?.load(as: Double.self) ?? 0
            // Durante el archivo de la mezcla la duracion que se ve es la de la saliente.
            if newDur > 0, gaplessStage != 2 {
                Task { @MainActor in
                    NowPlaying.shared.duration = newDur
                    self.setNowPlayingMetadata()
                }
            }
        } else if name == "video-params/w", prop.format == MPV_FORMAT_INT64 {
            let width: Int64 = prop.data?.load(as: Int64.self) ?? 0
            if width > 0 {
                Task { @MainActor in
                    let ok = self.muxedActive && NowPlaying.shared.videoId == self.muxedVideoId
                    guard ok else { return }
                    if self.hasPresentedVideo { self.clearVideoLayer() }
                    // Only the flip owns the mount; background prerender must
                    // never pop the UI (ready is still recorded below).
                    if self.videoModeSwitchInFlight { NowPlaying.shared.isVideoMode = true }
                    self.hasPresentedVideo = true
                }
            }
        } else if name == "video-out-params", prop.format == MPV_FORMAT_NODE {
            Task { @MainActor in
                let ok = self.muxedActive && NowPlaying.shared.videoId == self.muxedVideoId
                guard ok else { return }
                if self.videoModeSwitchInFlight { NowPlaying.shared.isVideoMode = true }
                NowPlaying.shared.isVideoReady = true
                self.hasPresentedVideo = true
            }
        }
    }

    nonisolated private func handleVideoReconfig() {
        Task { @MainActor in
            let ok = self.muxedActive && NowPlaying.shared.videoId == self.muxedVideoId
            guard ok else { return }
            if self.videoModeSwitchInFlight { NowPlaying.shared.isVideoMode = true }
            NowPlaying.shared.isVideoReady = true
            self.hasPresentedVideo = true
        }
    }

    nonisolated private func handlePlaybackRestart() {
        let flipPending = self.videoFlipAwaitingRestart
        Task { @MainActor in
            guard flipPending else { return }
            let ok = self.muxedActive && NowPlaying.shared.videoId == self.muxedVideoId
            self.videoFlipAwaitingRestart = false
            guard ok else { return }
            if self.videoModeSwitchInFlight { NowPlaying.shared.isVideoMode = true }
            NowPlaying.shared.isVideoReady = true
            self.hasPresentedVideo = true
        }
    }

    nonisolated private func handleEndFile(_ event: UnsafeMutablePointer<mpv_event>) {
        guard let data = event.pointee.data else { return }
        let endFile = data.load(as: mpv_event_end_file.self)
        let reason = endFile.reason
        let isEof = reason == MPV_END_FILE_REASON_EOF
        let isError = reason == MPV_END_FILE_REASON_ERROR
        if isError {
            PlaybackReport.record("reproductor: FIN CON ERROR (\(String(cString: mpv_error_string(endFile.error))))")
        }
        // AutoMix: la saliente llego a su punto de corte (EOF) y mpv sigue sin pausa con el archivo de la mezcla; cuando este
        // acaba, sigue con la entrante. En ninguno de los dos casos la app debe pensar que acabo la cancion.
        if isEof, gaplessStage == 1 {
            gaplessStage = 2
            _ = withMpv { mpv in mpv_set_property_string(mpv, "end", "none") }
            PlaybackReport.record("automix: mpv paso de la saliente al archivo de la mezcla")
            return
        }
        if isEof, gaplessStage == 2 {
            gaplessStage = 3
            pendingVideoId = gaplessIncomingId
            gaplessIncomingId = nil
            gaplessMixLoaded = false
            Task { @MainActor in AutoMixEngine.shared.gaplessReachedIncoming() }
            return
        }
        let stoppedVideoId = self.currentVideoId
        Task { @MainActor [weak self] in
            guard let self else { return }
            let videoId = stoppedVideoId
            Log.player.debug(
                "TRANSITION END_FILE reason=\(reason.rawValue) isEof=\(isEof) isError=\(isError) stoppedVideoId=\(videoId ?? "nil")"
            )
            if isError, videoId != nil {
                Task { await PlaybackStateService.shared.stopTracking() }
            }
            if isEof {
                self.playState.send(.stopped)
                NowPlaying.shared.stopped(videoId: videoId, isEof: true)
            } else if isError {
                self.currentVideoId = nil
                self.playState.send(.stopped)
                NowPlaying.shared.stopped(videoId: videoId, isEof: false)
            } else {
                Log.player.debug("END_FILE non-EOF ignored for auto-advance")
            }
        }
    }
}

// MARK: - Video mode

extension PlayerController {
    func setVideoMode() {
        // No real video (e.g. art-track): stay in the big player, do nothing.
        guard NowPlaying.shared.hasVideo else { return }
        guard let videoId = NowPlaying.shared.videoId else { return }
        if muxedActive {
            NowPlaying.shared.isVideoMode = true
            NowPlaying.shared.isVideoReady = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard NowPlaying.shared.videoId == videoId,
                      NowPlaying.shared.isVideoMode else { return }
                guard self.videoLayerDrifted() else { return }
                NowPlaying.shared.isVideoReady = false
                self.setVideoTrack()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard NowPlaying.shared.videoId == videoId,
                      NowPlaying.shared.isVideoMode,
                      !NowPlaying.shared.isVideoReady else { return }
                NowPlaying.shared.isVideoReady = true
            }
            return
        }
        guard !videoModeSwitchInFlight else { return }
        videoModeSwitchInFlight = true
        NowPlaying.shared.isVideoMode = true
        NowPlaying.shared.isVideoReady = false
        Task {
            defer { videoModeSwitchInFlight = false }
            if loadedVideoOnlyURL != nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard NowPlaying.shared.videoId == videoId else { return }
            }
            do {
                guard await ensureVideoAttached(videoId: videoId) else {
                    throw StreamError.noSuitableFormat
                }
                guard NowPlaying.shared.videoId == videoId, NowPlaying.shared.isVideoMode else { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard NowPlaying.shared.videoId == videoId, NowPlaying.shared.isVideoMode else { return }
                Log.player.debug("TRANSITION video flipped videoId=\(videoId)")
                NowPlaying.shared.isVideoReady = true
                return
            } catch {
                Log.player.debug("video attach failed, falling back to EDL replace: \(error)")
            }
            do {
                videoFlipAwaitingRestart = false
                let resumeAt = currentTime
                let url: String
                if let loaded = loadedMuxedURL {
                    url = loaded
                } else {
                    url = try await PlaybackManager.shared.resolveMuxedURL(videoId: videoId)
                    guard NowPlaying.shared.videoId == videoId else { return }
                    loadedMuxedURL = url
                }
                guard NowPlaying.shared.videoId == videoId else { return }
                setVideoTrack()
                Log.player.debug("TRANSITION entering video mode videoId=\(videoId) url=\(url.prefix(80))")
                muxedVideoId = videoId
                pendingVideoId = videoId
                loadFileReplacing(url, startAt: resumeAt)
                muxedActive = true
            } catch {
                Log.player.error("setVideoMode failed: \(error)")
                NowPlaying.shared.isVideoMode = false
                NowPlaying.shared.isVideoReady = false
            }
        }
    }

    func ensureVideoAttached(videoId: String) async -> Bool {
        if muxedActive, muxedVideoId == videoId { return true }
        if let task = videoAttachTask, videoAttachTaskId == videoId {
            return await task.value
        }
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            return await self.attachVideoTrack(videoId: videoId)
        }
        videoAttachTask = task
        videoAttachTaskId = videoId
        let result = await task.value
        if videoAttachTaskId == videoId {
            videoAttachTask = nil
            videoAttachTaskId = nil
        }
        return result
    }

    private func attachVideoTrack(videoId: String) async -> Bool {
        do {
            // Already initialized at the right size by preload? Don't churn.
            if voWarmedVideoId != videoId || videoLayerDrifted() {
                setVideoTrack()
            }
            let videoURL: String
            if let preloaded = loadedVideoOnlyURL {
                videoURL = preloaded
            } else {
                videoURL = try await PlaybackManager.shared.resolveVideoOnlyURL(videoId: videoId)
                guard NowPlaying.shared.videoId == videoId else { return false }
                loadedVideoOnlyURL = videoURL
            }
            guard NowPlaying.shared.videoId == videoId else { return false }
            let addResult = withMpv { mpv in
                ["video-add", videoURL, "select"].withUnsafeCArg { mpv_command(mpv, $0) }
            } ?? -1
            guard addResult == 0 else { throw StreamError.noSuitableFormat }
            guard await waitForVideoTrack(videoId: videoId) else { throw StreamError.noSuitableFormat }
            guard NowPlaying.shared.videoId == videoId else { return false }
            muxedVideoId = videoId
            muxedActive = true
            voInitDrawableSize = videoLayer.drawableSize
            // video-add starts at 0 while audio is live — seek both to now.
            let syncAt = currentTime
            videoFlipAwaitingRestart = true
            let seekResult = withMpv { mpv in
                ["seek", String(syncAt), "absolute"].withUnsafeCArg { mpv_command(mpv, $0) }
            } ?? -1
            guard seekResult == 0 else {
                videoFlipAwaitingRestart = false
                throw StreamError.noSuitableFormat
            }
            _ = await waitForFlipRestart(videoId: videoId)
            guard NowPlaying.shared.videoId == videoId else { return false }
            videoFlipAwaitingRestart = false
            return true
        } catch {
            videoFlipAwaitingRestart = false
            Log.player.debug("video attach failed videoId=\(videoId): \(error)")
            return false
        }
    }

    private func waitForVideoTrack(videoId: String) async -> Bool {
        for _ in 0..<60 {
            guard NowPlaying.shared.videoId == videoId else { return false }
            let width: Int64 = withMpv { mpv in
                var w = Int64(0)
                mpv_get_property(mpv, "video-params/w", MPV_FORMAT_INT64, &w)
                return w
            } ?? 0
            if width > 0 { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func waitForFlipRestart(videoId: String) async -> Bool {
        for _ in 0..<50 {
            guard NowPlaying.shared.videoId == videoId else { return false }
            if !videoFlipAwaitingRestart { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func preloadVideoURL() {
        guard let videoId = NowPlaying.shared.videoId else { return }
        guard !isVideoPrerendered(videoId: videoId) else { return }
        Task {
            if loadedVideoOnlyURL == nil {
                do {
                    let url = try await PlaybackManager.shared.resolveVideoOnlyURL(videoId: videoId)
                    guard NowPlaying.shared.videoId == videoId, loadedVideoOnlyURL == nil else { return }
                    loadedVideoOnlyURL = url
                } catch {
                    Log.player.error("Video preload failed: \(error)")
                    return
                }
            }
        }
    }

    private func isVideoPrerendered(videoId: String) -> Bool {
        loadedVideoOnlyURL != nil && voWarmedVideoId == videoId
            && muxedActive && muxedVideoId == videoId
    }

    func handleVideoStreamFailure() {
        guard muxedActive || videoModeSwitchInFlight else { return }
        loadedMuxedURL = nil
        loadedVideoOnlyURL = nil
        voWarmedVideoId = nil
        muxedActive = false
        muxedVideoId = nil
        videoModeSwitchInFlight = false
        videoFlipAwaitingRestart = false
        NowPlaying.shared.isVideoMode = false
        NowPlaying.shared.isVideoReady = false
    }

    private func setVideoTrack() {
        lastDetectedCrop = nil
        detectedCropRepeatCount = 0
        if videoLayer.superlayer == nil {
            presizeVideoLayerForExpectedFrame()
        }
        voInitDrawableSize = videoLayer.drawableSize
        let wid: Int64 = unsafeBitCast(videoLayer, to: Int64.self)
        withMpv { mpv in
            mpv_set_property_string(mpv, "vo", "null")
            mpv_set_property_string(mpv, "vo", "gpu-next")
            mpv_set_property_string(mpv, "gpu-api", "vulkan")
            mpv_set_property_string(mpv, "gpu-context", "moltenvk")
            var widCopy = wid
            mpv_set_property(mpv, "wid", MPV_FORMAT_INT64, &widCopy)
            mpv_set_property_string(mpv, "vid", "auto")
        }
        setVideoCrop(.none)
    }

    private func presizeVideoLayerForExpectedFrame() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return }
        let width = window.bounds.width - 64
        guard width > 0 else { return }
        let height = width * 9 / 16
        let scale = window.screen.nativeScale > 0 ? window.screen.nativeScale : 3
        videoLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        videoLayer.contentsScale = scale
        videoLayer.drawableSize = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
    }

    func videoLayerDrifted() -> Bool {
        let baseline = voInitDrawableSize
        guard baseline.width > 0, baseline.height > 0 else { return false }
        let current = videoLayer.drawableSize
        return abs(current.width - baseline.width) > 2 || abs(current.height - baseline.height) > 2
    }

    func refreshVideoGeometryIfNeeded() {
        guard muxedActive || hasPresentedVideo else { return }
        guard videoLayerDrifted() else { return }
        guard Date().timeIntervalSince(lastGeometryRefreshAt) > 0.5 else { return }
        lastGeometryRefreshAt = Date()
        Log.player.debug("TRANSITION video VO restart for geometry")
        setVideoTrack()
    }

    nonisolated private func detectedCrop(from log: String) -> DetectedCrop? {
        guard let marker = log.range(of: "crop=") else { return nil }
        let values = log[marker.upperBound...]
            .split(whereSeparator: { $0 == Character(":") || $0 == Character(" ") || $0 == Character("\n") })
            .prefix(4)
            .compactMap { Int($0) }
        guard values.count == 4 else { return nil }
        return DetectedCrop(width: values[0], height: values[1], x: values[2], y: values[3])
    }

    private func applyDetectedCrop(_ crop: DetectedCrop) {
        guard crop.width > 0, crop.height > 0 else { return }
        let signature = "\(crop.width)x\(crop.height)+\(crop.x)+\(crop.y)"
        if lastDetectedCrop == signature {
            detectedCropRepeatCount += 1
        } else {
            lastDetectedCrop = signature
            detectedCropRepeatCount = 1
        }
        guard detectedCropRepeatCount >= 2 else { return }
        _ = withMpv { mpv in
            mpv_set_property_string(mpv, "video-crop", signature)
        }
    }

    enum VideoCropMode { case none, square }

    private struct VideoDims: Sendable {
        var width: Int64
        var height: Int64
        var hasVid: Bool
    }

    private func setVideoCrop(_ mode: VideoCropMode) {
        switch mode {
        case .none:
            _ = withMpv { mpv in
                mpv_set_property_string(mpv, "video-crop", "")
            }
        case .square:
            let dims: VideoDims = withMpv { mpv in
                var w = Int64(0), h = Int64(0)
                mpv_get_property(mpv, "video-params/w", MPV_FORMAT_INT64, &w)
                mpv_get_property(mpv, "video-params/h", MPV_FORMAT_INT64, &h)
                var vid: UnsafeMutablePointer<CChar>?
                defer { if let vid { mpv_free(vid) } }
                let hasVid = mpv_get_property(mpv, "vid", MPV_FORMAT_STRING, &vid) == 0
                    && vid.map { String(cString: $0) != "no" } ?? false
                return VideoDims(width: w, height: h, hasVid: hasVid)
            } ?? VideoDims(width: 0, height: 0, hasVid: false)
            if dims.width > 0, dims.height > 0 {
                let side = min(dims.width, dims.height)
                _ = withMpv { mpv in
                    mpv_set_property_string(mpv, "video-crop", "\(side)x\(side)")
                }
            } else if dims.hasVid {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    self.setVideoCrop(.square)
                }
            }
        }
    }

    private func loadFileReplacing(_ url: String, startAt: TimeInterval = 0) {
        pendingResumeAt = startAt
        Log.player.debug("TRANSITION loadFileReplacing startAt=\(startAt) url=\(url.prefix(80))")
        withMpv { mpv in
            let args = ["loadfile", url, "replace"]
            _ = args.withUnsafeCArg { mpv_command(mpv, $0) }
        }
    }
}

// MARK: - Audio session / interruption handling

extension PlayerController {
    func assertAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playback || session.mode != .default {
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            }
            try session.setActive(true)
        } catch {
            Log.player.error("Failed to assert audio session: \(error)")
        }
    }

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            Log.player.info("AUDIO_INTERRUPTION began")
            wasPlayingBeforeInterruption = desiredPlaying || playState.value == .playing
            if playState.value == .playing {
                Task { @MainActor in
                    self.setPaused(true)
                    self.desiredPlaying = self.wasPlayingBeforeInterruption
                }
            }
        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let shouldResume = options.contains(.shouldResume) || wasPlayingBeforeInterruption
            Log.player.info("AUDIO_INTERRUPTION ended")
            Task { @MainActor in
                guard shouldResume else { return }
                self.assertAudioSession()
                if self.playState.value != .playing {
                    self.setPaused(false)
                }
                self.wasPlayingBeforeInterruption = false
            }
        @unknown default:
            break
        }
    }

    private func observeAudioSessionReset() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }

    @objc private func handleAudioSessionReset() {
        Log.player.notice("AUDIO_SESSION reset")
        Task { @MainActor in
            self.assertAudioSession()
            self.setNowPlayingMetadata()
            if self.desiredPlaying, self.playState.value != .playing {
                self.setPaused(false)
            }
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        Log.player.info("ROUTE_CHANGE reason=\(reason.rawValue)")
        if reason == .oldDeviceUnavailable, playState.value == .playing {
            Task { @MainActor in togglePlayPause() }
        }
    }
}

// MARK: - Now Playing info / lock-screen

extension PlayerController {
    func setNowPlayingMetadata() {
        assertAudioSession()
        refreshRemoteCommandState()
        let np = NowPlaying.shared
        nowPlayingInfo.removeAll()

        let liveDur = withMpv { mpv in
            var val = Double(0)
            mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &val)
            return val
        } ?? 0
        let duration = liveDur > 0 ? liveDur : np.duration
        if duration > 0 { np.duration = duration }

        let livePos = withMpv { mpv in
            var val = Double(0)
            mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &val)
            return val
        } ?? 0
        let elapsed = livePos > 0 ? livePos : np.currentTime

        nowPlayingInfo[MPMediaItemPropertyTitle] = np.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = np.artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = np.albumTitle
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = np.isPlaying ? 1 : 0
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1
        if duration > 0 { nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration }
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackQueueIndex] = np.queueIndex
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackQueueCount] = np.queueSongs.count
        if let image = np.thumbnailUIImage {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        MPNowPlayingInfoCenter.default().playbackState = np.isPlaying ? .playing : .paused
        Log.player.info(
            "NOW_PLAYING_PUBLISH title='\(np.title)' artist='\(np.artist)' " +
            "duration=\(duration) rate=\(nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] ?? 0) " +
            "artwork=\(np.thumbnailUIImage != nil) keys=\(nowPlayingInfo.keys.count)"
        )
    }

    func updateNowPlayingArtwork() {
        let np = NowPlaying.shared
        if let image = np.thumbnailUIImage {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    func updateNowPlayingProgress(publishToSystem: Bool = true) {
        let hadPendingSeek = pendingSeek != nil
        let props: (dur: Double, pos: Double)? = withMpv { mpv in
            var dur = Double(0)
            mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &dur)
            var pos = Double(0)
            mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &pos)
            return (dur, pos)
        }
        guard var props, props.dur > 0 else { return }
        // AutoMix: mientras suena su tramo preparado, la posicion es la suya (mpv esta en pausa).
        if let positionOverride { props.pos = positionOverride }
        if let durationOverride { props.dur = durationOverride }
        let np = NowPlaying.shared

        if let seek = pendingSeek {
            if abs(props.pos - seek.target) > 1, Date() < seek.deadline {
                props.pos = seek.target
            } else {
                pendingSeek = nil
            }
        }

        var info = nowPlayingInfo
        info[MPMediaItemPropertyPlaybackDuration] = props.dur
        if np.duration != props.dur { np.duration = props.dur }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = props.pos
        if np.currentTime != props.pos { np.currentTime = props.pos }
        info[MPNowPlayingInfoPropertyPlaybackRate] = np.isPlaying ? 1 : 0
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = np.queueIndex
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = np.queueSongs.count
        nowPlayingInfo = info
        guard publishToSystem || hadPendingSeek else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = np.isPlaying ? .playing : .paused
    }
}

// MARK: - Remote commands

extension PlayerController {
    nonisolated static func registerRemoteControlSupport() {
        MainActor.assumeIsolated {
            UIApplication.shared.beginReceivingRemoteControlEvents()
            Log.player.info("REMOTE_COMMANDS launch-time beginReceivingRemoteControlEvents")
        }
    }

    fileprivate func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Log.player.info("REMOTE_COMMAND play fired")
            Task { @MainActor [weak self] in self?.setPaused(false) }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Log.player.info("REMOTE_COMMAND pause fired")
            Task { @MainActor [weak self] in self?.setPaused(true) }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Log.player.info("REMOTE_COMMAND togglePlayPause fired")
            Task { @MainActor [weak self] in self?.togglePlayPause() }
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { _ in
            Log.player.info("REMOTE_COMMAND next fired")
            Task { @MainActor in NowPlaying.shared.playNext() }
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { _ in
            Log.player.info("REMOTE_COMMAND previous fired")
            Task { @MainActor in NowPlaying.shared.playPrevious() }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Log.player.info("REMOTE_COMMAND seek fired to=\(position)")
            Task { @MainActor [weak self] in
                self?.seek(to: position)
                self?.updateNowPlayingProgress()
            }
            return .success
        }

        // Me gusta desde la pantalla de bloqueo, los auriculares o CarPlay.
        center.likeCommand.isEnabled = true
        center.likeCommand.localizedTitle = NSLocalizedString("Like", comment: "")
        center.likeCommand.addTarget { _ in
            Task { @MainActor in
                let np = NowPlaying.shared
                guard let id = np.videoId,
                      let song = np.queueSongs.first(where: { $0.videoId == id }) else { return }
                await LikeStore.shared.toggle(song: song)
            }
            return .success
        }

        // Adelantar y atrasar 15 s: solo se activan con podcasts (ver `refreshRemoteCommandState`).
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.skip(by: 15) }
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.skip(by: -15) }
            return .success
        }

        // El corazon de la pantalla de bloqueo sigue al Me gusta de la app.
        remoteStateCancellable = LikeStore.shared.$liked
            .sink { [weak self] _ in
                // Se publica antes de cambiar el valor: se espera al siguiente turno para leerlo.
                Task { @MainActor [weak self] in self?.refreshRemoteCommandState() }
            }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Keep the audio session alive while the screen is locked so
                // auto-advance can keep playing without user interaction.
                if self.desiredPlaying {
                    self.assertAudioSession()
                }
                self.setNowPlayingMetadata()
                self.updateNowPlayingProgress()
            }
            for delaySeconds in [0.6, 3] as [Double] {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                    guard let self, UIApplication.shared.applicationState != .active else { return }
                    self.setNowPlayingMetadata()
                    self.updateNowPlayingProgress()
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.assertAudioSession()
                self.updateNowPlayingProgress()
            }
        }
    }
}

extension PlayerController {
    /// Pone al dia los botones de la pantalla de bloqueo: corazon segun el Me gusta de la cancion y
    /// +-15 s solo en podcasts (en musica se mantienen siguiente y anterior).
    func refreshRemoteCommandState() {
        let center = MPRemoteCommandCenter.shared()
        let np = NowPlaying.shared
        center.likeCommand.isActive = np.videoId.map { LikeStore.shared.isLiked(videoId: $0) } ?? false
        let isPodcast = np.musicVideoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"
        center.skipForwardCommand.isEnabled = isPodcast
        center.skipBackwardCommand.isEnabled = isPodcast
    }

    func skip(by seconds: TimeInterval) {
        let length = duration
        var target = max(0, currentTime + seconds)
        if length > 0 { target = min(target, max(0, length - 1)) }
        seek(to: target)
        updateNowPlayingProgress()
    }
}

extension Array where Element == String {
    func withUnsafeCArg<T>(_ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> T) -> T {
        let cstrings = map { strdup($0) }
        defer { cstrings.forEach { free($0) } }
        var ptrs = cstrings.map { UnsafePointer($0) } + [nil]
        return ptrs.withUnsafeMutableBufferPointer { buf in
            body(buf.baseAddress)
        }
    }
}

// MARK: - AutoMix: mezcla encadenada dentro de mpv

extension PlayerController {
    /// Deja detras de la cancion que suena el archivo de la mezcla y la entrante, y corta la saliente en `endAt`: asi
    /// mpv encadena los tres sin pausa y sin otro reproductor (con dos reproductores separados las dos copias de la
    /// cancion no se pueden alinear mejor que unas decenas de milisegundos y se oye un doblado).
    func armGaplessMix(mixURL: URL, incomingURL: URL, incomingStart: TimeInterval, endAt: TimeInterval, incomingId: String) -> Bool {
        let endText = String(format: "%.4f", endAt)
        let startOption = "start=" + String(format: "%.4f", incomingStart)
        let mix = mixURL.absoluteString
        let incoming = incomingURL.absoluteString
        let armed: Bool = withMpv { mpv -> Bool in
            mpv_set_property_string(mpv, "gapless-audio", "yes")
            mpv_set_property_string(mpv, "prefetch-playlist", "yes")
            guard mpv_set_property_string(mpv, "end", endText) >= 0 else { return false }
            let first = ["loadfile", mix, "append"].withUnsafeCArg { mpv_command(mpv, $0) }
            let second = ["loadfile", incoming, "append", "-1", startOption].withUnsafeCArg { mpv_command(mpv, $0) }
            if first < 0 || second < 0 {
                mpv_set_property_string(mpv, "end", "none")
                _ = ["playlist-clear"].withUnsafeCArg { mpv_command(mpv, $0) }
                return false
            }
            return true
        } ?? false
        if armed {
            gaplessIncomingId = incomingId
            gaplessMixLoaded = false
            gaplessStage = 1
        }
        return armed
    }

    /// Quita lo que AutoMix dejo preparado detras de la cancion que suena (antes de que llegue el corte).
    func disarmGaplessMix() {
        let wasArmed = gaplessStage == 1
        resetGaplessMix()
        guard wasArmed else { return }
        withMpv { mpv in
            mpv_set_property_string(mpv, "end", "none")
            mpv_set_property_string(mpv, "prefetch-playlist", "no")
            _ = ["playlist-clear"].withUnsafeCArg { mpv_command(mpv, $0) }
        }
    }

    /// Olvida el estado de la mezcla encadenada (no toca mpv: se usa cuando se va a cargar otra cosa).
    func resetGaplessMix() {
        gaplessStage = 0
        gaplessIncomingId = nil
        gaplessMixLoaded = false
        positionOverride = nil
        durationOverride = nil
    }
}
