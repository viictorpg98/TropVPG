//
//  TrackAnalysisStore.swift
//  Trop
//

import AVFoundation
import Foundation
import ffmpegkit

/// Analiza las canciones (de una en una, en segundo plano) y guarda el resultado en disco para no repetir el trabajo.
/// Una cancion no analizable se guarda vacia y no se vuelve a intentar.
///
/// Las canciones LARGAS (mas de 10 minutos: mezclas, directos, UGC de horas) no se bajan enteras: la que va a salir se
/// analiza por sus ultimos 2 minutos (cuando faltan 4 para que acabe) y la que va a entrar por los 2 primeros.
@MainActor
final class TrackAnalysisStore {
    static let shared = TrackAnalysisStore()

    /// Para que se pide: la cancion entera, la que va a salir (su final) o la que va a entrar (su principio). En canciones
    /// normales los tres son lo mismo; en las largas, cada papel mira solo su ventana.
    enum Role: String {
        case whole, outgoing, incoming
    }

    private struct Job: Hashable {
        let videoId: String
        let role: Role
        /// Con que nombre se guarda y se apunta todo lo que pasa con este trabajo.
        var key: String { role == .whole ? videoId : "\(videoId).\(role.rawValue)" }
    }

    /// Lecturas de fondo (analisis, onda) a la vez como mucho.
    nonisolated static let readSlots = DispatchSemaphore(value: 4)

    /// Mas de esto (segundos) es una cancion larga.
    nonisolated static let longSeconds: TimeInterval = 600
    /// Lo que se analiza de una larga: el principio o el final.
    nonisolated static let windowSeconds: TimeInterval = 120
    /// La saliente larga se analiza cuando faltan menos de estos segundos.
    nonisolated static let tailLeadSeconds: TimeInterval = 240

    private var memory: [String: TrackStructure] = [:]
    private var unusable: Set<String> = []
    /// Cuando se miro por ultima vez el disco sin encontrar su analisis (para no leerlo cuatro veces por segundo).
    private var missChecked: [String: Date] = [:]
    private var queued: [Job] = []
    private var running = false
    /// Canciones en streaming cuyo analisis fallo (red...): no se guardan como "no analizables", se reintentan mas tarde.
    private var retryAfter: [String: Date] = [:]
    /// Cada tanda de la cola lleva un numero. Si una cancion tarda demasiado (red lenta, direccion estrangulada...) se da por
    /// perdida y la cola sigue con las demas; si su resultado llega tarde se guarda igual, pero ya no toca la cola.
    private var runID = 0
    private var runStarted: Date?
    private var watchdog: Task<Void, Never>?
    /// Fallos seguidos por trabajo: los reintentos se van espaciando (1,5 min, 3, 6... hasta 30).
    private var failures: [String: Int] = [:]
    /// El trabajo que se esta haciendo ahora y los que el vigilante dio por perdidos pero cuya lectura sigue viva (no se
    /// vuelven a pedir hasta que termine, para no bajar el mismo audio dos veces a la vez).
    private var runningJob: Job?
    private var abandoned: Set<String> = []
    /// Duracion de las canciones que han resultado largas.
    private var longDurations: [String: TimeInterval] = [:]
    /// Largas cuya duracion exacta no se conoce (la lectura llego al tope de tiempo de audio).
    private var unknownLong: Set<String> = []
    /// Canciones largas cuyo trozo para "mezclar ahora" no se pudo leer (o no tenia ritmo): un rato no se vuelve a intentar,
    /// para que el reintento de una mezcla que llego tarde no repita la espera.
    private var windowRetryAfter: [String: Date] = [:]

    private init() {
        removeEmptyResultsOnce()
    }

    /// Hasta ahora, una cancion en streaming cuya direccion no se pudo pedir (o cuyo analisis fallo) quedaba como "no
    /// analizable" para siempre (un archivo vacio). Una sola vez se borran esos archivos para que se vuelvan a analizar.
    private func removeEmptyResultsOnce() {
        let flag = "automix.emptyResultsCleaned.v2"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        var removed = 0
        for url in files where url.pathExtension == "json" {
            if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0 {
                try? FileManager.default.removeItem(at: url)
                removed += 1
            }
        }
        if removed > 0 { PlaybackReport.record("automix: \(removed) analisis vacios borrados para volver a analizarlos") }
    }

    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("automix", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    // MARK: - Lo que se sabe

    /// Cuanto dura la cancion, si ya se sabe (la que suena: la dice el reproductor; las demas: la de la cola).
    func knownDuration(_ videoId: String) -> TimeInterval? {
        if let long = longDurations[videoId] { return long }
        let now = NowPlaying.shared
        if now.videoId == videoId, now.duration > 0 { return now.duration }
        if let song = now.queueSongs.first(where: { $0.videoId == videoId }), song.duration > 0 {
            return TimeInterval(song.duration)
        }
        return nil
    }

    /// Es una cancion larga (por su duracion conocida o porque ya se vio que lo es).
    func isLong(_ videoId: String) -> Bool {
        unknownLong.contains(videoId) || (knownDuration(videoId) ?? 0) > Self.longSeconds
    }

    /// El resultado guardado de la cancion ENTERA, o `nil` si aun no se ha analizado (o no se pudo).
    func structure(for videoId: String) -> TrackStructure? {
        load(videoId)
    }

    /// El resultado para ese papel: el de la cancion entera si la hay, y si es larga, el de su ventana.
    func structure(for videoId: String, role: Role) -> TrackStructure? {
        if let whole = load(videoId) { return whole }
        guard role != .whole else { return nil }
        return load(Job(videoId: videoId, role: role).key)
    }

    private func load(_ key: String) -> TrackStructure? {
        if let cached = memory[key] { return cached }
        if unusable.contains(key) { return nil }
        if let last = missChecked[key], Date().timeIntervalSince(last) < 5 { return nil }
        guard let data = try? Data(contentsOf: fileURL(key)) else {
            missChecked[key] = Date()
            return nil
        }
        if data.isEmpty {
            unusable.insert(key)
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(TrackStructure.self, from: data),
              decoded.version == TrackStructure.currentVersion else {
            // Version antigua: se mide otra vez.
            try? FileManager.default.removeItem(at: fileURL(key))
            return nil
        }
        memory[key] = decoded
        return decoded
    }

    /// Hay resultado (valido o "no analizable") y no hace falta pedir nada.
    func isSettled(_ videoId: String, role: Role = .whole) -> Bool {
        if load(videoId) != nil || unusable.contains(videoId) { return true }
        guard role != .whole else { return false }
        let key = Job(videoId: videoId, role: role).key
        return load(key) != nil || unusable.contains(key)
    }

    /// La cola de analisis lleva un buen rato con OTRA cancion: esta puede sacar su onda por su propio carril sin esperar.
    func shouldBypassQueue(for videoId: String) -> Bool {
        running && runningJob?.videoId != videoId && !isAbandoned(videoId)
            && (runStarted.map { Date().timeIntervalSince($0) > 25 } ?? false)
    }

    /// Alguna lectura de esta cancion (entera, final o principio) sigue viva aunque el vigilante la diera por perdida.
    private func isAbandoned(_ videoId: String) -> Bool {
        abandoned.contains { $0 == videoId || $0.hasPrefix(videoId + ".") }
    }

    private func nextRetryDelay(_ key: String) -> TimeInterval {
        let count = (failures[key] ?? 0) + 1
        failures[key] = count
        return min(1800, 90 * pow(2, Double(count - 1)))
    }

    // MARK: - Cola

    /// Pide analizar una cancion; no hace nada si ya esta hecha o en cola.
    func request(_ videoId: String, role: Role = .whole) {
        let job = Job(videoId: videoId, role: role)
        guard !isSettled(videoId, role: role), !queued.contains(job), runningJob?.videoId != videoId, !isAbandoned(videoId) else {
            return
        }
        if let later = retryAfter[job.key], later > Date() { return }
        // Una cancion larga no se analiza entera (su onda tiene otra via) y su final solo cuando ya falta poco.
        if isLong(videoId) {
            if role == .whole { return }
            if role == .outgoing, let duration = knownDuration(videoId), NowPlaying.shared.videoId == videoId,
               duration - NowPlaying.shared.currentTime > Self.tailLeadSeconds { return }
        }
        // En streaming hay que pedir su direccion a YouTube: no se hace mientras se resuelve una cancion ni en los
        // segundos siguientes a un cambio (varias peticiones a la vez dejaban sin direccion valida a la que se quiere oir).
        if !DownloadManager.shared.isDownloaded(videoId: videoId) {
            if NowPlaying.shared.isBusyResolving { return }
            // La direccion de la que suena ya esta en la cache (no cuesta otra peticion a YouTube): se puede analizar antes.
            let wait: TimeInterval = NowPlaying.shared.videoId == videoId ? 3 : 12
            if Date().timeIntervalSince(AutoMixEngine.shared.lastSongChange) < wait { return }
        }
        // La que suena va la primera: de ella dependen la onda de la barra y la mezcla que viene.
        if NowPlaying.shared.videoId == videoId { queued.insert(job, at: 0) } else { queued.append(job) }
        drain()
    }

    /// Lo que sale de leer una cancion.
    private struct Analysis {
        var structure: TrackStructure?
        var wave: [Float]?
        var decoded: Bool
        /// La cancion ha resultado ser larga: su duracion en segundos (`nil` si no).
        var longSeconds: TimeInterval?
        /// Es larga pero no se sabe cuanto dura.
        var longUnknown = false
        /// La saliente es larga y aun falta mucho para su final: se mira mas tarde, sin contar como fallo.
        var deferred = false
        /// `structure` es de una ventana (principio o final) y no de la cancion entera.
        var windowed = false
    }

    private func drain() {
        guard !running else { return }
        // Se descartan las que ya no hacen falta: resueltas, con la lectura anterior aun viva o con un reintento pendiente.
        while let candidate = queued.first,
              isSettled(candidate.videoId, role: candidate.role) || abandoned.contains(candidate.key)
                || (retryAfter[candidate.key].map { $0 > Date() } ?? false) {
            queued.removeFirst()
        }
        guard !queued.isEmpty else { return }
        running = true
        runID += 1
        let id = runID
        runStarted = Date()
        let job = queued.removeFirst()
        runningJob = job
        PlaybackReport.record("automix: analiza \(job.videoId) (\(job.role.rawValue))")
        Task { [weak self] in
            let started = Date()
            var analysis: Analysis?
            var isLocal = true
            if let source = await AutoMixSource.source(for: job.videoId) {
                isLocal = source.isLocal
                let url = source.url
                let local = source.isLocal
                let role = job.role
                // La duracion: la de la direccion o el archivo, o la que dice el reproductor si es la que suena.
                let duration = source.duration ?? self?.knownDuration(job.videoId)
                if let duration, duration > Self.longSeconds, role == .outgoing,
                   NowPlaying.shared.videoId == job.videoId,
                   duration - NowPlaying.shared.currentTime > Self.tailLeadSeconds {
                    analysis = Analysis(structure: nil, wave: nil, decoded: true, longSeconds: duration, deferred: true)
                } else {
                    analysis = await Task.detached(priority: .utility) {
                        await Self.analyze(url, isLocal: local, role: role, duration: duration)
                    }.value
                }
            }
            guard let self else { return }
            self.finish(job, analysis: analysis, isLocal: isLocal, seconds: Date().timeIntervalSince(started), run: id)
        }
        // Vigilante: una cancion no puede tener parada la cola mas de 90 segundos (antes, una tardo 27 minutos y las
        // siguientes se quedaron sin onda ni mezcla).
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
            guard let self, self.running, self.runID == id else { return }
            let delay = self.nextRetryDelay(job.key)
            self.retryAfter[job.key] = Date().addingTimeInterval(delay)
            PlaybackReport.record(String(
                format: "automix: el analisis de %@ (%@) lleva mas de 90 s, la cola sigue con las demas (se reintentara en %.0f min)",
                job.videoId, job.role.rawValue, delay / 60
            ))
            self.abandoned.insert(job.key)
            self.runID += 1
            self.running = false
            self.runStarted = nil
            self.runningJob = nil
            self.drain()
        }
    }

    private func finish(_ job: Job, analysis: Analysis?, isLocal: Bool, seconds: TimeInterval, run: Int) {
        // Si el vigilante ya dio este trabajo por perdido, su resultado se guarda pero no se toca la cola.
        let stale = run != runID
        let videoId = job.videoId
        abandoned.remove(job.key)
        if let long = analysis?.longSeconds, longDurations[videoId] == nil {
            longDurations[videoId] = long
            PlaybackReport.record(String(
                format: "automix: %@ es larga (%.0f min): no se baja entera, solo su principio y su final", videoId, long / 60
            ))
            // Su onda sale por muestras, por su propio carril.
            WaveformStore.shared.request(videoId, urgent: NowPlaying.shared.videoId == videoId)
        }
        if analysis?.longUnknown == true, !unknownLong.contains(videoId) {
            unknownLong.insert(videoId)
            PlaybackReport.record("automix: \(videoId) es larga (no se sabe cuanto): no se baja entera")
            WaveformStore.shared.request(videoId, urgent: NowPlaying.shared.videoId == videoId)
        }
        // La onda de la barra sale del mismo audio: asi no se baja la cancion otra vez para ella.
        if let wave = analysis?.wave { WaveformStore.shared.store(wave, for: videoId) }
        // Una cancion entera se guarda con su id; la ventana de una larga, con el del papel.
        let storeKey = (analysis?.windowed == true) ? job.key : videoId
        if let result = analysis?.structure {
            failures.removeValue(forKey: job.key)
            retryAfter.removeValue(forKey: job.key)
            memory[storeKey] = result
            if let data = try? JSONEncoder().encode(result) {
                try? data.write(to: fileURL(storeKey), options: .atomic)
            }
            PlaybackReport.record(String(
                format: "automix: analizada %@ (%@): %.0f BPM, intro %@, estribillo final %@ (%.1f s)",
                videoId, analysis?.windowed == true ? job.role.rawValue : "entera", result.bpm,
                result.introEndMs.map { "\($0 / 1000)s" } ?? "-",
                result.lastChorusEndMs.map { "\($0 / 1000)s" } ?? "-",
                seconds
            ))
        } else if stale {
            // Llego tarde y sin nada util: el vigilante ya dejo apuntado el reintento.
        } else if analysis == nil {
            // No hubo direccion (sin red, permiso de datos, todos los clientes de YouTube fallan...): es pasajero, se reintenta
            // cada vez mas tarde; no se marca como imposible.
            let delay = nextRetryDelay(job.key)
            retryAfter[job.key] = Date().addingTimeInterval(delay)
            PlaybackReport.record(String(format: "automix: %@ sin direccion para analizar, se reintentara en %.0f min", videoId, delay / 60))
        } else if analysis?.deferred == true {
            // Una saliente larga a la que aun le falta mucho: se vuelve a mirar en un rato (no es un fallo).
            retryAfter[job.key] = Date().addingTimeInterval(20)
        } else if analysis?.longSeconds != nil, analysis?.windowed != true, analysis?.decoded == true {
            // Una larga pedida entera: no hay nada que analizar (su onda sale por muestras).
        } else if analysis?.longUnknown == true {
            // Larga de duracion desconocida: no se sabe donde acaba, se reintentara cuando el reproductor la sepa.
            let delay = nextRetryDelay(job.key)
            retryAfter[job.key] = Date().addingTimeInterval(delay)
        } else if analysis?.decoded == false, !isLocal {
            // En streaming el fallo puede ser pasajero (sin red, direccion caducada, lectura demasiado lenta): se reintenta.
            let delay = nextRetryDelay(job.key)
            retryAfter[job.key] = Date().addingTimeInterval(delay)
            PlaybackReport.record(String(format: "automix: %@ (%@) no se pudo leer, se reintentara en %.0f min", videoId, job.role.rawValue, delay / 60))
        } else {
            // Se leyo bien pero no tiene un compas que analizar (o el archivo local no se puede leer): no se vuelve a intentar.
            unusable.insert(storeKey)
            try? Data().write(to: fileURL(storeKey), options: .atomic)
            PlaybackReport.record("automix: \(videoId) (\(job.role.rawValue)) no se pudo analizar")
        }
        if !stale {
            watchdog?.cancel()
            running = false
            runStarted = nil
            runningJob = nil
            drain()
        }
    }

    // MARK: - Una mezcla pedida a mano en mitad de una cancion larga

    /// La estructura de la parte de una cancion larga que empieza en `position` (para "mezclar ahora" a mitad de una larga).
    /// No se guarda: solo vale para esa mezcla. `nil` si no se pudo.
    func structureAround(_ videoId: String, position: TimeInterval) async -> TrackStructure? {
        if let until = windowRetryAfter[videoId], until > Date() {
            PlaybackReport.record("automix: ventana de \(videoId) para mezclar ahora: se salta (fallo reciente), fundido simple")
            return nil
        }
        guard let source = await AutoMixSource.source(for: videoId) else { return nil }
        let url = source.url
        let local = source.isLocal
        let start = max(0, position - 5)
        // 72 s = 6 pedazos de 12 s, que se leen todos a la vez (con mas pedazos habria una segunda ronda y se pasaria el tiempo).
        let length: TimeInterval = 72
        // Es un trozo del medio: no se sabe donde acaba la musica de verdad (un tramo tranquilo no es el final), asi que
        // se da por buena toda la cancion hasta su final.
        let total = source.duration ?? knownDuration(videoId) ?? (start + length + 3600)
        let outcome = await Task.detached(priority: .userInitiated) { () -> (structure: TrackStructure?, read: Bool) in
            // A trozos cortos y a la vez, con 8 s en total: si la lectura es lenta, mejor un fundido simple enseguida.
            guard let pcm = Self.decodePCMChunked(url, isLocal: local, start: start, length: length, timeout: 8) else { return (nil, false) }
            guard let raw = TrackStructureAnalyzer.analyze(pcm) else { return (nil, true) }
            return (raw.asMiddleWindow(offsetMs: Int64(start * 1000), totalMs: Int64(total * 1000)), true)
        }.value
        if outcome.structure == nil { windowRetryAfter[videoId] = Date().addingTimeInterval(outcome.read ? 180 : 600) }
        let state = outcome.structure != nil ? "ok" : (outcome.read ? "sin compas" : "no se pudo leer")
        PlaybackReport.record("automix: ventana de \(videoId) desde \(Int(start)) s para mezclar ahora: \(state)")
        return outcome.structure
    }

    // MARK: - Lectura del audio y analisis (fuera del hilo principal)

    /// Decodifica la cancion (o su ventana, si es larga) a mono, 16 bits, 8 kHz y la analiza.
    nonisolated private static func analyze(_ url: URL, isLocal: Bool, role: Role, duration: TimeInterval?) async -> Analysis {
        if let duration, duration > longSeconds {
            return analyzeWindow(url, isLocal: isLocal, role: role, duration: duration)
        }
        // Siempre con tope de audio (el umbral y un margen): si la duracion no se conocia y la cancion resulta larga, la
        // lectura se corta ahi en vez de bajar horas.
        let pcm: [Int16]?
        if isLocal, duration != nil {
            pcm = await decode(url)
        } else {
            pcm = decodePCM(url, isLocal: isLocal, start: 0, length: longSeconds + 30, timeout: 120)
        }
        guard let pcm, !pcm.isEmpty else { return Analysis(structure: nil, wave: nil, decoded: false) }
        let seconds = Double(pcm.count) / Double(TrackStructureAnalyzer.sampleRate)
        if duration == nil, seconds >= longSeconds + 15 {
            // Larga y sin saber cuanto dura. La entrante se puede analizar por su principio, que ya se ha leido.
            guard role == .incoming else { return Analysis(structure: nil, wave: nil, decoded: true, longUnknown: true) }
            let head = Array(pcm.prefix(Int(windowSeconds) * TrackStructureAnalyzer.sampleRate))
            let structure = TrackStructureAnalyzer.analyze(head)?.asWindow(offsetMs: 0, keepsStart: true, totalMs: 6 * 3_600_000)
            return Analysis(structure: structure, wave: nil, decoded: true, longUnknown: true, windowed: true)
        }
        let wave: [Float]? = pcm.count > WaveformStore.buckets * 4 ? WaveformStore.envelope(pcm) : nil
        return Analysis(structure: TrackStructureAnalyzer.analyze(pcm), wave: wave, decoded: true)
    }

    /// Una cancion larga: solo se lee su principio (entrante) o sus ultimos 2 minutos (saliente).
    nonisolated private static func analyzeWindow(_ url: URL, isLocal: Bool, role: Role, duration: TimeInterval) -> Analysis {
        // Entera no se analiza: su onda sale por muestras.
        guard role != .whole else { return Analysis(structure: nil, wave: nil, decoded: true, longSeconds: duration) }
        let start = role == .outgoing ? max(0, duration - windowSeconds - 5) : 0
        // La ventana se lee a trozos cortos y a la vez (una lectura larga seguida se queda a medias en algunos videos).
        let length = role == .outgoing ? duration - start + 1 : windowSeconds
        guard let pcm = decodePCMChunked(url, isLocal: isLocal, start: start, length: length, timeout: 60) else {
            return Analysis(structure: nil, wave: nil, decoded: false, longSeconds: duration, windowed: true)
        }
        guard let raw = TrackStructureAnalyzer.analyze(pcm) else {
            return Analysis(structure: nil, wave: nil, decoded: true, longSeconds: duration, windowed: true)
        }
        let structure = raw.asWindow(
            offsetMs: Int64(start * 1000), keepsStart: role == .incoming, totalMs: Int64(duration * 1000)
        )
        return Analysis(structure: structure, wave: nil, decoded: true, longSeconds: duration, windowed: true)
    }

    /// FFmpeg lee la cancion (archivo o direccion de internet), o solo la parte que empieza en `start` y dura `length`, y la
    /// decodifica a PCM crudo en un archivo temporal. `timeout`: si no ha terminado a tiempo (direccion estrangulada, red muy
    /// lenta) se corta y se da por fallida.
    nonisolated static func decodePCM(
        _ url: URL, isLocal: Bool, start: TimeInterval, length: TimeInterval?, timeout: TimeInterval
    ) -> [Int16]? {
        // Las lecturas de fondo ceden ante la reproduccion: ninguna justo despues de un salto del usuario (el audio abre su
        // propia conexion y las de fondo la frenaban) y como mucho 4 a la vez.
        var waited = 0.0
        while Date().timeIntervalSince(PlaybackActivity.lastSeekAt) < 12, waited < 20 {
            Thread.sleep(forTimeInterval: 0.5)
            waited += 0.5
        }
        guard readSlots.wait(timeout: .now() + max(timeout - waited, 1)) == .success else { return nil }
        defer { readSlots.signal() }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("automix-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var arguments = ["-y", "-v", "error"] + AutoMixSource.inputOptions(for: url)
        if start > 0 { arguments += ["-ss", String(format: "%.3f", start)] }
        if let length { arguments += ["-t", String(format: "%.3f", length)] }
        arguments += [
            "-i", url.isFileURL ? url.path : url.absoluteString,
            "-vn", "-ac", "1", "-ar", String(TrackStructureAnalyzer.sampleRate),
            "-f", "s16le", temporary.path
        ]
        let began = Date()
        let what = String(format: "ffmpeg %@ desde %.0f s%@", url.isFileURL ? "archivo" : "internet", start,
                          length.map { String(format: ", %.0f s", $0) } ?? " hasta el final")
        let done = DispatchSemaphore(value: 0)
        let session = FFmpegKit.execute(
            withArgumentsAsync: arguments,
            withCompleteCallback: { _ in done.signal() },
            withLogCallback: nil,
            withStatisticsCallback: nil
        )
        if done.wait(timeout: .now() + timeout) == .timedOut {
            session?.cancel()
            _ = done.wait(timeout: .now() + 10)
            PlaybackReport.record(String(format: "%@: cortado a los %.0f s sin terminar", what, Date().timeIntervalSince(began)))
            return nil
        }
        let elapsed = Date().timeIntervalSince(began)
        guard ReturnCode.isSuccess(session?.getReturnCode()),
              let data = try? Data(contentsOf: temporary), data.count > 2 else {
            // Para saber por que falla (direccion caducada, 403, formato...): el final de lo que dijo FFmpeg.
            let output = (session?.getOutput() ?? "").split(separator: "\n").suffix(3).joined(separator: " | ")
            PlaybackReport.record(String(format: "%@: fallo en %.1f s (%@)", what, elapsed, String(output.prefix(240))))
            return nil
        }
        // Una lectura lenta (direccion estrangulada) se apunta aunque termine bien.
        if elapsed > 8 { PlaybackReport.record(String(format: "%@: tardo %.0f s", what, elapsed)) }
        var samples = [Int16](repeating: 0, count: data.count / 2)
        samples.withUnsafeMutableBufferPointer { buffer in _ = data.copyBytes(to: buffer) }
        return samples
    }

    /// Como `decodePCM`, pero el trozo se lee en pedazos de `chunk` s, hasta 6 a la vez, y se pegan en orden. Cada pedazo sale de
    /// una conexion nueva (como las muestras de la onda, que van rapido) en vez de una lectura larga seguida. Cada pedazo se
    /// ajusta a su largo exacto para que los tiempos del analisis no se desplacen. Si falla alguno (o se acaba `timeout`), `nil`.
    nonisolated static func decodePCMChunked(
        _ url: URL, isLocal: Bool, start: TimeInterval, length: TimeInterval, chunk: TimeInterval = 12, timeout: TimeInterval
    ) -> [Int16]? {
        let rate = TrackStructureAnalyzer.sampleRate
        let count = max(1, Int((length / chunk).rounded(.up)))
        let box = ChunkBox(count: count)
        let deadline = Date().addingTimeInterval(timeout)
        DispatchQueue.concurrentPerform(iterations: count) { index in
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 1 else { return }
            let begin = start + Double(index) * chunk
            let span = min(chunk, start + length - begin)
            guard span > 0.5,
                  var pcm = decodePCM(url, isLocal: isLocal, start: begin, length: span, timeout: min(remaining, 15)) else { return }
            let expected = Int((span * Double(rate)).rounded())
            if pcm.count > expected {
                pcm.removeLast(pcm.count - expected)
            } else if pcm.count < expected {
                // Un pedazo que no es el ultimo no puede quedarse corto (se descuadrarian los tiempos); el ultimo si, si la
                // cancion acaba antes de lo previsto. Faltas minimas se rellenan con silencio.
                let missing = expected - pcm.count
                if index < count - 1 {
                    guard missing <= rate / 10 else { return }
                    pcm.append(contentsOf: [Int16](repeating: 0, count: missing))
                }
            }
            box.set(index, pcm)
        }
        var joined: [Int16] = []
        for index in 0..<count {
            guard let part = box.get(index) else { return nil }
            joined.append(contentsOf: part)
        }
        return joined.count > 2 ? joined : nil
    }

    /// Una cancion en streaming entera (la usa la onda de las normales).
    nonisolated static func decodeRemote(_ url: URL, timeout: TimeInterval = 120) -> [Int16]? {
        decodePCM(url, isLocal: false, start: 0, length: longSeconds + 30, timeout: timeout)
    }

    nonisolated static func decode(_ url: URL) async -> [Int16]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: TrackStructureAnalyzer.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            let count = length / MemoryLayout<Int16>.size
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: count * MemoryLayout<Int16>.size,
                    destination: base.advanced(by: start * MemoryLayout<Int16>.size)
                )
            }
            if status != kCMBlockBufferNoErr { return nil }
        }
        return reader.status == .completed ? samples : nil
    }
}

extension TrackStructure {
    /// Lo medido sobre un trozo del MEDIO de una cancion larga (para "mezclar ahora"): ni su intro ni su final se conocen.
    func asMiddleWindow(offsetMs: Int64, totalMs: Int64) -> TrackStructure {
        var shifted = self
        shifted.downbeatsMs = downbeatsMs.map { $0 + offsetMs }
        shifted.sections = sections.map { SectionChange(timeMs: $0.timeMs + offsetMs, deltaDb: $0.deltaDb) }
        shifted.waveform = nil
        shifted.firstSoundMs = 0
        shifted.lastSoundMs = totalMs
        shifted.musicEndMs = totalMs
        shifted.introEndMs = nil
        shifted.lastChorusEndMs = nil
        return shifted
    }

    /// La estructura medida sobre un trozo de una cancion larga, puesta en los tiempos de la cancion entera.
    /// - `keepsStart`: el trozo es el principio (se conservan el primer sonido y la intro; el final no se conoce y se da por
    ///   el de la cancion). Si no, es un trozo del final o del medio (la intro no existe y el primer sonido es el del trozo).
    func asWindow(offsetMs: Int64, keepsStart: Bool, totalMs: Int64? = nil) -> TrackStructure {
        var shifted = self
        shifted.downbeatsMs = downbeatsMs.map { $0 + offsetMs }
        shifted.sections = sections.map { SectionChange(timeMs: $0.timeMs + offsetMs, deltaDb: $0.deltaDb) }
        shifted.waveform = nil
        if keepsStart {
            let end = totalMs ?? (musicEndMs + offsetMs)
            shifted.lastSoundMs = end
            shifted.musicEndMs = end
            shifted.lastChorusEndMs = nil
        } else {
            shifted.firstSoundMs = 0
            shifted.lastSoundMs = lastSoundMs + offsetMs
            shifted.musicEndMs = musicEndMs + offsetMs
            shifted.introEndMs = nil
            shifted.lastChorusEndMs = lastChorusEndMs.map { $0 + offsetMs }
        }
        return shifted
    }
}

/// Los pedazos de una ventana, que se rellenan desde varios hilos a la vez.
private final class ChunkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [[Int16]?]

    init(count: Int) { parts = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ value: [Int16]) {
        lock.lock()
        parts[index] = value
        lock.unlock()
    }

    func get(_ index: Int) -> [Int16]? {
        lock.lock()
        defer { lock.unlock() }
        return parts[index]
    }
}

/// Lo que esta haciendo la reproduccion y las lecturas de fondo deben respetar.
enum PlaybackActivity {
    /// Cuando fue el ultimo salto de posicion: justo despues, el audio necesita su conexion libre.
    nonisolated(unsafe) static var lastSeekAt = Date.distantPast
}
