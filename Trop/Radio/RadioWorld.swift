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
        if let current = memory ?? stored(), Date().timeIntervalSince(current.fetchedAt) < freshSeconds {
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
        var trends: [String] = []
        if let data = await download(trendsURL, timeout: 8) {
            trends = await parseTitles(data).filter { !isSensitive($0) }
        }
        let wiki = await mostRead()
        let weather = await currentWeather()
        guard !headlines.isEmpty || !trends.isEmpty || !wiki.isEmpty || weather != nil else {
            if let old = memory ?? stored(), Date().timeIntervalSince(old.fetchedAt) < staleSeconds { return old }
            return nil
        }
        let result = RadioWorldData(headlines: headlines, trends: trends, wiki: wiki, weather: weather, fetchedAt: Date())
        memory = result
        if let data = try? JSONEncoder().encode(result) { UserDefaults.standard.set(data, forKey: cacheKey) }
        PlaybackReport.record("radio: datos del mundo: \(headlines.count) titulares, \(trends.count) tendencias, \(wiki.count) de la Wikipedia, tiempo \(weather != nil ? "si" : "no")")
        return result
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
