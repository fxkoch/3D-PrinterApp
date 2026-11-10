import SliceKit
import SwiftUI

/// Colour changes at a height: from there upwards the object is printed with another slot
/// (name plates, key rings, lithophanes …).
struct ColorChangeView: View {
    @Environment(\.dismiss) private var dismiss
    let project: PrintProject
    let objectID: ModelObject.ID
    @State private var changes: [ColorChange] = []

    private var object: ModelObject? { project.allObjects.first { $0.id == objectID } }
    private var filaments: [Filament] { project.settings.filaments }
    private var height: Double { object?.boundingBox.size.z ?? 0 }
    private var layer: Double { max(project.settings.layerHeight, 0.05) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let object {
                        HStack(alignment: .bottom, spacing: 16) {
                            strip(object)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(object.name).font(.headline)
                                Text(String(format: "Höhe %.1f mm", height)).font(.subheadline).foregroundStyle(.secondary)
                                Text("Grundfarbe: Slot \(object.tool + 1)").font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                } footer: {
                    Text("Ab der gewählten Höhe druckt das Objekt mit einem anderen Slot. Beim Kobra S1 (ACE Pro) braucht das den Reinigungsturm, beim U1 wechselt der Druckkopf.")
                }

                Section("Farbwechsel") {
                    ForEach(changes.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(String(format: "ab %.2f mm", changes[i].z)).font(.subheadline.weight(.semibold)).monospacedDigit()
                                Spacer()
                                ForEach(0..<project.settings.machine.toolCount, id: \.self) { tool in
                                    Button { changes[i].tool = tool } label: {
                                        Swatch(color: tool < filaments.count ? filaments[tool].color : "#888888", label: "\(tool + 1)",
                                               selected: changes[i].tool == tool, size: 26)
                                    }
                                    .buttonStyle(.plain)
                                }
                                Button(role: .destructive) { changes.remove(at: i) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                            }
                            Slider(value: Binding(get: { changes[i].z }, set: { changes[i].z = snap($0) }),
                                   in: layer...max(height - layer, layer * 2), step: layer)
                        }
                        .padding(.vertical, 2)
                    }
                    Button {
                        let z = snap(changes.map(\.z).max().map { $0 + (height - $0) / 2 } ?? height / 2)
                        let next = ((changes.last?.tool ?? object?.tool ?? 0) + 1) % max(project.settings.machine.toolCount, 1)
                        changes.append(ColorChange(z: z, tool: next))
                    } label: { Label("Farbwechsel hinzufügen", systemImage: "plus.circle") }
                        .accessibilityIdentifier("addColorChange")
                }
            }
            .navigationTitle("Farbwechsel bei Höhe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { project.setColorChanges(changes, for: objectID); dismiss() }
                        .accessibilityIdentifier("colorChangesDone")
                }
            }
            .onAppear { changes = object?.colorChanges ?? [] }
        }
        .presentationDetents([.medium, .large])
    }

    private func snap(_ z: Double) -> Double { max(layer, (z / layer).rounded() * layer) }

    /// A tall bar showing which slot prints at which height.
    private func strip(_ object: ModelObject) -> some View {
        let sorted = changes.sorted { $0.z < $1.z }
        var segments: [(from: Double, to: Double, tool: Int)] = []
        var start = 0.0, tool = object.tool
        for change in sorted where change.z < height {
            segments.append((start, change.z, tool))
            start = change.z
            tool = change.tool
        }
        segments.append((start, height, tool))
        return VStack(spacing: 0) {
            ForEach(segments.indices.reversed(), id: \.self) { i in
                let s = segments[i]
                Rectangle()
                    .fill(Color(hex: s.tool < filaments.count ? filaments[s.tool].color : "#888888"))
                    .frame(height: max(4, 90 * (s.to - s.from) / max(height, 1)))
            }
        }
        .frame(width: 34)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.4)))
    }
}
