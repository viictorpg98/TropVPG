//
//  PlayerSettingsView.swift
//  Trop
//
//  Created by 686udjie on 20/08/2026.
//

import SwiftUI

struct PlayerSettingsView: View {
    @Environment(\.settingsStore) private var settings

    var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                SettingsNavigationRow("Equalizer", icon: "slider.vertical.3") {
                    EqualizerView()
                }
            } header: {
                Text("Equalizer")
            } footer: {
                Text("Adjust the sound with presets or a custom curve.")
            }

            Section {
                SettingsPickerRow("Audio Quality", icon: "waveform", selection: $settings.audioQuality)
                SettingsToggleRow("Audio Normalization", icon: "speaker.wave.2", isOn: $settings.audioNormalization)
                SettingsToggleRow("Gapless Playback", icon: "arrow.right.arrow.left", isOn: $settings.gaplessPlayback)
            } header: {
                Text("Audio")
            }

            Section {
                SettingsToggleRow("Full-Width Artwork", icon: "rectangle.portrait.topthird.inset.filled", isOn: $settings.fullWidthArtwork)
            } header: {
                Text("Layout")
            } footer: {
                Text("Shows the cover edge to edge and tints the player with its colors, like Apple Music.")
            }

            Section {
                SettingsToggleRow("Animated Artwork", icon: "play.rectangle.on.rectangle", isOn: $settings.animatedArtworkEnabled)
                SettingsToggleRow("Animated Artwork on Mobile Data", icon: "antenna.radiowaves.left.and.right", isOn: $settings.animatedArtworkUsesMobileData)
            } header: {
                Text("Animated Artwork")
            } footer: {
                Text("Plays the looping video that goes with a cover (from Apple Music or TIDAL) when the song has one; otherwise the normal cover is shown. It uses Wi-Fi unless you allow mobile data, and it turns off in Low Power Mode or with Reduce Motion.")
            }

            Section {
                SettingsToggleRow("AutoMix", icon: "wand.and.stars", isOn: $settings.autoMixEnabled)
                SettingsToggleRow("Mix Streamed Songs on Mobile Data", icon: "antenna.radiowaves.left.and.right", isOn: $settings.autoMixUsesMobileData)
            } header: {
                Text("AutoMix")
            } footer: {
                Text("Blends one song into the next like a DJ: they overlap, the tempo is matched and the bass is swapped. Downloaded songs always mix; streamed songs mix over Wi-Fi, or also on mobile data if you turn that on (it downloads each song's audio an extra time). The Playback Report shows what it did.")
            }

            Section {
                SettingsToggleRow("Autoplay Similar", icon: "infinity", isOn: $settings.autoplaySimilar)
                SettingsToggleRow("Persist Queue", icon: "clock.arrow.circlepath", isOn: $settings.persistQueue)
            } header: {
                Text("Queue")
            } footer: {
                Text("Persist Queue restores your queue, shuffle, and repeat state when the app relaunches.")
            }

            Section {
                SettingsToggleRow("Swipe Artwork to Skip", icon: "hand.draw", isOn: $settings.artworkSwipeNavigation)
            } header: {
                Text("Gestures")
            } footer: {
                Text("Swipe left or right on the artwork in the full player to play the next or previous song.")
            }
        }
        .navigationTitle("Player")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
    }
}
