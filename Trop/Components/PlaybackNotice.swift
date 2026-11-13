//
//  PlaybackNotice.swift
//  Trop
//

import Observation
import SwiftUI

/// Aviso breve cuando algo no se puede reproducir. Antes un fallo solo quedaba en el registro y,
/// para quien usa la app, parecia que "no pasaba nada" al pulsar.
@Observable
@MainActor
final class PlaybackNotice {
    static let shared = PlaybackNotice()

    private(set) var message: String?
    /// Texto del boton del aviso (por ejemplo "Go to Downloads"); `nil` si no lleva boton.
    private(set) var actionTitle: String?
    @ObservationIgnored private var action: (() -> Void)?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    private init() {}

    func show(_ text: String, actionTitle: String? = nil, duration: Double = 6, action: (() -> Void)? = nil) {
        message = text
        self.actionTitle = actionTitle
        self.action = action
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.message = nil
            self?.actionTitle = nil
            self?.action = nil
        }
    }

    func dismiss() {
        hideTask?.cancel()
        message = nil
        actionTitle = nil
        action = nil
    }

    /// Se pulso el boton del aviso: se cierra y se hace lo que proponia.
    func performAction() {
        let pending = action
        dismiss()
        pending?()
    }
}

/// La barra del aviso; va encima del mini reproductor.
struct PlaybackNoticeBar: View {
    @Environment(SettingsStore.self) private var settings
    @State private var notice = PlaybackNotice.shared

    var body: some View {
        Group {
            if let message = notice.message {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(settings.accentColor)
                    Text(message)
                        .font(.footnote.weight(.medium))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let actionTitle = notice.actionTitle {
                        Button(action: { notice.performAction() }, label: {
                            Text(LocalizedStringKey(actionTitle))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(settings.accentOnColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(settings.accentColor))
                        })
                        .buttonStyle(PressableButtonStyle())
                    }
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
                .contentShape(Rectangle())
                .onTapGesture { notice.dismiss() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: notice.message)
    }
}
