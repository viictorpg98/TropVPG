//
//  SleepMarksView.swift
//  Trop
//
//  Musica para dormir: las canciones marcadas a mano (para quitarles la marca), lo que el algoritmo ha dejado fuera por su cuenta (para
//  decir "no es de dormir" si se ha equivocado) y las excepciones.
//

import Foundation
import SwiftUI

struct SleepMarksView: View {
    @State private var marks = SleepFilter.shared.allMarks
    @State private var detected = SleepFilter.shared.detectedList
    @State private var exceptions = SleepFilter.shared.allAllowed

    var body: some View {
        List {
            Section {
                if marks.isEmpty {
                    Text("No songs marked for sleeping yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(marks) { mark in
                    row(title: mark.title, subtitle: mark.artist, button: "Unmark") {
                        SleepFilter.shared.unmark(mark.id)
                        reload()
                    }
                }
            } header: {
                Text("Marked by You")
            } footer: {
                Text("Marked songs stay out of For You, the widgets and the radio. They still play when you search for them or start them yourself.")
            }

            Section {
                if detected.isEmpty {
                    Text("Nothing detected yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(detected) { entry in
                    row(title: entry.title, subtitle: subtitle(for: entry), button: "It's Not for Sleeping") {
                        SleepFilter.shared.allow(entry)
                        reload()
                    }
                }
            } header: {
                Text("Detected Automatically")
            } footer: {
                Text("What the app left out on its own: long songs heard at night, or words about sleeping in the title. It fills up as you use For You and the widgets. If it got one wrong, tap “It's Not for Sleeping”.")
            }

            if !exceptions.isEmpty {
                Section {
                    ForEach(exceptions) { mark in
                        row(title: mark.title, subtitle: mark.artist, button: "Back to Automatic") {
                            SleepFilter.shared.disallow(mark.id)
                            reload()
                        }
                    }
                } header: {
                    Text("Exceptions")
                } footer: {
                    Text("Songs you said are not for sleeping: they are never left out automatically.")
                }
            }
        }
        .sonarSettingsList()
        .navigationTitle("Songs for Sleeping")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
        .onAppear { reload() }
    }

    private func reload() {
        withAnimation {
            marks = SleepFilter.shared.allMarks
            detected = SleepFilter.shared.detectedList
            exceptions = SleepFilter.shared.allAllowed
        }
    }

    private func subtitle(for entry: SleepDetected) -> String {
        let reason: String
        switch SleepFilter.Reason(rawValue: entry.reason) {
        case .night: reason = NSLocalizedString("Long song heard at night", comment: "")
        case .timer: reason = NSLocalizedString("Long song heard with the timer", comment: "")
        default: reason = NSLocalizedString("Words about sleeping in the title", comment: "")
        }
        return entry.artist.isEmpty ? reason : entry.artist + " · " + reason
    }

    private func row(title: String, subtitle: String, button: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(button, action: action)
                .buttonStyle(.borderless)
        }
    }
}
