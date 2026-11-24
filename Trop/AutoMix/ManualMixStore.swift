//
//  ManualMixStore.swift
//  Trop
//
//  El estilo de mezcla que has elegido TU para una pareja de canciones (la que suena y la siguiente): su duracion y si se
//  iguala el tempo. Manda sobre lo que elegiria AutoMix (y sobre su aprendizaje). Se guarda por pareja, en el movil.
//

import Foundation

@MainActor
final class ManualMixStore {
    static let shared = ManualMixStore()

    /// Lo que se puede elegir a mano.
    struct Choice: Equatable {
        var length: MixStyle.Length
        var matchTempo: Bool
        /// Como suena la transicion.
        var sound: MixSound = .blend
        /// Donde deja la saliente (ms de su cancion) y por donde entra la entrante; `nil`: lo decide AutoMix. Se ajustan a compas.
        var outStartMs: Int64?
        var inStartMs: Int64?
        /// Las curvas del editor (volumen, graves y filtro); `nil`: la mezcla de siempre con el sonido elegido.
        var curves: MixCurves?

        /// "duracion|tempo|sonido|salida|entrada|curvas" (los guardados antiguos llevan solo los dos primeros campos o los cinco primeros).
        var stored: String {
            [
                length.rawValue, matchTempo ? "tempo" : "libre", sound.rawValue,
                outStartMs.map(String.init) ?? "-", inStartMs.map(String.init) ?? "-",
                curves?.encoded ?? "-"
            ].joined(separator: "|")
        }

        init(
            length: MixStyle.Length, matchTempo: Bool, sound: MixSound = .blend, outStartMs: Int64? = nil, inStartMs: Int64? = nil,
            curves: MixCurves? = nil
        ) {
            self.length = length
            self.matchTempo = matchTempo
            self.sound = sound
            self.outStartMs = outStartMs
            self.inStartMs = inStartMs
            self.curves = curves
        }

        init?(stored: String) {
            let parts = stored.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let length = MixStyle.Length(rawValue: parts[0]) else { return nil }
            var sound = MixSound.blend
            var outStart: Int64?
            var inStart: Int64?
            if parts.count >= 5 {
                sound = MixSound(rawValue: parts[2]) ?? .blend
                outStart = Int64(parts[3])
                inStart = Int64(parts[4])
            }
            let curves = parts.count >= 6 ? MixCurves(encoded: parts[5]) : nil
            self.init(
                length: length, matchTempo: parts[1] == "tempo", sound: sound, outStartMs: outStart, inStartMs: inStart, curves: curves
            )
        }
    }

    private static let defaultsKey = "automix.manualStyles.v1"
    private static let maxPairs = 200
    private var styles: [String: String]

    private init() {
        styles = (UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:]
    }

    private func pairKey(_ outId: String, _ inId: String) -> String { "\(outId)>\(inId)" }

    func choice(outId: String, inId: String) -> Choice? {
        styles[pairKey(outId, inId)].flatMap { Choice(stored: $0) }
    }

    /// `nil` quita lo elegido (AutoMix vuelve a decidir).
    func set(_ choice: Choice?, outId: String, inId: String) {
        let key = pairKey(outId, inId)
        if let choice {
            styles[key] = choice.stored
            if styles.count > Self.maxPairs {
                // El diccionario no guarda el orden: se recorta al azar lo que sobra, sin tocar esta pareja.
                for other in styles.keys.filter({ $0 != key }).prefix(styles.count - Self.maxPairs) { styles[other] = nil }
            }
        } else {
            styles[key] = nil
        }
        UserDefaults.standard.set(styles, forKey: Self.defaultsKey)
    }
}

/// Guardar la transicion elegida para una pareja y aplicarla: si es la de la cancion que suena con la siguiente, se rehace el plan.
@MainActor
enum MixTransition {
    /// Hay mezclas: con AutoMix encendido en Ajustes.
    static var mixingEnabled: Bool {
        // La radio (Sonar FM) apaga la mezcla en el paso donde va a hacer un corte con una seccion (la cancion se funde y la siguiente empieza desde cero).
        SettingsStore.shared.autoMixEnabled && !RadioSession.shared.holdsMix
    }

    /// Guarda la eleccion (`nil`: que decida AutoMix) y devuelve el texto que explica cuando se aplicara.
    @discardableResult
    static func apply(_ choice: ManualMixStore.Choice?, outId: String, inId: String) -> String {
        ManualMixStore.shared.set(choice, outId: outId, inId: inId)
        let np = NowPlaying.shared
        let isNext = np.queueSongs.indices.contains(np.queueIndex) && np.queueIndex + 1 < np.queueSongs.count
            && np.queueSongs[np.queueIndex].videoId == outId && np.queueSongs[np.queueIndex + 1].videoId == inId
        guard mixingEnabled else {
            return NSLocalizedString("Saved, but AutoMix is off: turn it on in Settings to use it.", comment: "")
        }
        guard isNext else {
            return NSLocalizedString("Saved for when these two songs play.", comment: "")
        }
        if AutoMixEngine.shared.isActive {
            return NSLocalizedString("Saved. This mix is already prepared; it applies the next time these two play.", comment: "")
        }
        AutoMixEngine.shared.replan()
        return NSLocalizedString("Saved for the next transition.", comment: "")
    }

    /// El nombre corto de lo elegido, para la etiqueta entre dos canciones ("Automatic" si no se ha tocado).
    static func title(for choice: ManualMixStore.Choice?) -> String {
        guard let choice else { return NSLocalizedString("Automatic", comment: "") }
        var title: String
        switch choice.length {
        case .short: title = NSLocalizedString("Short Blend", comment: "")
        case .medium: title = NSLocalizedString("Medium Blend", comment: "")
        case .long: title = NSLocalizedString("Long Blend", comment: "")
        }
        if choice.curves != nil {
            title += " · " + NSLocalizedString("Curves", comment: "")
        } else if choice.sound == .fade {
            title += " · " + NSLocalizedString("Fade", comment: "")
        }
        if choice.outStartMs != nil || choice.inStartMs != nil { title += " · " + NSLocalizedString("Custom points", comment: "") }
        return title
    }

    /// Todo lo que decide como se mezcla una pareja: el estilo, donde deja la saliente y por donde entra la entrante. Lo usan el motor
    /// (la mezcla de verdad) y el editor (la vista previa), para que lo que se ve sea lo que suena.
    struct PlanInputs {
        var style: MixStyle
        var forcedStartMs: Int64?
        var forcedIncomingMs: Int64?
    }

    /// - `currentTime`: donde va la saliente ahora (0 si no es la que suena). Un punto de salida elegido a mano que ya queda a menos de
    ///   10 s se ignora (la mezcla se haria tarde), y el DJ no elige un corte tan pronto.
    static func planInputs(
        outId: String, inId: String, outgoing: TrackStructure, incoming: TrackStructure, currentTime: TimeInterval
    ) -> PlanInputs {
        planInputs(
            outId: outId, inId: inId, outgoing: outgoing, incoming: incoming, currentTime: currentTime,
            choice: ManualMixStore.shared.choice(outId: outId, inId: inId)
        )
    }

    /// Igual, pero con la eleccion a mano dada (el editor la prueba antes de guardarla); `nil` = automatico.
    static func planInputs(
        outId: String, inId: String, outgoing: TrackStructure, incoming: TrackStructure, currentTime: TimeInterval,
        choice: ManualMixStore.Choice?
    ) -> PlanInputs {
        let context = MixLearning.context(outgoingBpm: outgoing.bpm, incomingBpm: incoming.bpm)
        var style: MixStyle
        if let choice {
            style = MixStyle(
                length: choice.length, matchTempo: context == "near" ? choice.matchTempo : true, context: context,
                sound: choice.sound, manual: true, curves: choice.curves
            )
        } else {
            style = MixLearning.shared.style(outId: outId, inId: inId, outBpm: outgoing.bpm, inBpm: incoming.bpm)
        }
        var inputs = PlanInputs(style: style)
        let minStartMs = Int64((currentTime + 10) * 1000)
        if let manual = choice {
            if let start = manual.outStartMs, start >= minStartMs { inputs.forcedStartMs = start }
            inputs.forcedIncomingMs = manual.inStartMs
        }
        inputs.style = style
        return inputs
    }
}
