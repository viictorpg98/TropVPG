//
//  SystemVolume.swift
//  Trop
//
//  El volumen real del dispositivo: se lee y se sigue (botones fisicos, Centro de control) y se puede cambiar desde un
//  deslizador propio. iOS no da una forma directa de cambiar el volumen del sistema: se usa un `MPVolumeView`
//  escondido y se mueve su deslizador interno.
//

import AVFoundation
import MediaPlayer
import SwiftUI

@MainActor
final class SystemVolume: ObservableObject {
    @Published private(set) var level: Double
    fileprivate weak var slider: UISlider?
    private var observation: NSKeyValueObservation?
    private var lastUserChange = Date.distantPast

    init() {
        level = Double(AVAudioSession.sharedInstance().outputVolume)
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Mientras se arrastra, los avisos del sistema llegan con retraso y harian saltar el deslizador.
                guard Date().timeIntervalSince(self.lastUserChange) > 0.4 else { return }
                self.level = Double(value)
            }
        }
    }

    func set(_ value: Double) {
        let clamped = min(1, max(0, value))
        lastUserChange = Date()
        level = clamped
        slider?.value = Float(clamped)
    }
}

/// El `MPVolumeView` que hace falta para poder cambiar el volumen del sistema (casi invisible, sin tocarse).
struct SystemVolumeHost: UIViewRepresentable {
    let model: SystemVolume

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        // El deslizador interno se crea despues, al colocarse la vista.
        Task { @MainActor in
            model.slider = view.subviews.compactMap { $0 as? UISlider }.first
        }
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        if model.slider == nil {
            model.slider = view.subviews.compactMap { $0 as? UISlider }.first
        }
    }
}
