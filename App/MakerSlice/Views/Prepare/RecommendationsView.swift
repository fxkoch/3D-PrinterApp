import SliceKit
import SwiftUI

/// List of print recommendations. Before printing, the user picks which to apply.
struct RecommendationsView: View {
    enum Mode {
        case review
        /// Called with `true` when settings changed (re-slice needed), `false` to print as is.
        case beforePrint((Bool) -> Void)
    }

    @Environment(\.dismiss) private var dismiss
    let project: PrintProject
    let mode: Mode
    @State private var chosen: Set<String> = []
    @State private var error: String?

    private var actionable: [Recommendation] { project.recommendations.filter { $0.action != nil && !project.dismissed.contains($0.id) } }
    private var infos: [Recommendation] { project.recommendations.filter { $0.action == nil } }

    var body: some View {
        NavigationStack {
            List {
                if case .beforePrint = mode {
                    Section {
                        Text("Vor dem Start: Diese Änderungen machen den Druck sicherer oder schöner. Ausgewählte Punkte werden übernommen und das Modell neu geslicet.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
                if !actionable.isEmpty {
                    Section("Empfohlen") {
                        ForEach(actionable) { rec in
                            Button {
                                if chosen.contains(rec.id) { chosen.remove(rec.id) } else { chosen.insert(rec.id) }
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: chosen.contains(rec.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(chosen.contains(rec.id) ? Color.accentColor : .secondary)
                                        .font(.title3)
                                    RecommendationText(recommendation: rec)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !infos.isEmpty {
                    Section("Hinweise") {
                        ForEach(infos) { RecommendationText(recommendation: $0) }
                    }
                }
            }
            .navigationTitle("Empfehlungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        applyChosen()
                    } label: {
                        Text(primaryTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(chosen.isEmpty && !isBeforePrint)
                    .accessibilityIdentifier("applyRecommendations")
                    if case .beforePrint(let done) = mode {
                        Button("Ohne Änderungen drucken") {
                            dismiss()
                            done(false)
                        }
                    }
                }
                .padding()
                .background(.bar)
            }
            .onAppear { chosen = Set(actionable.filter { $0.severity >= .suggestion }.map(\.id)) }
        }
    }

    private var isBeforePrint: Bool {
        if case .beforePrint = mode { return true }
        return false
    }

    private var primaryTitle: String {
        if isBeforePrint {
            return chosen.isEmpty ? "Drucken" : "\(chosen.count) übernehmen & drucken"
        }
        return chosen.isEmpty ? "Übernehmen" : "\(chosen.count) übernehmen"
    }

    private func applyChosen() {
        do {
            for rec in actionable where chosen.contains(rec.id) {
                if let action = rec.action { try project.apply(action) }
            }
            for rec in actionable where !chosen.contains(rec.id) { project.dismissed.insert(rec.id) }
            dismiss()
            if case .beforePrint(let done) = mode { done(!chosen.isEmpty) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct RecommendationText: View {
    let recommendation: Recommendation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: recommendation.icon)
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(recommendation.title).font(.subheadline.weight(.semibold))
                Text(recommendation.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        switch recommendation.severity {
        case .warning: return .orange
        case .suggestion: return .accentColor
        case .info: return .secondary
        }
    }
}

/// Compact row with apply / dismiss buttons for the prepare screen.
struct RecommendationRow: View {
    let recommendation: Recommendation
    var compact = false
    let apply: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RecommendationText(recommendation: recommendation)
            HStack {
                Spacer()
                Button("Ignorieren", action: dismiss).font(.caption).buttonStyle(.borderless)
                Button("Übernehmen", action: apply).font(.caption.weight(.semibold)).buttonStyle(.bordered)
            }
        }
    }
}
