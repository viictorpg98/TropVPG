//
//  DJSettingsView.swift
//  Trop
//
//  El DJ en su propia pantalla: cada cuantas canciones habla, con que escribe, que voz usa y una prueba para oirlo. Ya no se
//  enciende aqui: es una sesion que se inicia desde el reproductor, el menu de la cola o el Inicio.
//

import SwiftUI

struct DJSettingsView: View {
    @Bindable private var dj = DJSettings.shared
    @State private var voices: [DJSpeech.VoiceInfo] = []
    @State private var isTesting = false
    @State private var testResult = ""

    private var modelStatus: String {
        String(format: NSLocalizedString("Apple Intelligence model: %@", comment: ""), DJWriter.availabilityDescription())
    }

    var body: some View {
        List {
            Section {
                Stepper(value: $dj.everySongs, in: 1...10) {
                    Text(String(format: NSLocalizedString("Speak every %d songs", comment: ""), dj.everySongs))
                }
                SettingsToggleRow("Write With Apple Intelligence", icon: "sparkles", isOn: $dj.useLanguageModel)
            } header: {
                Text("DJ")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The DJ is a session: start it from the DJ button in the player, from the queue menu or from the Home screen. It lowers the music, says a short line over the start of a song and brings the music back.")
                    Text(modelStatus)
                }
            }

            Section {
                if voices.isEmpty {
                    Text("No Spanish voices found on this device.")
                        .foregroundStyle(.secondary)
                }
                ForEach(voices) { voice in
                    Button {
                        select(voice)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(voice.name)
                                Text(voice.quality + " · " + voice.language)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if dj.voiceId == voice.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                Text("Voice")
            } footer: {
                Text("Tap a voice to hear it. For a much better voice, download an Enhanced or Premium Spanish one in the iPhone Settings: Accessibility > Spoken Content > Voices > Spanish. Then come back and pick it here.")
            }

            Section {
                Button {
                    runTest()
                } label: {
                    Text(LocalizedStringKey(isTesting ? "Testing…" : "Test an Introduction"))
                }
                .disabled(isTesting)
                if !testResult.isEmpty {
                    Text(testResult)
                        .font(.footnote)
                }
            } header: {
                Text("Test")
            } footer: {
                Text("Writes and says an introduction for the song that is playing now (or an example if nothing is playing). What happened is also saved in the playback report, on the lines starting with dj:.")
            }
        }
        .sonarSettingsList()
        .navigationTitle("DJ")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
        .onAppear { voices = DJSpeech.spanishVoices() }
    }

    private func select(_ voice: DJSpeech.VoiceInfo) {
        dj.voiceId = voice.id
        Task {
            await DJSpeech.shared.speak(NSLocalizedString("Hi, I'm your DJ. This is my voice.", comment: ""), voiceId: voice.id)
        }
    }

    private func runTest() {
        isTesting = true
        testResult = ""
        Task {
            testResult = await DJHost.shared.test()
            isTesting = false
        }
    }
}
