//
//  Gemini.swift
//  Trop
//
//  Las dos llamadas a Gemini que usa la radio, probadas antes en el PC (speechify-prueba): texto con respuesta JSON (guiones y recetas) y voz
//  (POST /v1beta/interactions, una voz o dos). La clave va en la cabecera x-goog-api-key y no se apunta en ningun registro. Si el cupo se
//  acaba o la clave falla, se deja de insistir un rato y la radio sigue con musica sola.
//

import Foundation

enum Gemini {
    struct Failure: Error, LocalizedError {
        let code: Int
        let message: String
        var errorDescription: String? { message }
    }

    private static let base = "https://generativelanguage.googleapis.com/v1beta"
    private static let pitirreStyle = "relaxed and cocky, slow smirking drawl, amused, laughing easily"
    private static let chuletaStyle = "fast, teasing and energetic, hype-man, interrupting and laughing"
    /// Estilo de las cuñas ("¡Sónar efe eme!").
    static let announcerStyle = "booming radio station announcer, loud, big energy, shouting the station name with a smile"

    /// Cada tipo de peticion (el texto y cada modelo de voz) tiene su propio limite: que se agote la voz no debe parar el texto.
    private enum Scope: Hashable {
        case text
        case voice(String)
    }

    nonisolated(unsafe) private static var coolDowns: [Scope: Date] = [:]

    private static func ensureUsable(_ scope: Scope) throws {
        guard !RadioSettings.apiKey.isEmpty else { throw Failure(code: 401, message: "falta la clave de Gemini") }
        if RadioSettings.capReached { throw Failure(code: 0, message: "tope de gasto diario alcanzado") }
        if let until = coolDowns[scope], Date() < until { throw Failure(code: 429, message: "esperando para no pasarse de peticiones") }
    }

    /// `true` si la voz (el modelo normal y, si esta activada, el de reserva) esta parada por el limite DIARIO (para avisarlo en la pestaña Radio).
    static var voiceExhaustedForDay: Bool {
        var models = [RadioSettings.voiceModel]
        if RadioSettings.fallbackEnabled { models.append(RadioSettings.fallbackModel) }
        let limit = Date().addingTimeInterval(3_600)
        return models.allSatisfy { (coolDowns[.voice($0)] ?? .distantPast) > limit }
    }

    // MARK: - Texto

    /// Pregunta que devuelve JSON (como texto, sin las vallas ```).
    static func text(system: String, prompt: String, temperature: Double, timeout: Double = 8) async throws -> String {
        try ensureUsable(.text)
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["temperature": temperature, "responseMimeType": "application/json"]
        ]
        guard let url = URL(string: "\(base)/models/\(RadioSettings.textModel):generateContent") else {
            throw Failure(code: 0, message: "direccion no valida")
        }
        let json = try await post(url, body: body, timeout: timeout, scope: .text)
        RadioSettings.addSpend(0.0004)
        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              var text = parts.first?["text"] as? String else {
            throw Failure(code: 0, message: "respuesta de texto vacia")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.hasPrefix("```") == true { lines.removeLast() }
            text = lines.joined(separator: "\n")
        }
        return text
    }

    // MARK: - Voz

    /// Audio de uno o dos locutores ("Pitirre" y "Chuleta"). `style` solo vale con un locutor (para las cuñas).
    static func speech(_ turns: [RadioTurn], style: String? = nil, timeout: Double = 15) async throws -> RadioClip {
        let primary = RadioSettings.voiceModel
        do {
            return try await speech(turns, style: style, timeout: timeout, model: primary)
        } catch let failure as Failure where failure.code == 429 && RadioSettings.fallbackEnabled && RadioSettings.fallbackModel != primary {
            // El modelo barato llego a su limite (por minuto o por dia): se prueba con el de reserva, que tiene su propia cuota.
            PlaybackReport.record("radio: voz: \(primary) no puede ahora (\(failure.message)); se prueba la de reserva \(RadioSettings.fallbackModel)")
            return try await speech(turns, style: style, timeout: timeout, model: RadioSettings.fallbackModel)
        }
    }

    private static func speech(_ turns: [RadioTurn], style: String?, timeout: Double, model: String) async throws -> RadioClip {
        try ensureUsable(.voice(model))
        guard !turns.isEmpty else { throw Failure(code: 0, message: "nada que decir") }
        let speakers = Set(turns.map(\.speaker))
        let single = speakers.count == 1 ? speakers.first : nil
        var content: [[String: Any]] = []
        for turn in turns {
            var annotation: [String: Any] = ["type": "speech_metadata"]
            if single != nil {
                // Un locutor: la anotacion solo lleva el estilo.
                annotation["style"] = style ?? styleFor(turn.speaker)
            } else {
                // Dos locutores: cada trozo lleva su locutor y su estilo.
                annotation["speaker"] = turn.speaker
                annotation["style"] = styleFor(turn.speaker)
            }
            content.append(["type": "text", "text": turn.text, "annotations": [annotation]])
        }
        let input: [[String: Any]] = [["type": "user_input", "content": content]]
        let config: [String: Any]
        if let single {
            // Un locutor: speech_config es una LISTA con la voz.
            config = ["speech_config": [["voice": voiceId(for: single)]]]
        } else {
            // Dos locutores: speech_config es un objeto con `speakers`.
            let speakerList: [[String: Any]] = [
                ["speaker": "Pitirre", "voice": RadioSettings.pitirreVoice],
                ["speaker": "Chuleta", "voice": RadioSettings.chuletaVoice]
            ]
            config = ["speech_config": ["speakers": speakerList]]
        }
        let body: [String: Any] = [
            "model": model,
            "input": input,
            "response_format": ["type": "audio"],
            "generation_config": config
        ]
        guard let url = URL(string: "\(base)/interactions") else { throw Failure(code: 0, message: "direccion no valida") }
        let json = try await post(url, body: body, timeout: timeout, scope: .voice(model))
        guard let found = findAudio(json), let raw = Data(base64Encoded: found.data),
              let parsed = RadioAudio.samples(from: raw), parsed.rate > 0, !parsed.samples.isEmpty else {
            throw Failure(code: 0, message: "la respuesta de voz no traia audio")
        }
        let seconds = Double(parsed.samples.count) / Double(parsed.rate)
        // Gasto estimado: el audio son ~25 tokens por segundo a ~6 dolares el millon (unos 0,00014 € por segundo) mas el texto de entrada.
        let rate = model == RadioSettings.voiceModel ? 0.00014 : 0.00021
        RadioSettings.addSpend(seconds * rate + 0.0003)
        RadioSettings.addVoiceRequest()
        return RadioClip(wav: RadioAudio.wav(parsed.samples, rate: parsed.rate), seconds: seconds)
    }

    private static func styleFor(_ speaker: String) -> String {
        speaker == "Chuleta" ? chuletaStyle : pitirreStyle
    }

    private static func voiceId(for speaker: String) -> String {
        speaker == "Chuleta" ? RadioSettings.chuletaVoice : RadioSettings.pitirreVoice
    }

    /// Busca en la respuesta (su forma cambia) el bloque de audio en base64: un diccionario con `data` cuyo tipo diga "audio". En una lista, el ultimo.
    private static func findAudio(_ node: Any) -> (data: String, mime: String)? {
        if let dictionary = node as? [String: Any] {
            let mime = (dictionary["mime_type"] as? String) ?? (dictionary["mimeType"] as? String) ?? ""
            let type = (dictionary["type"] as? String) ?? ""
            if let data = dictionary["data"] as? String, (mime + type).lowercased().contains("audio") {
                return (data, mime)
            }
            for value in dictionary.values {
                if let found = findAudio(value) { return found }
            }
        } else if let array = node as? [Any] {
            var last: (data: String, mime: String)?
            for value in array {
                if let found = findAudio(value) { last = found }
            }
            return last
        }
        return nil
    }

    // MARK: - Red

    private static func post(_ url: URL, body: [String: Any], timeout: Double, scope: Scope) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(RadioSettings.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 1
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            RadioSettings.status = "sin respuesta de Gemini (\((error as NSError).code))"
            throw Failure(code: -1, message: "sin respuesta")
        }
        let code = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let message = explain(code, result.0, scope)
            RadioSettings.status = message
            throw Failure(code: code, message: message)
        }
        guard let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any] else {
            throw Failure(code: 0, message: "respuesta que no es JSON")
        }
        RadioSettings.status = "ok"
        return json
    }

    private static func explain(_ code: Int, _ data: Data, _ scope: Scope) -> String {
        let body = String(data: data, encoding: .utf8) ?? ""
        let detail = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
        switch code {
        case 401, 403:
            return "error \(code): la clave de Gemini no vale o no tiene permiso"
        case 429:
            if body.contains("per day") || body.contains("PerDay") {
                coolDowns[scope] = Date().addingTimeInterval(6 * 3_600)
                return "error 429: cupo diario de Gemini agotado (la radio sigue sin voz)"
            }
            coolDowns[scope] = Date().addingTimeInterval(60)
            return "error 429: demasiadas peticiones seguidas (espera 1 minuto)"
        case 400:
            return "error 400: " + (detail ?? "peticion no valida")
        default:
            return "error \(code)" + (detail.map { ": \($0)" } ?? "")
        }
    }
}
