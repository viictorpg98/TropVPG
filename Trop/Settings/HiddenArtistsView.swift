//
//  HiddenArtistsView.swift
//  Trop
//
//  Los artistas ocultos, para volver a mostrarlos.
//

import SwiftUI

struct HiddenArtistsView: View {
    @State private var artists = HiddenArtists.shared.all

    var body: some View {
        List {
            if artists.isEmpty {
                Text("No hidden artists yet.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(artists) { artist in
                        HStack {
                            Text(artist.name)
                            Spacer()
                            Button("Show Again") {
                                HiddenArtists.shared.unhide(artist)
                                withAnimation { artists = HiddenArtists.shared.all }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } footer: {
                    Text("Artists you hide stop appearing on Home, in radios and in the queue. They still show up when you search for them.")
                }
            }
        }
        .sonarSettingsList()
        .navigationTitle("Hidden Artists")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
    }
}
