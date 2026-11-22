//
//  SleepFilter.swift
//  Trop
//
//  Musica para dormir: un solo filtro para "Para ti", los widgets (y, mas adelante, la radio). NO afecta a Inicio, a la busqueda, a las
//  radios de una cancion, a las listas ni a lo que pidas por voz: la musica de dormir sigue ahi cuando la quieras.
//
//  Todo es reversible y por cancion (nunca por artista):
//  - Marca manual ("Es para dormir"): siempre manda, y se quita desde Ajustes.
//  - Automatico, con el historial local: una larga (20 min o mas) que sono de noche o con el temporizador de la app; palabras tipicas de
//    dormir en el titulo (las claras solas, las ambiguas solo con duracion larga, noche o temporizador). Una cancion de duracion normal NO
//    se quita nunca sola (ni por la hora): solo con la marca manual. Si suena mas de dia que de noche, se recupera.
//  - Excepciones: lo que el algoritmo quito y el usuario dice "no es de dormir" no se vuelve a quitar solo (una marca manual si manda).
//  - Lo que el algoritmo va quitando se apunta (las ultimas 100) para poder revisarlo en Ajustes.
//  - El temporizador de sueño de la app solo anota canciones largas o con palabras de dormir (el del iPhone no se puede ver desde la app).
//

import Foundation

/// Una cancion marcada a mano (o una excepcion): lo justo para ensenarla en una lista.
struct SleepMark: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var artist: String
}

/// Una cancion que el algoritmo ha dejado fuera, para poder revisarla.
struct SleepDetected: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var artist: String
    /// `SleepFilter.Reason.rawValue`.
    var reason: String
    var date: Double
}

final class SleepFilter: @unchecked Sendable {
    static let shared = SleepFilter()

    enum Reason: String, Sendable {
        case marked, night, timer, keywords
    }

    enum KeywordLevel {
        case none, weak, strong
    }

    /// Lo que salio de evaluar el historial local (para el informe).
    struct Evaluation {
        var excluded: [String: Reason] = [:]
        var evaluated: Set<String> = []
    }

    private static let marksKey = "sleepFilter.marks.v1"
    private static let allowedKey = "sleepFilter.allowed.v1"
    private static let logKey = "sleepFilter.log.v1"
    private static let timerKey = "sleepFilter.timerLog.v1"
    private static let autoKey = "sleepFilter.autoReasons.v1"
    private static let evaluatedKey = "sleepFilter.evaluated.v1"
    private static let refreshedKey = "sleepFilter.refreshedAt.v1"
    private static let timerLogLimit = 200
    private static let detectedLimit = 100

    private let lock = NSLock()
    private var marks: [SleepMark]
    private var allowed: [SleepMark]
    private var detected: [String: SleepDetected]
    private var timerLog: [String: Double]
    private var autoReasons: [String: String]
    private var evaluatedIds: Set<String>
    private var logFlushScheduled = false

    private init() {
        let defaults = UserDefaults.standard
        marks = Self.decode([SleepMark].self, defaults.data(forKey: Self.marksKey)) ?? []
        allowed = Self.decode([SleepMark].self, defaults.data(forKey: Self.allowedKey)) ?? []
        let log = Self.decode([SleepDetected].self, defaults.data(forKey: Self.logKey)) ?? []
        detected = Dictionary(log.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        timerLog = (defaults.dictionary(forKey: Self.timerKey) as? [String: Double]) ?? [:]
        autoReasons = (defaults.dictionary(forKey: Self.autoKey) as? [String: String]) ?? [:]
        evaluatedIds = Set(defaults.stringArray(forKey: Self.evaluatedKey) ?? [])
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Marcas manuales

    var allMarks: [SleepMark] {
        lock.lock()
        defer { lock.unlock() }
        return marks
    }

    func isMarked(_ videoId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return marks.contains { $0.id == videoId }
    }

    /// Marcar manda sobre una excepcion anterior y la saca de la lista de "detectadas".
    func mark(_ song: SongItem) {
        guard !song.videoId.isEmpty else { return }
        lock.lock()
        if !marks.contains(where: { $0.id == song.videoId }) {
            marks.append(SleepMark(id: song.videoId, title: song.title, artist: song.artistNamesDisplay))
        }
        allowed.removeAll { $0.id == song.videoId }
        detected.removeValue(forKey: song.videoId)
        let marksSnapshot = marks
        let allowedSnapshot = allowed
        let logSnapshot = Array(detected.values)
        lock.unlock()
        persist(marksSnapshot, key: Self.marksKey)
        persist(allowedSnapshot, key: Self.allowedKey)
        persist(logSnapshot, key: Self.logKey)
    }

    func unmark(_ videoId: String) {
        lock.lock()
        marks.removeAll { $0.id == videoId }
        let snapshot = marks
        lock.unlock()
        persist(snapshot, key: Self.marksKey)
    }

    // MARK: - Excepciones y revision de lo detectado

    var allAllowed: [SleepMark] {
        lock.lock()
        defer { lock.unlock() }
        return allowed
    }

    func isAllowed(_ videoId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowed.contains { $0.id == videoId }
    }

    /// Lo que el algoritmo ha dejado fuera (lo mas reciente primero), sin lo ya marcado a mano ni lo que es una excepcion.
    var detectedList: [SleepDetected] {
        lock.lock()
        defer { lock.unlock() }
        return detected.values
            .filter { entry in !marks.contains { $0.id == entry.id } && !allowed.contains { $0.id == entry.id } }
            .sorted { $0.date > $1.date }
    }

    /// "No es de dormir": la cancion no se vuelve a quitar sola.
    func allow(_ entry: SleepDetected) {
        lock.lock()
        if !allowed.contains(where: { $0.id == entry.id }) {
            allowed.append(SleepMark(id: entry.id, title: entry.title, artist: entry.artist))
        }
        detected.removeValue(forKey: entry.id)
        autoReasons.removeValue(forKey: entry.id)
        let allowedSnapshot = allowed
        let logSnapshot = Array(detected.values)
        let autoSnapshot = autoReasons
        lock.unlock()
        persist(allowedSnapshot, key: Self.allowedKey)
        persist(logSnapshot, key: Self.logKey)
        UserDefaults.standard.set(autoSnapshot, forKey: Self.autoKey)
    }

    /// Quita la excepcion: vuelve a decidir el algoritmo (en la siguiente evaluacion).
    func disallow(_ videoId: String) {
        lock.lock()
        allowed.removeAll { $0.id == videoId }
        let snapshot = allowed
        lock.unlock()
        persist(snapshot, key: Self.allowedKey)
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Apunta una cancion quitada por el algoritmo. Se guarda en disco como mucho cada 2 s (esto se llama muchas veces seguidas).
    private func recordDetected(id: String, title: String, artist: String, reason: Reason) {
        guard !id.isEmpty else { return }
        lock.lock()
        detected[id] = SleepDetected(id: id, title: title, artist: artist, reason: reason.rawValue, date: Date().timeIntervalSince1970)
        trimDetectedLocked()
        let schedule = !logFlushScheduled
        logFlushScheduled = true
        lock.unlock()
        if schedule {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in flushLog() }
        }
    }

    private func trimDetectedLocked() {
        guard detected.count > Self.detectedLimit else { return }
        let oldest = detected.values.sorted { $0.date < $1.date }.prefix(detected.count - Self.detectedLimit)
        for entry in oldest { detected.removeValue(forKey: entry.id) }
    }

    private func flushLog() {
        lock.lock()
        logFlushScheduled = false
        let snapshot = Array(detected.values)
        lock.unlock()
        persist(snapshot, key: Self.logKey)
    }

    // MARK: - Temporizador

    /// Se llama al registrar una reproduccion con el temporizador de sueño de la app en marcha. Solo anota canciones largas o con palabras de dormir.
    func noteTimerPlay(_ song: SongItem) {
        guard song.duration >= 1200 || Self.keywordLevel(title: song.title, artist: song.artistNamesDisplay) != .none else { return }
        lock.lock()
        timerLog[song.videoId] = Date().timeIntervalSince1970
        if timerLog.count > Self.timerLogLimit {
            let oldest = timerLog.sorted { $0.value < $1.value }.prefix(timerLog.count - Self.timerLogLimit)
            for entry in oldest { timerLog.removeValue(forKey: entry.key) }
        }
        let snapshot = timerLog
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: Self.timerKey)
    }

    // MARK: - Palabras

    static func keywordLevel(title: String, artist: String) -> KeywordLevel {
        let words = HiddenArtists.normalize(title + " " + artist)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let text = " " + words.joined(separator: " ") + " "
        for phrase in strongPhrases where text.contains(" " + phrase + " ") { return .strong }
        for word in weakWords where text.contains(" " + word + " ") { return .weak }
        return .none
    }

    /// Frases que casi nunca son una cancion normal.
    private static let strongPhrases = [
        "sleep music", "sleeping music", "music for sleeping", "musica para dormir", "para dormir", "white noise", "ruido blanco",
        "pink noise", "brown noise", "rain sounds", "sonido de lluvia", "sonidos de lluvia", "deep sleep", "sleep sounds", "asmr",
        "binaural beats", "slowed"
    ]

    /// Palabras que tambien salen en canciones normales ("Rain", "Sleep"): solo cuentan con duracion larga, noche o temporizador.
    private static let weakWords = [
        "sleep", "sleeping", "dormir", "rain", "lluvia", "ambient", "ambiental", "relax", "relaxing", "relajante", "meditation",
        "meditacion", "lofi", "lo fi", "lullaby", "nana", "insomnia", "reverb"
    ]

    // MARK: - Historial local

    /// Por que una cancion del historial local es "de dormir" (o `nil` si no lo es).
    func verdict(for stat: ListeningStat) -> Reason? {
        let id = stat.entity.id
        if isMarked(id) { return .marked }
        if isAllowed(id) { return nil }
        lock.lock()
        let timerAt = timerLog[id]
        lock.unlock()
        let day = stat.events - stat.nightEvents
        let duration = stat.entity.duration
        let hasTimer = timerAt != nil
        // Una reproduccion de dia con el temporizador puesto (una siesta) no cuenta como "de dia".
        let timerCoversDay = timerAt.map { $0 >= stat.lastDayPlay.timeIntervalSince1970 - 5 } ?? false
        let recovered = day > stat.nightEvents && !timerCoversDay

        if duration >= 1200, stat.nightEvents >= 1 || hasTimer, !recovered {
            return stat.nightEvents >= 1 ? .night : .timer
        }
        switch Self.keywordLevel(title: stat.entity.title, artist: stat.entity.artistName ?? "") {
        case .strong:
            if !recovered { return .keywords }
        case .weak:
            if duration >= 600 || stat.nightEvents >= 1 || hasTimer, !recovered { return .keywords }
        case .none:
            break
        }
        // Una cancion de duracion normal NUNCA se quita sola por la hora (a las 23:30 se puede estar oyendo musica normal): solo con la marca
        // manual. La musica de dormir se pone a mano y suele ser larga o llevar palabras de dormir.
        return nil
    }

    /// Evalua todo el historial y guarda el resultado, para que el resto (widgets, Listen again, radios) lo consulte sin leer la base de datos.
    func evaluate(stats: [ListeningStat]) -> Evaluation {
        var result = Evaluation()
        var found: [SleepDetected] = []
        let now = Date().timeIntervalSince1970
        for stat in stats {
            let id = stat.entity.id
            result.evaluated.insert(id)
            guard let reason = verdict(for: stat) else { continue }
            result.excluded[id] = reason
            if reason != .marked {
                found.append(SleepDetected(
                    id: id,
                    title: stat.entity.title,
                    artist: stat.entity.artistName ?? "",
                    reason: reason.rawValue,
                    date: now
                ))
            }
        }
        lock.lock()
        autoReasons = result.excluded.mapValues(\.rawValue)
        evaluatedIds = result.evaluated
        // Lo ya evaluado que el algoritmo ya no quita (se recupero) sale de la lista de revision; lo que quita se apunta.
        for id in Array(detected.keys) where result.evaluated.contains(id) && result.excluded[id] == nil {
            detected.removeValue(forKey: id)
        }
        for entry in found { detected[entry.id] = entry }
        trimDetectedLocked()
        let autoSnapshot = autoReasons
        let logSnapshot = Array(detected.values)
        lock.unlock()
        let defaults = UserDefaults.standard
        defaults.set(autoSnapshot, forKey: Self.autoKey)
        defaults.set(Array(result.evaluated), forKey: Self.evaluatedKey)
        defaults.set(now, forKey: Self.refreshedKey)
        persist(logSnapshot, key: Self.logKey)
        return result
    }

    /// Para los widgets (no pasan por "Para ti"): vuelve a evaluar el historial si hace mas de 10 minutos.
    func refreshAutomatic() async {
        let last = UserDefaults.standard.double(forKey: Self.refreshedKey)
        guard Date().timeIntervalSince1970 - last > 600 else { return }
        guard let listening = try? await DatabaseService.shared.fetchListeningStats() else { return }
        _ = evaluate(stats: listening.stats)
    }

    // MARK: - Consulta

    /// Solo por identificador (marca manual o historial local): para lo que no tiene titulo a mano, como las semillas guardadas.
    func isSleep(videoId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if marks.contains(where: { $0.id == videoId }) { return true }
        if allowed.contains(where: { $0.id == videoId }) { return false }
        return autoReasons[videoId] != nil
    }

    /// ¿Es musica de dormir? Con historial local manda lo evaluado; sin el (Listen again, radios, inicio de YouTube) solo valen la marca
    /// manual y las palabras del titulo, y no se recorta nada solo por duracion.
    func isSleep(_ song: SongItem) -> Bool {
        lock.lock()
        let marked = marks.contains { $0.id == song.videoId }
        let isException = allowed.contains { $0.id == song.videoId }
        let evaluated = evaluatedIds.contains(song.videoId)
        let auto = autoReasons[song.videoId] != nil
        let hasTimer = timerLog[song.videoId] != nil
        lock.unlock()
        if marked { return true }
        if isException { return false }
        if evaluated { return auto }
        let level = Self.keywordLevel(title: song.title, artist: song.artistNamesDisplay)
        let byWords = level == .strong || (level == .weak && (song.duration >= 600 || hasTimer))
        if byWords {
            recordDetected(id: song.videoId, title: song.title, artist: song.artistNamesDisplay, reason: .keywords)
        }
        return byWords
    }
}
