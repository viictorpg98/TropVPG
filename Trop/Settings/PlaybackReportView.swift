//
//  PlaybackReportView.swift
//  Trop
//

import SwiftUI

/// Pantalla con el registro de reproduccion, para copiarlo y mandarlo cuando algo no suena.
struct PlaybackReportView: View {
    @State private var report = PlaybackReport.text
    @State private var previous = DiagLog.shared.previousSessionReport

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
                Text("The summary of this session (screens, network, freezes, CPU, memory, battery) and the latest events. Pull down to refresh.")
            }

            if !report.isEmpty {
                Section {
                    Button("Copy") {
                        UIPasteboard.general.string = report
                    }
                    if let previous, !previous.isEmpty {
                        Button("Copy Previous Session") {
                            UIPasteboard.general.string = previous
                        }
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
