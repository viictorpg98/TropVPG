//
//  DJWriter.swift
//  Trop
//
//  Escribe lo que dice el DJ al presentar una cancion. Si se puede, lo escribe el modelo del propio iPhone (Apple Intelligence,
//  gratis, sin conexion y sin enviar nada fuera); si no esta disponible, tarda demasiado o falla, usa frases hechas. El modelo solo
//  recibe los datos de la cancion (titulo, artista, album, año y la anterior) y se le pide que no invente nada mas.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum DJWriter {
    /// Lo que se sabe de la cancion que empieza.
    struct Context {
        var title: String
        var artist: String
        var album: String?
        var year: Int?
        var previousTitle: String?
        var previousArtist: String?
    }

    enum Source: String {
        case model = "modelo del iPhone"
        case template = "frase hecha"
    }

    struct Line {
        var text: String
        var source: Source
        /// Por que se uso esta fuente (para el informe y la pantalla de pruebas).
        var note: String
    }

    private enum ModelOutcome: Sendable {
        case text(String)
        case failed(String)
        case timeout
    }

    /// Cuanto se espera como maximo al modelo antes de usar una frase hecha.
    private static let modelTimeout: UInt64 = 10_000_000_000

    static func line(for context: Context, useModel: Bool) async -> Line {
        if useModel {
            let (text, note) = await modelLine(context)
            if let text { return Line(text: text, source: .model, note: note) }
            return Line(text: templateLine(context), source: .template, note: note)
        }
        return Line(text: templateLine(context), source: .template, note: "modelo desactivado en los ajustes")
    }

    /// Estado del modelo del iPhone, en texto, para la pantalla de pruebas.
    static func availabilityDescription() -> String {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return "disponible"
        case .unavailable(let reason):
            return "no disponible (\(reason))"
        }
        #else
        return "no disponible en este sistema"
        #endif
    }

    // MARK: - Modelo del iPhone

    private static func modelLine(_ context: Context) async -> (String?, String) {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            return (nil, "modelo no disponible (\(reason))")
        }

        let request = makePrompt(for: context)
        let started = Date()

        let outcome: ModelOutcome = await withTaskGroup(of: ModelOutcome.self) { group in
            group.addTask {
                do {
                    // La sesion se crea aqui dentro (no se captura desde fuera: no es Sendable). Las instrucciones van como cadena
                    // literal, como en el ejemplo de Apple.
                    let session = LanguageModelSession(instructions: """
                    You are a warm, concise radio DJ introducing songs to a Spanish-speaking listener. \
                    Always answer in Spanish, in one or two short sentences, at most 30 words in total. \
                    Use only the facts you are given. Never invent facts about the artist or the song. \
                    No emojis, no quotation marks, no hashtags.
                    """)
                    // Una cadena con interpolacion (y no la variable sola) vale tanto si `respond` pide String como si pide Prompt.
                    let response = try await session.respond(to: "\(request)")
                    return .text(response.content)
                } catch {
                    return .failed("\(error)")
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: modelTimeout)
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }

        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        switch outcome {
        case .text(let raw):
            let cleaned = clean(raw)
            guard !cleaned.isEmpty else { return (nil, "el modelo no escribio nada (\(seconds) s)") }
            return (cleaned, "escrito por el modelo en \(seconds) s")
        case .failed(let description):
            return (nil, "el modelo fallo en \(seconds) s: \(description)")
        case .timeout:
            return (nil, "el modelo tardo mas de \(modelTimeout / 1_000_000_000) s")
        }
        #else
        return (nil, "el modelo del iPhone no existe en este sistema")
        #endif
    }

    private static func makePrompt(for context: Context) -> String {
        var facts = ["Song: \(context.title)", "Artist: \(context.artist)"]
        if let album = context.album, !album.isEmpty { facts.append("Album: \(album)") }
        if let year = context.year { facts.append("Year: \(year)") }
        if let previousTitle = context.previousTitle {
            facts.append("Previous song: \(previousTitle)" + (context.previousArtist.map { " by \($0)" } ?? ""))
        }
        return """
        Introduce the song that has just started, in Spanish, like a friendly radio DJ.
        \(facts.joined(separator: "\n"))
        """
    }

    /// Quita comillas, saltos de linea y espacios de mas, y recorta si se alarga.
    private static func clean(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "“", with: "")
            .replacingOccurrences(of: "”", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 260, let end = text.prefix(260).lastIndex(where: { ".!?".contains($0) }) {
            text = String(text[...end])
        }
        return String(text.prefix(300))
    }

    // MARK: - Frases hechas

    private static func templateLine(_ context: Context) -> String {
        let title = context.title
        let artist = context.artist
        var options: [String] = [
            "Ahora suena \(title), de \(artist).",
            "Esto es \(title), de \(artist).",
            "Seguimos con \(artist) y \(title).",
            "Sube el volumen: \(title), de \(artist)."
        ]
        if let previous = context.previousTitle {
            options.append("Después de \(previous), llega \(title), de \(artist).")
            options.append("Y de \(previous) pasamos a \(title), de \(artist).")
        }
        if let year = context.year {
            options.append("Un clásico del \(year): \(title), de \(artist).")
        }
        return options.randomElement() ?? "Ahora suena \(title)."
    }
}
