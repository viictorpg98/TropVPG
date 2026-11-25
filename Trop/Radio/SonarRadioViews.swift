//
//  RadioViews.swift
//  Trop
//
//  Los ajustes de la radio.
//

import AVFoundation
import SwiftUI

struct RadioSettingsView: View {
    @State private var key = RadioSettings.apiKey
    @State private var busy = false
    @State private var message = ""
    @AppStorage(RadioSettings.enabledKey) private var enabled = true
    @AppStorage(RadioSettings.talkEveryKey) private var talkEvery = 2
    @AppStorage(RadioSettings.rhythmKey) private var rhythm = 0
    @AppStorage(RadioSettings.humorKey) private var humor = 1
    @AppStorage(RadioSettings.sportsKey) private var sports = RadioSettings.defaultSports
    @AppStorage(RadioSettings.dailyCapKey) private var cap = 0.30
    @AppStorage(RadioSettings.voiceGainKey) private var gain = 2.6
    @AppStorage(RadioSettings.duckKey) private var duck = 0.45
    @AppStorage(RadioSettings.memoryKey) private var memory = true
    @AppStorage(RadioSettings.sectionsKey) private var sections = true
    @AppStorage(RadioSettings.cityKey) private var city = "Sabadell"
    @AppStorage(RadioSettings.fallbackKey) private var fallback = true
    @AppStorage(RadioSettings.fallbackModelKey) private var fallbackModel = ""
    @AppStorage(RadioSettings.textModelKey) private var textModel = ""
    @AppStorage(RadioSettings.humorModelKey) private var humorModel = ""
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
                Text("The radio uses Google Gemini to write what the hosts say and to give them a voice. What you ask for, the titles of the songs, the time of day, the names of the artists you listen to most and the city you pick for the weather are sent to Google; your key stays on this phone.")
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
                Picker("Regularity", selection: $rhythm) {
                    Text("Exact").tag(0)
                    Text("Natural").tag(1)
                    Text("Unpredictable").tag(2)
                }
                Text("Exact: they talk exactly as often as you choose. Natural: a little variation. Unpredictable: more variation, with some silences and some comments back to back. With “Every song”, the last two just mean they sometimes skip a song.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("Humor", selection: $humor) {
                    Text("Mild").tag(0)
                    Text("Spicy").tag(1)
                    Text("Dark Humor").tag(2)
                }
                Text("Mild: the usual jokes. Spicy: cynical and foul-mouthed, like the radios in GTA. Dark Humor: also macabre and absurd (about made-up things). If Google blocks a piece, it is rewritten in Mild.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("Daily Spending Limit", selection: $cap) {
                    ForEach(Self.capOptions, id: \.self) { value in
                        Text(value == 0 ? NSLocalizedString("No limit", comment: "") : String(format: "%.2f €", value)).tag(value)
                    }
                }
                Toggle("Sections", isOn: $sections)
                if sections { RadioSectionToggles() }
                Picker("City for the Weather", selection: $city) {
                    ForEach(RadioSettings.cities, id: \.name) { place in
                        Text(verbatim: place.name).tag(place.name)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("My Sports")
                    TextField(RadioSettings.defaultSports, text: $sports)
                        .autocorrectionDisabled()
                        .foregroundStyle(.secondary)
                }
                Text("Teams and sports you follow, separated by commas (up to 4). They are used to look for sports headlines and are sent to Google, like the rest of your tastes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text("Voice Level")
                    Slider(value: $gain, in: 1.0...4.0, step: 0.1)
                }
                VStack(alignment: .leading) {
                    Text("Music Under Voices")
                    Slider(value: $duck, in: 0.15...0.8, step: 0.05)
                }
                Text(String(format: NSLocalizedString("Estimated spend today: %@", comment: ""), String(format: "%.3f €", RadioSettings.spentToday)))
                    .foregroundStyle(.secondary)
                Text(String(format: NSLocalizedString("Voice requests today: %d", comment: ""), RadioSettings.voiceRequestsToday))
                    .foregroundStyle(.secondary)
                Toggle("Use Backup Voice at the Limit", isOn: $fallback)
            } footer: {
                Text("The limit is an estimate based on what this app generates, not on what Google charges. When it is reached, the radio keeps playing music without voices.")
            }

            Section {
                Toggle("Radio Remembers", isOn: $memory)
                Button(role: .destructive) {
                    RadioDiary.clear()
                    message = NSLocalizedString("Memory cleared.", comment: "")
                } label: {
                    Label("Clear Memory", systemImage: "trash")
                }
            } footer: {
                Text("The radio keeps a diary on this phone (what you ask for, which artists it plays, how many times you say Not on the Radio) and sends short summaries of it to Google so the hosts can remember and joke about it. Clear Memory deletes it.")
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
                TextField("Humor Model", text: $humorModel, prompt: Text(verbatim: RadioSettings.defaultHumorModel))
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
                TextField("Backup Voice Model", text: $fallbackModel, prompt: Text(verbatim: RadioSettings.defaultFallbackModel))
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
