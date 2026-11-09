//
//  MixFeedback.swift
//  Trop
//
//  Tras cada mezcla de AutoMix, un aviso discreto para valorarla (bien / mal). Cada mezcla se guarda con sus datos y la
//  valoracion, para poder ajustar despues los umbrales (duracion, diferencia de tempo...) con lo que de verdad te gusta.
//

import Foundation
import Observation
import SwiftUI

struct MixRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var outId: String
    var inId: String
    var durationSeconds: Double
    var outgoingBpm: Double
    var incomingBpm: Double
    var outgoingRatio: Double
    var incomingRatio: Double
    /// 1 = bien, -1 = mal, 0 = sin valorar.
    var rating = 0
    /// El estilo de mezcla con que se hizo (para que el aprendizaje sepa de que se trata la valoracion).
    var arm: String?
}

@MainActor
@Observable
final class MixFeedbackStore {
    static let shared = MixFeedbackStore()

    /// La mezcla que acaba de sonar y aun se puede valorar.
    private(set) var pending: MixRecord?
    /// Se acaba de valorar: se enseña un "gracias" un momento.
    private(set) var thanks = false

    @ObservationIgnored private var records: [MixRecord] = []
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private static let key = "automix.feedback.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([MixRecord].self, from: data) {
            records = saved
        }
    }

    /// Una mezcla acaba de terminar: se guarda y se ofrece valorarla unos segundos.
    func mixFinished(outId: String, inId: String, plan: TransitionPlan) {
        let store = TrackAnalysisStore.shared
        let record = MixRecord(
            outId: outId, inId: inId,
            durationSeconds: Double(plan.durationMs) / 1000,
            outgoingBpm: store.structure(for: outId)?.bpm ?? 0,
            incomingBpm: store.structure(for: inId)?.bpm ?? 0,
            outgoingRatio: plan.outgoingSpeedRatio, incomingRatio: plan.incomingSpeedRatio,
            arm: plan.styleKey
        )
        records.append(record)
        if records.count > 300 { records.removeFirst(records.count - 300) }
        persist()
        thanks = false
        pending = record
        schedule(after: 10)
    }

    func rate(_ value: Int) {
        guard let current = pending, !thanks else { return }
        if let index = records.firstIndex(where: { $0.id == current.id }) {
            records[index].rating = value
            persist()
        }
        PlaybackReport.record(String(
            format: "automix: valoracion de la mezcla %@ -> %@: %@ (%.0f s, %.0f -> %.0f BPM)",
            current.outId, current.inId, value > 0 ? "bien" : "mal",
            current.durationSeconds, current.outgoingBpm, current.incomingBpm
        ))
        // Solo cuenta la valoracion explicita: el aprendizaje de AutoMix se ajusta con ella.
        if let arm = current.arm {
            MixLearning.shared.record(arm: arm, outId: current.outId, inId: current.inId, rating: value)
        }
        thanks = true
        schedule(after: 1.4)
    }

    private func schedule(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.pending = nil
            self?.thanks = false
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Aviso para valorar la mezcla que acaba de sonar (ocupa el sitio de la linea de la letra).
struct MixFeedbackPill: View {
    private let store = MixFeedbackStore.shared

    var body: some View {
        HStack(spacing: 14) {
            if store.thanks {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                Text("Thanks!")
                    .font(.caption.weight(.semibold))
            } else {
                Text("How was the mix?")
                    .font(.caption.weight(.semibold))
                Button { store.rate(1) } label: {
                    Image(systemName: "hand.thumbsup.fill")
                        .font(.system(size: 15))
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Good mix")
                Button { store.rate(-1) } label: {
                    Image(systemName: "hand.thumbsdown.fill")
                        .font(.system(size: 15))
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Bad mix")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
