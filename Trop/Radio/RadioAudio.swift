//
//  RadioAudio.swift
//  Trop
//
//  Audio de la radio: leer lo que devuelve Gemini (WAV con cabecera o PCM de 16 bits sin ella), subirle el volumen con un limitador suave (las voces de
//  Gemini salen mucho mas bajas que las canciones), la cache en el movil y el reproductor de clips.
//

import AVFoundation
import CryptoKit
import Foundation

struct RadioTurn: Codable, Hashable {
    let speaker: String
    let text: String
}

/// Un audio ya generado (WAV de 16 bits, sin subir de volumen) y lo que dura.
struct RadioClip {
    let wav: Data
    let seconds: Double
    /// `false` para los audios ya preparados a su nivel (las cuñas): no se les sube el volumen al reproducirlos.
    var needsBoost: Bool = true
}

enum RadioAudio {
    // MARK: - WAV

    /// Muestras de 16 bits mono de lo que devuelve Gemini: un WAV con cabecera (se busca el bloque `data`, no se da por hecha una cabecera de 44 bytes)
    /// o PCM crudo de 24 kHz.
    static func samples(from data: Data) -> (samples: [Int16], rate: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count > 2 else { return nil }
        if bytes.count > 12, Array(bytes[0..<4]) == Array("RIFF".utf8) {
            var offset = 12
            var rate = 24_000
            var channels = 1
            var bits = 16
            while offset + 8 <= bytes.count {
                let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
                let size = Int(le32(bytes, offset + 4))
                let body = offset + 8
                if id == "fmt ", body + 16 <= bytes.count {
                    channels = max(1, Int(le16(bytes, body + 2)))
                    rate = Int(le32(bytes, body + 4))
                    bits = Int(le16(bytes, body + 14))
                } else if id == "data" {
                    guard bits == 16 else { return nil }
                    let end = (size == 0 || size == 0xFFFF_FFFF || body + size > bytes.count) ? bytes.count : body + size
                    return (pcm(bytes, from: body, to: end, channels: channels), rate)
                }
                offset = body + size + (size & 1)
            }
            return nil
        }
        return (pcm(bytes, from: 0, to: bytes.count, channels: 1), 24_000)
    }

    private static func pcm(_ bytes: [UInt8], from start: Int, to end: Int, channels: Int) -> [Int16] {
        var result: [Int16] = []
        result.reserveCapacity((end - start) / (2 * channels))
        var index = start
        while index + 1 < end {
            result.append(Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)))
            index += 2 * channels
        }
        return result
    }

    private static func le16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8)
    }

    private static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8) | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
    }

    /// Un WAV de 16 bits mono con cabecera de 44 bytes.
    static func wav(_ samples: [Int16], rate: Int) -> Data {
        var data = Data()
        func append32(_ value: UInt32) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 4))
        }
        func append16(_ value: UInt16) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 2))
        }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(UInt32(rate))
        append32(UInt32(rate * 2))
        append16(2)
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(byteCount))
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }

    /// Duracion de cada ventana del mapa de voz.
    static let activityWindow = 0.05

    /// Donde hay voz en un audio, por ventanas de 50 ms (`true` = habla). Las pausas de menos de 0,4 s entre palabras no cuentan como pausa, para que la
    /// musica solo suba en los silencios de verdad.
    static func activity(of wavData: Data) -> [Bool] {
        guard let parsed = samples(from: wavData), parsed.rate > 0, !parsed.samples.isEmpty else { return [] }
        let size = max(1, Int(Double(parsed.rate) * activityWindow))
        var levels: [Float] = []
        var index = 0
        while index < parsed.samples.count {
            let end = min(index + size, parsed.samples.count)
            var sum: Float = 0
            for position in index..<end {
                let value = Float(parsed.samples[position]) / 32768
                sum += value * value
            }
            levels.append((sum / Float(end - index)).squareRoot())
            index = end
        }
        let peak = levels.max() ?? 0
        guard peak > 0 else { return levels.map { _ in false } }
        let threshold = peak * 0.08
        var active = levels.map { $0 > threshold }
        // Rellena los huecos cortos entre dos trozos con voz.
        let bridge = 8
        var position = 0
        while position < active.count {
            if active[position] {
                position += 1
                continue
            }
            var end = position
            while end < active.count, !active[end] { end += 1 }
            if position > 0, end < active.count, end - position < bridge {
                for fill in position..<end { active[fill] = true }
            }
            position = end
        }
        return active
    }

    static func duration(of wavData: Data) -> Double {
        guard let parsed = samples(from: wavData), parsed.rate > 0 else { return 0 }
        return Double(parsed.samples.count) / Double(parsed.rate)
    }

    /// Sube el volumen de la voz (se hace al reproducir, asi cambiar el ajuste vale tambien para lo ya guardado) con un limitador suave para que
    /// los picos no recorten.
    static func boosted(_ wavData: Data, gain: Double = RadioSettings.voiceGain) -> Data {
        guard let parsed = samples(from: wavData) else { return wavData }
        let factor = Float(gain)
        let knee: Float = 0.6
        let room: Float = 0.38
        let lifted = parsed.samples.map { sample -> Int16 in
            var value = Float(sample) / 32768 * factor
            let magnitude = abs(value)
            if magnitude > knee {
                value = (value < 0 ? -1 : 1) * (knee + room * tanh((magnitude - knee) / room))
            }
            return Int16(max(-32_767, min(32_767, value * 32_767)))
        }
        return wav(lifted, rate: parsed.rate)
    }

    // MARK: - Cache

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("radio-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var fixedDirectory: URL {
        let url = directory.appendingPathComponent("fixed", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(for key: String, fixed: Bool) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return (fixed ? fixedDirectory : directory).appendingPathComponent(digest + ".wav")
    }

    static func cached(key: String, fixed: Bool) -> RadioClip? {
        guard let data = try? Data(contentsOf: file(for: key, fixed: fixed)) else { return nil }
        let seconds = duration(of: data)
        return seconds > 0 ? RadioClip(wav: data, seconds: seconds) : nil
    }

    static func store(_ clip: RadioClip, key: String, fixed: Bool) {
        try? clip.wav.write(to: file(for: key, fixed: fixed))
        if !fixed { trim() }
    }

    /// Las frases sueltas (comentarios entre canciones) se borran a los 7 dias o si pasan de 150 MB; las fijas (preguntas, rellenos, cuñas) se quedan.
    private static func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let wavs = files.filter { $0.pathExtension == "wav" }
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        var kept: [(url: URL, date: Date, size: Int)] = []
        for url in wavs {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let date = values?.contentModificationDate ?? .distantPast
            if date < cutoff {
                try? FileManager.default.removeItem(at: url)
            } else {
                kept.append((url, date, values?.fileSize ?? 0))
            }
        }
        var total = kept.reduce(0) { $0 + $1.size }
        for entry in kept.sorted(by: { $0.date < $1.date }) where total > 150 * 1_024 * 1_024 {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

/// Reproduce un clip y espera a que acabe; se puede cortar (`stop`). Cada clip lleva su propio plazo para que el de uno anterior no corte el siguiente.
final class RadioClipPlayer: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var currentToken = UUID()

    func play(_ data: Data) async -> Bool {
        stop()
        guard let player = try? AVAudioPlayer(data: data) else { return false }
        self.player = player
        player.delegate = self
        player.volume = 1
        player.prepareToPlay()
        let token = UUID()
        currentToken = token
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.continuation = continuation
            if !player.play() {
                finish(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + player.duration + 3) { [weak self] in
                if self?.currentToken == token { self?.finish(false) }
            }
        }
    }

    func stop() {
        player?.stop()
        finish(false)
    }

    /// Por donde va el audio que suena (0 si no suena nada).
    var currentTime: TimeInterval {
        player?.currentTime ?? 0
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

/// Reproduce la musiquita de una seccion (un MP3 de la app) por debajo de la voz: se puede subir y bajar su volumen. NO usa `RadioAudio` (eso es para WAV).
final class RadioBedPlayer: @unchecked Sendable {
    private var player: AVAudioPlayer?

    /// Empieza a sonar; devuelve lo que dura, o `nil` si no se pudo.
    @discardableResult
    func start(url: URL, volume: Float) -> TimeInterval? {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.volume = volume
        player.prepareToPlay()
        guard player.play() else { return nil }
        self.player = player
        return player.duration
    }

    var volume: Float {
        get { player?.volume ?? 0 }
        set { player?.volume = newValue }
    }

    var isPlaying: Bool { player?.isPlaying ?? false }

    func fade(to volume: Float, over seconds: TimeInterval) {
        player?.setVolume(volume, fadeDuration: seconds)
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
