//
//  CloudVoice.swift
//  Trop
//
//  La voz de respuesta de la busqueda por voz ("Poniendo ...", "No he encontrado ..."): una voz de IA de Speechify (plan gratuito) en vez de la
//  del sistema. Es opcional: hace falta pegar la clave de API en Ajustes > Reproduccion. Sin clave, sin conexion, si tarda mas de unos segundos
//  o si se acaba el cupo gratis, se usa la voz del sistema y nunca se queda mudo.
//
//  API (documentacion de Speechify, leida el 20-11-2026): POST https://api.speechify.ai/v1/audio/speech con `Authorization: Bearer <clave>` y un JSON
//  { input, voice_id, audio_format, model } que devuelve { audio_data (base64), ... }; las voces salen de GET /v1/voices?locale=es-ES (`staff_pick_rank`
//  1 es la recomendada). Errores: 401 clave mala, 402 sin creditos, 429 demasiadas peticiones.
//
//  Cada frase generada se guarda en el movil (Application Support/voice-cache): las frases fijas ("¿Qué quieres escuchar?") se generan una sola vez y
//  las repetidas no gastan caracteres. Lo que se dice se envia a Speechify. La clave se guarda en el llavero del movil, nunca en el repositorio.
//

import AVFoundation
import CryptoKit
import Foundation
import Security

enum CloudVoice {
    static let enabledKey = "voice.cloud.enabled"
    private static let statusKey = "voice.cloud.status"
    private static let baseURL = "https://api.speechify.ai"
    private static let keyService = "sonar.cloudvoice"
    private static let keyFallbackKey = "voice.cloud.key.fallback"

    // MARK: - Ajustes

    static var apiKey: String {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keyService,
                kSecAttrAccount as String: "speechify",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return UserDefaults.standard.string(forKey: keyFallbackKey) ?? ""
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keyService,
                kSecAttrAccount as String: "speechify"
            ]
            SecItemDelete(base as CFDictionary)
            UserDefaults.standard.removeObject(forKey: keyFallbackKey)
            guard !trimmed.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(trimmed.utf8)
            // Si el llavero no deja guardarla (algunas firmas de sideload), se guarda en los ajustes de la app.
            if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
                UserDefaults.standard.set(trimmed, forKey: keyFallbackKey)
            }
        }
    }

    static var isConfigured: Bool {
        UserDefaults.standard.bool(forKey: enabledKey) && !apiKey.isEmpty
    }

    /// Lo ultimo que paso con la voz de la nube (para enseñarlo en Ajustes y en el registro).
    static var status: String {
        UserDefaults.standard.string(forKey: statusKey) ?? ""
    }

    private static func setStatus(_ text: String) {
        UserDefaults.standard.set(text, forKey: statusKey)
        VoiceLog.add("voz en la nube: \(text)")
    }

    // MARK: - Voz elegida

    private static var locale: String {
        (Locale.preferredLanguages.first ?? "es").hasPrefix("es") ? "es-ES" : "en-US"
    }

    private static var voiceIdKey: String { "voice.cloud.voiceId.\(locale)" }
    private static var voiceNameKey: String { "voice.cloud.voiceName.\(locale)" }

    static var voiceName: String {
        UserDefaults.standard.string(forKey: voiceNameKey) ?? ""
    }

    private struct Voice {
        let id: String
        let name: String
    }

    /// Las voces del idioma del movil, la recomendada por Speechify primero.
    private static func voices() async -> [Voice] {
        guard var components = URLComponents(string: baseURL + "/v1/voices") else { return [] }
        components.queryItems = [URLQueryItem(name: "locale", value: locale), URLQueryItem(name: "limit", value: "200")]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = await send(request, seconds: 8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["voices"] as? [[String: Any]] else { return [] }
        let ranked = list.compactMap { entry -> (Voice, Int)? in
            guard let id = entry["id"] as? String else { return nil }
            let name = (entry["display_name"] as? String) ?? id
            return (Voice(id: id, name: name), (entry["staff_pick_rank"] as? Int) ?? 9999)
        }
        return ranked.sorted { $0.1 < $1.1 }.map { $0.0 }
    }

    private static func currentVoiceId() async -> String? {
        if let saved = UserDefaults.standard.string(forKey: voiceIdKey), !saved.isEmpty { return saved }
        guard let first = await voices().first else {
            setStatus("no se encontro ninguna voz en \(locale) (revisa la clave)")
            return nil
        }
        UserDefaults.standard.set(first.id, forKey: voiceIdKey)
        UserDefaults.standard.set(first.name, forKey: voiceNameKey)
        return first.id
    }

    /// Pasa a la siguiente voz de la lista (para probar y quedarte con la que mas te guste). Devuelve su nombre.
    static func nextVoice() async -> String? {
        let all = Array(await voices().prefix(12))
        guard !all.isEmpty else {
            setStatus("no se pudo leer la lista de voces (revisa la clave y la conexion)")
            return nil
        }
        let saved = UserDefaults.standard.string(forKey: voiceIdKey)
        let index = all.firstIndex { $0.id == saved }.map { ($0 + 1) % all.count } ?? 0
        UserDefaults.standard.set(all[index].id, forKey: voiceIdKey)
        UserDefaults.standard.set(all[index].name, forKey: voiceNameKey)
        return all[index].name
    }

    // MARK: - Audio

    /// El audio de una frase: de la cache del movil o generado ahora. `nil` si no se puede (se usa la voz del sistema).
    static func audio(for text: String) async -> Data? {
        guard isConfigured, let voiceId = await currentVoiceId() else { return nil }
        let file = cacheFile(text: text, voiceId: voiceId)
        if let cached = try? Data(contentsOf: file) { return cached }
        let started = Date()
        guard let audio = await generate(text: text, voiceId: voiceId) else { return nil }
        try? audio.write(to: file)
        trimCache()
        setStatus("ok, \"\(text.prefix(30))\" en \(Int(Date().timeIntervalSince(started) * 1000)) ms (\(text.count) caracteres)")
        return audio
    }

    /// Deja listas en la cache las frases fijas (asi la pregunta suena al instante y sin red).
    static func prewarm(_ phrases: [String]) async {
        for phrase in phrases { _ = await audio(for: phrase) }
    }

    private static func generate(text: String, voiceId: String) async -> Data? {
        // simba-3.5 es el recomendado; si la voz no lo admite (400) se prueba con simba-3.0, que lista es-ES y es-MX.
        for model in ["simba-3.5", "simba-3.0"] {
            var request = URLRequest(url: URL(string: baseURL + "/v1/audio/speech")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "input": text, "voice_id": voiceId, "audio_format": "mp3", "model": model
            ])
            guard let (data, code) = await send(request, seconds: 4) else { return nil }
            if code == 400 { continue }
            guard code == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let base64 = json["audio_data"] as? String,
                  let audio = Data(base64Encoded: base64) else {
                setStatus(explain(code))
                return nil
            }
            return audio
        }
        setStatus("error 400: la voz no admite el modelo (prueba con otra voz)")
        return nil
    }

    private static func explain(_ code: Int) -> String {
        switch code {
        case 401: return "error 401: la clave de API no vale"
        case 402: return "error 402: se acabo el cupo gratis de este mes (suena la voz del sistema)"
        case 429: return "error 429: demasiadas peticiones seguidas"
        default: return "error \(code)"
        }
    }

    /// Una peticion con tiempo limite total (si tarda mas, se usa la voz del sistema). Devuelve el cuerpo y el codigo, o `nil` sin respuesta.
    private static func send(_ request: URLRequest, seconds: Double) async -> (Data, Int)? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = seconds
        configuration.timeoutIntervalForResource = seconds + 1
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            setStatus("sin respuesta de Speechify (\((error as NSError).code))")
            return nil
        }
    }

    // MARK: - Cache

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("voice-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func cacheFile(text: String, voiceId: String) -> URL {
        let digest = SHA256.hash(data: Data("\(voiceId)|\(text)".utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(digest + ".mp3")
    }

    /// Se guardan como mucho las 300 frases mas recientes.
    private static func trimCache() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: keys),
              files.count > 300 else { return }
        let sorted = files.sorted {
            let first = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return first < second
        }
        for file in sorted.prefix(files.count - 300) { try? FileManager.default.removeItem(at: file) }
    }
}

/// Reproduce el audio de una frase y espera a que termine.
final class ClipPlayer: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Bool, Never>?

    func play(_ data: Data) async -> Bool {
        guard let player = try? AVAudioPlayer(data: data) else { return false }
        self.player = player
        player.delegate = self
        player.prepareToPlay()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.continuation = continuation
            if !player.play() {
                finish(false)
                return
            }
            // Por si el audio no llega a terminar nunca.
            DispatchQueue.main.asyncAfter(deadline: .now() + player.duration + 3) { [weak self] in self?.finish(false) }
        }
    }

    private func finish(_ ok: Bool) {
        continuation?.resume(returning: ok)
        continuation = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finish(false)
    }
}
