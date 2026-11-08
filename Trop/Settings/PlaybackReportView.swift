//
//  PlaybackReportView.swift
//  Trop
//

import SwiftUI

/// Pantalla con el registro de reproduccion, para copiarlo y mandarlo cuando algo no suena.
struct PlaybackReportView: View {
    @State private var report = PlaybackReport.text

    var body: some View {
        List {
            Section {
                if report.isEmpty {
                    Text("No playback has been recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(report)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            } footer: {
                Text("Shows the latest steps when playing something: which client got the stream and what the player said.")
            }

            if !report.isEmpty {
                Section {
                    Button("Copy") {
                        UIPasteboard.general.string = report
                    }
                    Button("Clear", role: .destructive) {
                        PlaybackReport.clear()
                        report = ""
                    }
                }
            }
        }
        .navigationTitle("Playback Report")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { report = PlaybackReport.text }
        .miniPlayerTracksScroll()
    }
}
