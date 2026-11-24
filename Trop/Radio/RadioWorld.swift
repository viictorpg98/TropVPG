//
//  RadioWorld.swift
//  Trop
//
//  El mundo real para las secciones de la radio (probado antes en el PC con speechify-prueba\fuentes-prueba.py): titulares de 20minutos, Xataka y Menéame
//  (RSS), las tendencias de Google en España, lo mas leido de la Wikipedia en español y el tiempo (Open-Meteo, sin clave) de la ciudad que elijas en Ajustes.
//  Se baja como mucho cada 3 horas y solo se queda con los TITULARES (nunca el articulo). Las dos fuentes sin datos (sin red) caen sin avisar: la
//  seccion que las necesite se salta. Las noticias de tragedias, muertes o violencia se descartan antes de que lleguen al modelo.
//

import Foundation

struct RadioWeather: Codable {
    var city: String
    var now: Double
    var code: Int
    var max: Double
    var min: Double
    var rain: Int

    var text: String {
        switch code {
        case 0: return "despejado"
        case 1, 2, 3: return "nubes y claros"
        case 45, 48: return "niebla"
        case 51...67, 80...82: return "lluvia"
        case 71...77, 85, 86: return "nieve"
        case 95...99: return "tormenta"
        default: return "tiempo variable"
        }
    }
}

struct RadioWorldData: Codable {
    var headlines: [String]
    var trends: [String]
    var wiki: [String]
    var weather: RadioWeather?
    var fetchedAt: Date
    /// "Un dia como hoy" (Wikipedia): "1963: ..." y el dia al que corresponde ("MM-dd"). Opcionales para leer lo guardado por versiones anteriores.
    var onThisDay: [String]? = nil
    var onThisDayKey: String? = nil
    /// Titulares de deportes (de Google Noticias): "[Deporte en general] ...", "[LaLiga] ...", "[Tu tema: X] ...". Vacio si no se pudo bajar; `nil` si es de una version anterior.
    var sports: [String]? = nil
}

enum RadioWorld {
    private static let cacheKey = "radio.world.v1"
    private static let freshSeconds: TimeInterval = 3 * 3_600
    private static let staleSeconds: TimeInterval = 24 * 3_600

    private static let feeds: [(source: String, url: String)] = [
        ("20minutos", "https://www.20minutos.es/rss/"),
        ("Xataka", "https://www.xataka.com/feedburner.xml"),
        ("Menéame", "https://www.meneame.net/rss")
    ]
    private static let trendsURL = "https://trends.google.com/trending/rss?geo=ES"

    private static let sensitive = try? NSRegularExpression(
        pattern: "muer[et]|mata\\b|matan|falleci|asesin|crimen|violaci|agresi[oó]n|accidente|terroris|v[ií]ctima|suicid|incendio|guerra|ataque|tiroteo|apuñal|cad[aá]ver",
        options: [.caseInsensitive]
    )

    nonisolated(unsafe) private static var memory: RadioWorldData?
    nonisolated(unsafe) private static var fetching = false

    private static func isSensitive(_ text: String) -> Bool {
        guard let sensitive else { return false }
        return sensitive.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - Lo ultimo que hay

    /// Los datos de hoy: de la memoria o del movil si tienen menos de 3 horas; si no, se bajan (como mucho 8 s por fuente). Con fallo de red se usan los de
    /// hace menos de 24 horas; si no hay nada, `nil`.
    static func snapshot() async -> RadioWorldData? {
        if let current = memory ?? stored(), current.sports != nil, Date().timeIntervalSince(current.fetchedAt) < freshSeconds {
            memory = current
            return current
        }
        guard !fetching else { return memory ?? stored() }
        fetching = true
        defer { fetching = false }
        var headlines: [String] = []
        for feed in feeds {
            guard let data = await download(feed.url, timeout: 8) else { continue }
            let found = await parseTitles(data).filter { !isSensitive($0) && $0.count > 15 }
            headlines += found.shuffled().prefix(25).map { "[\(feed.source)] \($0)" }
        }
        headlines += await localHeadlines()
        var trends: [String] = []
        if let data = await download(trendsURL, timeout: 8) {
            trends = await parseTitles(data).filter { !isSensitive($0) }
        }
        let wiki = await mostRead()
        let weather = await currentWeather()
        let today = await onThisDayList()
        let sports = await sportsLines()
        guard !headlines.isEmpty || !trends.isEmpty || !wiki.isEmpty || weather != nil || !today.isEmpty || !sports.isEmpty else {
            if let old = memory ?? stored(), Date().timeIntervalSince(old.fetchedAt) < staleSeconds { return old }
            return nil
        }
        let result = RadioWorldData(
            headlines: headlines, trends: trends, wiki: wiki, weather: weather, fetchedAt: Date(),
            onThisDay: today.isEmpty ? nil : today, onThisDayKey: today.isEmpty ? nil : dayKey(), sports: sports
        )
        memory = result
        if let data = try? JSONEncoder().encode(result) { UserDefaults.standard.set(data, forKey: cacheKey) }
        PlaybackReport.record("radio: datos del mundo: \(headlines.count) titulares, \(trends.count) tendencias, \(wiki.count) de la Wikipedia, \(today.count) de un dia como hoy, \(sports.count) de deportes, tiempo \(weather != nil ? "si" : "no")")
        return result
    }

    /// El tiempo YA bajado (sin pedir nada a la red) si tiene menos de 4 horas: para que los comentarios entre canciones puedan aludir al tiempo en directo.
    static func weatherLine() -> String? {
        guard let current = memory ?? stored(), let weather = current.weather,
              Date().timeIntervalSince(current.fetchedAt) < 4 * 3_600 else { return nil }
        return "El tiempo hace un rato en \(weather.city): \(Int(weather.now.rounded())) grados, \(weather.text); hoy maxima de \(Int(weather.max.rounded())) y minima de \(Int(weather.min.rounded()))."
    }

    /// Los hechos de "un dia como hoy" solo valen si son de HOY (los guardados de ayer no).
    static func onThisDayToday(_ world: RadioWorldData) -> [String] {
        guard world.onThisDayKey == dayKey() else { return [] }
        return world.onThisDay ?? []
    }

    private static func dayKey() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: Date())
    }

    private static func stored() -> RadioWorldData? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(RadioWorldData.self, from: data)
    }

    // MARK: - Fuentes

    private static func download(_ urlString: String, timeout: Double) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("SonarRadio/1.0", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 2
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let result = try? await session.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return result.0
    }

    /// Analiza el RSS fuera del hilo principal (el de 20minutos pesa casi 1 MB).
    private static func parseTitles(_ data: Data) async -> [String] {
        await Task.detached(priority: .utility) { titles(in: data) }.value
    }

    private static func titles(in data: Data) -> [String] {
        let delegate = TitleParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.titles
    }

    /// Lo mas leido de la Wikipedia en español (con 2 dias de retraso, que es lo que publica), sin portadas ni paginas especiales.
    private static func mostRead() async -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let date = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date()
        guard let data = await download(
            "https://wikimedia.org/api/rest_v1/metrics/pageviews/top/es.wikipedia/all-access/\(formatter.string(from: date))", timeout: 8
        ),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let items = json["items"] as? [[String: Any]],
            let articles = items.first?["articles"] as? [[String: Any]] else { return [] }
        let skip = ["Portada", "Especial:", "Wikipedia:", "Usuario:", "Ayuda:", "Categoría:", "Archivo:", "Plantilla:"]
        let names = articles.compactMap { $0["article"] as? String }
            .filter { name in name != "-" && !skip.contains { name.hasPrefix($0) } }
            .map { $0.replacingOccurrences(of: "_", with: " ") }
            .filter { !isSensitive($0) }
        return Array(names.prefix(25))
    }

    /// "Un dia como hoy" de la Wikipedia en español (hechos con año), sin tragedias ni violencia.
    private static func onThisDayList() async -> [String] {
        let parts = dayKey().split(separator: "-")
        guard parts.count == 2,
              let data = await download("https://es.wikipedia.org/api/rest_v1/feed/onthisday/events/\(parts[0])/\(parts[1])", timeout: 8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else { return [] }
        let lines = events.compactMap { event -> String? in
            guard let text = event["text"] as? String, let year = (event["year"] as? NSNumber)?.intValue,
                  text.count >= 25, text.count <= 220, !isSensitive(text) else { return nil }
            return "\(year): \(text)"
        }
        return Array(lines.shuffled().prefix(25))
    }

    /// Lo que no se quiere de los titulares de deportes: lesiones, compras y ofertas, apuestas y guias de horarios.
    private static let sportsNoise = try? NSRegularExpression(
        pattern: "lesi[oó]n|lesionad|molestias|fractura|rotura|operad|operaci[oó]n|descuento|\\bdto\\b|oferta|chollo|black friday|precio|apuest|cuota|bonus|casino|pron[oó]stic|quiniela|horarios|c[oó]mo ver|d[oó]nde ver|en qu[eé] canal|ciberataque",
        options: [.caseInsensitive]
    )

    private static func searchURL(_ topic: String) -> String {
        let encoded = topic.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? topic
        return "https://news.google.com/rss/search?q=\(encoded)%20when:2d&hl=es&gl=ES&ceid=ES:es"
    }

    /// Google Noticias pone " - Medio" al final de cada titular: aqui se quita.
    private static func withoutSource(_ title: String) -> String {
        guard let range = title.range(of: " - ", options: .backwards) else { return title }
        return String(title[..<range.lowerBound])
    }

    /// Titulares de deportes de los ultimos dos dias (Google Noticias, sin clave): el deporte en general, LaLiga y cada uno de los temas del oyente.
    private static func sportsLines() async -> [String] {
        var queries: [(label: String, limit: Int, url: String)] = [
            ("Deporte en general", 6, "https://news.google.com/rss/headlines/section/topic/SPORTS?hl=es&gl=ES&ceid=ES:es"),
            ("LaLiga", 5, searchURL("LaLiga"))
        ]
        for topic in RadioSettings.sportsTopics { queries.append(("Tu tema: \(topic)", 3, searchURL(topic))) }
        var lines: [String] = []
        var seen = Set<String>()
        for query in queries {
            guard let data = await download(query.url, timeout: 8) else { continue }
            let titles = await parseTitles(data)
            var taken = 0
            for raw in titles {
                let title = withoutSource(raw)
                let key = String(title.lowercased().prefix(28))
                var noisy = false
                if let sportsNoise { noisy = sportsNoise.firstMatch(in: title, options: [], range: NSRange(title.startIndex..., in: title)) != nil }
                guard title.count > 20, !isSensitive(title), !noisy, seen.insert(key).inserted else { continue }
                lines.append("[\(query.label)] \(title)")
                taken += 1
                if taken >= query.limit { break }
            }
        }
        lines += await laLigaFacts()
        return lines
    }

    // MARK: - Datos de LaLiga (ESPN, sin clave)

    private struct LeagueRow {
        let id: String
        let name: String
        let rank: Int
        let points: Int
        let played: Int
        let wins: Int
        let draws: Int
        let losses: Int
    }

    private static func espnJSON(_ path: String) async -> [String: Any]? {
        guard let data = await download("https://site.api.espn.com/apis/" + path, timeout: 8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// Un partido de ESPN: la fecha, "Local 3-2 Visitante" (o "Local contra Visitante" si no se ha jugado) y si ya termino.
    private static func match(_ event: [String: Any]) -> (date: Date, line: String, done: Bool)? {
        guard let dateText = event["date"] as? String,
              let competition = (event["competitions"] as? [[String: Any]])?.first,
              let competitors = competition["competitors"] as? [[String: Any]],
              let home = competitors.first(where: { $0["homeAway"] as? String == "home" }),
              let away = competitors.first(where: { $0["homeAway"] as? String == "away" }),
              let homeTeam = home["team"] as? [String: Any], let homeName = homeTeam["displayName"] as? String,
              let awayTeam = away["team"] as? [String: Any], let awayName = awayTeam["displayName"] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        guard let date = formatter.date(from: dateText) else { return nil }
        var done = false
        if let status = competition["status"] as? [String: Any], let type = status["type"] as? [String: Any] {
            done = type["completed"] as? Bool ?? false
        }
        func score(_ side: [String: Any]) -> String {
            if let dict = side["score"] as? [String: Any], let value = dict["displayValue"] as? String { return value }
            if let value = side["score"] as? String { return value }
            if let value = side["score"] as? NSNumber { return value.stringValue }
            return "?"
        }
        let line = done ? "\(homeName) \(score(home))-\(score(away)) \(awayName)" : "\(homeName) contra \(awayName)"
        return (date, line, done)
    }

    /// La clasificacion de LaLiga y, si el equipo del oyente juega en ella, su posicion, su ultimo partido y el proximo (ESPN, datos exactos).
    private static func laLigaFacts() async -> [String] {
        guard let table = await espnJSON("v2/sports/soccer/esp.1/standings"),
              let children = table["children"] as? [[String: Any]],
              let standings = children.first?["standings"] as? [String: Any],
              let entries = standings["entries"] as? [[String: Any]] else { return [] }
        var rows: [LeagueRow] = []
        for entry in entries {
            guard let team = entry["team"] as? [String: Any], let id = team["id"] as? String, let name = team["displayName"] as? String,
                  let stats = entry["stats"] as? [[String: Any]] else { continue }
            var values: [String: Int] = [:]
            for stat in stats {
                if let key = stat["name"] as? String, let number = stat["value"] as? NSNumber { values[key] = number.intValue }
            }
            rows.append(LeagueRow(
                id: id, name: name, rank: values["rank"] ?? 0, points: values["points"] ?? 0, played: values["gamesPlayed"] ?? 0,
                wins: values["wins"] ?? 0, draws: values["ties"] ?? 0, losses: values["losses"] ?? 0
            ))
        }
        rows.sort { $0.rank < $1.rank }
        guard rows.count >= 5, rows[0].rank > 0 else { return [] }
        var facts: [String] = []
        let top = rows.prefix(5).map { "\($0.rank).º \($0.name) (\($0.points) puntos)" }.joined(separator: ", ")
        facts.append("[Dato LaLiga] Clasificación tras \(rows[0].played) jornadas: \(top).")

        var favorite: LeagueRow?
        for topic in RadioSettings.sportsTopics.map({ fold($0) }) where topic.count >= 4 {
            if let found = rows.first(where: { fold($0.name).contains(topic) || topic.contains(fold($0.name)) }) {
                favorite = found
                break
            }
        }
        guard let team = favorite else { return facts }
        facts.append("[Dato LaLiga] \(team.name) va \(team.rank).º con \(team.points) puntos en \(team.played) partidos (\(team.wins) ganados, \(team.draws) empatados, \(team.losses) perdidos).")
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "es_ES")
        dayFormatter.timeZone = TimeZone(identifier: "Europe/Madrid")
        if let past = await espnJSON("site/v2/sports/soccer/esp.1/teams/\(team.id)/schedule"),
           let events = past["events"] as? [[String: Any]] {
            let last = events.compactMap { match($0) }.filter { $0.done }.max { $0.date < $1.date }
            if let last {
                dayFormatter.dateFormat = "d 'de' MMMM"
                facts.append("[Dato LaLiga] Último partido de \(team.name) (\(dayFormatter.string(from: last.date))): \(last.line).")
            }
        }
        if let future = await espnJSON("site/v2/sports/soccer/esp.1/teams/\(team.id)/schedule?fixture=true"),
           let events = future["events"] as? [[String: Any]] {
            let now = Date()
            let next = events.compactMap { match($0) }.filter { !$0.done && $0.date > now }.min { $0.date < $1.date }
            if let next {
                dayFormatter.dateFormat = "EEEE d 'de' MMMM, HH:mm 'h'"
                facts.append("[Dato LaLiga] Próximo partido de \(team.name) (hora de España, \(dayFormatter.string(from: next.date))): \(next.line).")
            }
        }
        return facts
    }

    /// Titulares de la ciudad de la emisora ("[Local: Sabadell] ..."): su diario local si lo hay (Sabadell: el Diari de Sabadell, a veces en catalan); si no, Google Noticias.
    private static func localHeadlines() async -> [String] {
        let city = RadioLocal.cityName
        let feed = RadioLocal.feedURL
        guard let data = await download(feed ?? searchURL(city), timeout: 8) else { return [] }
        var lines: [String] = []
        var seen = Set<String>()
        for raw in await parseTitles(data) {
            let title = feed == nil ? withoutSource(raw) : raw
            let key = String(title.lowercased().prefix(28))
            guard title.count > 20, !isSensitive(title), seen.insert(key).inserted else { continue }
            lines.append("[Local: \(city)] \(title)")
            if lines.count >= 8 { break }
        }
        return lines
    }

    private static func currentWeather() async -> RadioWeather? {
        let city = RadioSettings.city
        let url = "https://api.open-meteo.com/v1/forecast?latitude=\(city.latitude)&longitude=\(city.longitude)"
            + "&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max"
            + "&timezone=auto&forecast_days=1"
        guard let data = await download(url, timeout: 8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let daily = json["daily"] as? [String: Any],
              let now = (current["temperature_2m"] as? NSNumber)?.doubleValue,
              let code = (current["weather_code"] as? NSNumber)?.intValue,
              let max = ((daily["temperature_2m_max"] as? [Any])?.first as? NSNumber)?.doubleValue,
              let min = ((daily["temperature_2m_min"] as? [Any])?.first as? NSNumber)?.doubleValue else { return nil }
        let rain = (((daily["precipitation_probability_max"] as? [Any])?.first) as? NSNumber)?.intValue ?? 0
        return RadioWeather(city: city.name, now: now, code: code, max: max, min: min, rain: rain)
    }
}

/// Saca los `<title>` de cada `<item>` (RSS) o `<entry>` (Atom). Los metodos del delegado tienen que coincidir exactamente con los de XMLParserDelegate.
private final class TitleParser: NSObject, XMLParserDelegate {
    var titles: [String] = []
    private var inItem = false
    private var capturing = false
    private var current = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "item" || elementName == "entry" { inItem = true }
        capturing = inItem && elementName == "title"
        if capturing { current = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { current += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if capturing { current += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "title", capturing {
            let text = current
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#039;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { titles.append(text) }
            capturing = false
        }
        if elementName == "item" || elementName == "entry" { inItem = false }
    }
}
