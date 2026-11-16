//
//  DJSettingsView.swift
//  Trop
//
//  El DJ automatico: que hace mientras esta en marcha. Se enciende desde el reproductor, el menu de la cola o el Inicio (es una sesion).
//

import SwiftUI

struct DJSettingsView: View {
    @Bindable private var dj = DJSettings.shared

    var body: some View {
        List {
            Section {
                SettingsToggleRow("Sort the Queue", icon: "arrow.up.arrow.down", isOn: $dj.sortQueue)
                SettingsToggleRow("Mix Before the Song Ends", icon: "scissors", isOn: $dj.cutEarly)
            } header: {
                Text("DJ")
            } footer: {
                Text("The DJ is a session: start it from the DJ button in the player, from the queue menu or from the Home screen. While it is on, it sorts the next songs so they fit together (tempo and key) and mixes each song into the next at a good moment, without waiting for it to end, like a DJ. Long songs and podcasts play in full. Mixes between songs that are not downloaded need Wi-Fi, or mobile data allowed in the AutoMix settings.")
            }
        }
        .sonarSettingsList()
        .navigationTitle("DJ")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
    }
}
