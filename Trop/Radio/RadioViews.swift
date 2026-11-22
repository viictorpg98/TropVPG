//
//  RadioViews.swift
//  Trop
//
//  La tarjeta "Sónar FM" del Inicio (como la del DJ) y los ajustes de la radio.
//

import AVFoundation
import SwiftUI

/// La tarjeta del Inicio: un toque empieza la radio (los locutores preguntan que quieres oir); con la radio en marcha, un toque la para (la musica sigue).
struct RadioHomeCard: View {
    private let radio = RadioSession.shared

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(LinearGradient(
                        colors: [Color.orange, Color.red], startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    if radio.isStarting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: radio.isActive ? "dot.radiowaves.left.and.right" : "mic.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .symbolEffect(.variableColor.iterative, isActive: radio.isActive)
                    }
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Sónar FM")
                        .font(.headline)
                    Text(LocalizedStringKey(subtitleKey))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                Image(systemName: radio.isActive ? "stop.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityLabel(Text(verbatim: "Sónar FM"))
    }

    private var subtitleKey: String {
        if radio.isActive { return "The radio is on. Tap to stop it." }
        if !RadioSettings.isConfigured { return "Set up the radio in Settings > Radio." }
        return "Tell the hosts what you feel like hearing."
    }

    private func tap() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if radio.isActive {
            radio.stop(reason: "boton")
            PlaybackNotice.shared.show(NSLocalizedString("Radio stopped.", comment: ""))
            return
        }
        guard !radio.isStarting else { return }
        Task { await radio.begin() }
    }
}

struct RadioSettingsView: View {
    @State private var key = RadioSettings.apiKey
    @State private var busy = false
    @State private var message = ""
    @AppStorage(RadioSettings.enabledKey) private var enabled = true
    @AppStorage(RadioSettings.talkEveryKey) private var talkEvery = 2
    @AppStorage(RadioSettings.dailyCapKey) private var cap = 0.30
    @AppStorage(RadioSettings.voiceGainKey) private var gain = 2.6
    @AppStorage(RadioSettings.textModelKey) private var textModel = ""
    @AppStorage(RadioSettings.voiceModelKey) private var voiceModel = ""
    @AppStorage(RadioSettings.pitirreVoiceKey) private var pitirreVoice = ""
    @AppStorage(RadioSettings.chuletaVoiceKey) private var chuletaVoice = ""

    private static let capOptions: [Double] = [0.10, 0.30, 0.50, 1.00, 0]

    var body: some View {
        List {
            Section {
                Toggle("Radio", isOn: $enabled)
                SecureField("Gemini API Key", text: $key)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: key) {
                        RadioSettings.apiKey = key
                    }
            } header: {
                Text(verbatim: "Sónar FM")
            } footer: {
                Text("The radio uses Google Gemini to write what the hosts say and to give them a voice. What you ask for, the titles of the songs, the time of day and the names of the artists you listen to most are sent to Google; your key stays on this phone.")
            }

            Section {
                Picker("Talk", selection: $talkEvery) {
                    ForEach(1...5, id: \.self) { count in
                        Text(count == 1
                             ? NSLocalizedString("Every song", comment: "")
                             : String(format: NSLocalizedString("Every %d songs", comment: ""), count))
                            .tag(count)
                    }
                }
                Picker("Daily Spending Limit", selection: $cap) {
                    ForEach(Self.capOptions, id: \.self) { value in
                        Text(value == 0 ? NSLocalizedString("No limit", comment: "") : String(format: "%.2f €", value)).tag(value)
                    }
                }
                VStack(alignment: .leading) {
                    Text("Voice Level")
                    Slider(value: $gain, in: 1.0...4.0, step: 0.1)
                }
                Text(String(format: NSLocalizedString("Estimated spend today: %@", comment: ""), String(format: "%.3f €", RadioSettings.spentToday)))
                    .foregroundStyle(.secondary)
            } footer: {
                Text("The limit is an estimate based on what this app generates, not on what Google charges. When it is reached, the radio keeps playing music without voices.")
            }

            Section {
                Button {
                    busy = true
                    message = NSLocalizedString("Preparing phrases…", comment: "")
                    Task {
                        let made = await RadioContent.prewarm()
                        message = String(format: NSLocalizedString("Done: %d new phrases.", comment: ""), made)
                        if RadioSettings.status != "ok", !RadioSettings.status.isEmpty { message += " " + RadioSettings.status }
                        busy = false
                    }
                } label: {
                    Label("Prepare Phrases", systemImage: "arrow.down.circle")
                }
                .disabled(busy || key.isEmpty)
                Button {
                    busy = true
                    Task {
                        if let question = await RadioContent.question() {
                            _ = await RadioClipPlayer().play(RadioAudio.boosted(question.wav))
                            message = NSLocalizedString("Played one question.", comment: "")
                        } else {
                            message = RadioSettings.status.isEmpty ? NSLocalizedString("Couldn't generate the voice.", comment: "") : RadioSettings.status
                        }
                        busy = false
                    }
                } label: {
                    Label("Test Voices", systemImage: "speaker.wave.2")
                }
                .disabled(busy || key.isEmpty)
                if !message.isEmpty {
                    Text(verbatim: message)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Prepare Phrases saves the questions and short phrases once, so the radio starts instantly.")
            }

            Section {
                TextField("Text Model", text: $textModel, prompt: Text(verbatim: RadioSettings.defaultTextModel))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Voice Model", text: $voiceModel, prompt: Text(verbatim: RadioSettings.defaultVoiceModel))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Pitirre's Voice", text: $pitirreVoice, prompt: Text(verbatim: RadioSettings.defaultPitirreVoice))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Chuleta's Voice", text: $chuletaVoice, prompt: Text(verbatim: RadioSettings.defaultChuletaVoice))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Advanced")
            } footer: {
                Text("Leave these empty to use the default models and voices.")
            }
        }
        .sonarSettingsList()
        .navigationTitle("Radio")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
    }
}
