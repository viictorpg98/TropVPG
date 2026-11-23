//
//  RadioDiary.swift
//  Trop
//
//  La memoria de la radio entre dias: un diario LOCAL (en el movil) de lo que pides, a que hora, que artistas suenan, cuantas veces dices "Esto no" y una
//  linea de recuerdo tras cada charla. Para las bromas con tus datos reales ("como si la radio fuese tu") se manda a Google SOLO un resumen corto de esto
//  (nunca el historial entero ni la ubicacion), y solo si "La radio recuerda" esta activado (Ajustes > Radio). Se puede borrar.
//

import Foundation

enum RadioDiary {
    struct Session: Codable {
        var day: String
        var hour: Int
        var request: String
        var summary: String
    }

    struct Note: Codable {
        var day: String
        var text: String
    }

    private static let sessionsKey = "radio.diary.sessions.v1"
    private static let playsKey = "radio.diary.plays.v1"
    private static let skipsKey = "radio.diary.skips.v1"
    private static let notesKey = "radio.diary.notes.v1"

    // MARK: - Utilidades

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func day(daysAgo: Int, from now: Date = Date()) -> String {
        dayString(Calendar.current.date(byAdding: .day, value: -daysAgo, to: now) ?? now)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func times(_ count: Int) -> String {
        count == 1 ? "1 vez" : "\(count) veces"
    }

    // MARK: - Apuntar

    static func recordSession(request: String, summary: String) {
        guard RadioSettings.memoryEnabled else { return }
        var sessions = load([Session].self, sessionsKey) ?? []
        sessions.append(Session(
            day: dayString(Date()), hour: Calendar.current.component(.hour, from: Date()), request: String(request.prefix(80)), summary: String(summary.prefix(60))
        ))
        save(Array(sessions.suffix(60)), sessionsKey)
    }

    /// Una cancion de la radio que empieza a sonar (se cuentan por artista y dia; se guardan 14 dias).
    static func recordPlay(_ song: SongItem) {
        guard RadioSettings.memoryEnabled, let artist = song.artists.first?.name, !artist.isEmpty else { return }
        var plays = load([String: [String: Int]].self, playsKey) ?? [:]
        let today = dayString(Date())
        plays[today, default: [:]][artist, default: 0] += 1
        let keep = Set((0..<14).map { day(daysAgo: $0) })
        plays = plays.filter { keep.contains($0.key) }
        save(plays, playsKey)
    }

    static func recordNotThis() {
        guard RadioSettings.memoryEnabled else { return }
        var skips = load([String: Int].self, skipsKey) ?? [:]
        skips[dayString(Date()), default: 0] += 1
        let keep = Set((0..<14).map { day(daysAgo: $0) })
        save(skips.filter { keep.contains($0.key) }, skipsKey)
    }

    /// Una linea para recordar de una charla (algo que quedo pendiente, un gag...).
    static func recordNote(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RadioSettings.memoryEnabled, !clean.isEmpty else { return }
        var notes = load([Note].self, notesKey) ?? []
        notes.append(Note(day: dayString(Date()), text: String(clean.prefix(140))))
        save(Array(notes.suffix(20)), notesKey)
    }

    static func clear() {
        for key in [sessionsKey, playsKey, skipsKey, notesKey] { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - Lo que se manda a Gemini

    /// El resumen de lo que la radio sabe de la persona, para el prompt de las charlas ("" si la memoria esta apagada).
    /// `at`: cuando SE VA A OIR el comentario (se escribe unos minutos antes, mientras suena la cancion anterior), para dar la hora de entonces y no la de ahora.
    static func factsBlock(tasteText: String, at spoken: Date = Date(), includeClock: Bool = true) -> String {
        guard RadioSettings.memoryEnabled else { return "" }
        let now = Date()
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "es_ES")
        weekday.dateFormat = "EEEE"
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        var lines: [String] = []
        // La hora y el dia solo se dan de vez en cuando (si no, los locutores la dicen en cada comentario).
        if includeClock {
            lines.append("Ahora es \(weekday.string(from: spoken)) y son, mas o menos, las \(clock.string(from: spoken)) (hora aproximada: di \"sobre las...\" o \"casi las...\", nunca minutos exactos).")
        }

        let sessions = load([Session].self, sessionsKey) ?? []
        let today = dayString(now)
        let todays = sessions.filter { $0.day == today }
        if !todays.isEmpty {
            lines.append("Hoy ha pedido a la radio: " + todays.map { includeClock ? "\"\($0.request)\" (a las \($0.hour) h)" : "\"\($0.request)\"" }.joined(separator: "; ") + ".")
        }
        let yesterdays = sessions.filter { $0.day == day(daysAgo: 1) }
        if !yesterdays.isEmpty {
            lines.append("Ayer pidio: " + yesterdays.map { "\"\($0.request)\"" }.joined(separator: "; ") + ".")
        }
        // Dias seguidos con la radio (contando desde hoy, o desde ayer si hoy aun no ha pedido nada).
        var streak = 0
        var offset = todays.isEmpty ? 1 : 0
        while sessions.contains(where: { $0.day == day(daysAgo: offset) }) {
            streak += 1
            offset += 1
        }
        if streak >= 2 { lines.append("Lleva \(streak) dias seguidos usando la radio.") }

        let plays = load([String: [String: Int]].self, playsKey) ?? [:]
        var totals: [String: Int] = [:]
        for ago in 0..<7 {
            for (artist, count) in plays[day(daysAgo: ago)] ?? [:] { totals[artist, default: 0] += count }
        }
        let top = totals.filter { $0.value >= 3 }.sorted { $0.value > $1.value }.prefix(3)
        if !top.isEmpty {
            lines.append("En la radio esta semana han sonado: " + top.map { "\($0.key) \(times($0.value))" }.joined(separator: ", ") + ".")
        }
        let skips = load([String: Int].self, skipsKey) ?? [:]
        if let count = skips[today], count >= 1 {
            lines.append("Hoy ha dicho \"Esto no, en la radio\" \(times(count)).")
        }
        if !tasteText.isEmpty {
            lines.append(tasteText.replacingOccurrences(of: "GUSTOS DE LA PERSONA: ", with: ""))
        }

        let notes = (load([Note].self, notesKey) ?? []).suffix(6)
        // Sin ningun dato (sin hora, sin gustos, sin recuerdos) no se manda nada: asi no se pide "vacilar con sus datos" sin tenerlos.
        if lines.isEmpty, notes.isEmpty { return "" }
        var text = "LO QUE LA RADIO SABE DE LA PERSONA (datos reales; usalos a veces para vacilarle con cariño, como si la radio fuese ella; NO inventes ningun dato mas sobre ella):\n"
        text += lines.map { "- " + $0 }.joined(separator: "\n")
        if !notes.isEmpty {
            text += "\nRECUERDOS DE LOS LOCUTORES (de dias anteriores; puedes retomarlos, por ejemplo 'como ayer...'):\n"
            text += notes.map { "- (\(label(for: $0.day, now: now))) \($0.text)" }.joined(separator: "\n")
        }
        return text
    }

    private static func label(for dayText: String, now: Date) -> String {
        if dayText == dayString(now) { return "hoy" }
        if dayText == day(daysAgo: 1) { return "ayer" }
        for ago in 2..<15 where dayText == day(daysAgo: ago) { return "hace \(ago) dias" }
        return "hace tiempo"
    }
}
