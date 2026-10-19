import SliceKit
import SwiftUI

/// Split an object into parts that fit the printer, with plug-in connectors.
struct CutView: View {
    @Environment(\.dismiss) private var dismiss
    let project: PrintProject
    let object: ModelObject

    @State private var axis: CutAxis = .z
    @State private var fraction = 0.5
    @State private var connector: ConnectorStyle = .pegs
    @State private var count = 0
    @State private var diameter = 6.0
    @State private var depth = 6.0
    @State private var error: String?

    private var box: BoundingBox { object.boundingBox }

    private var range: (lo: Double, hi: Double) {
        switch axis {
        case .x: return (box.min.x, box.max.x)
        case .y: return (box.min.y, box.max.y)
        case .z: return (box.min.z, box.max.z)
        }
    }

    private var position: Double { range.lo + (range.hi - range.lo) * fraction }

    private var tooBig: Bool {
        let s = box.size
        return s.x > project.settings.bedSize || s.y > project.settings.bedSize || s.z > project.settings.maxHeight
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ModelSceneView(objects: [object], filaments: project.settings.filaments, bedSize: project.settings.bedSize,
                                   cutPlane: (axis, position))
                        .frame(height: 240)
                        .listRowInsets(EdgeInsets())
                }
                if tooBig {
                    Section {
                        Button {
                            run { try project.autoSplit(object.id) }
                        } label: {
                            Label("Automatisch passend teilen", systemImage: "wand.and.stars")
                        }
                        Text("Schneidet so oft wie nötig, damit jedes Teil auf das Druckbett passt, und setzt Dübel an die Schnittflächen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Schnitt") {
                    Picker("Richtung", selection: $axis) {
                        ForEach(CutAxis.allCases) { Text($0.displayName).tag($0) }
                    }
                    .onChange(of: axis) { _, new in
                        if new != .z, connector == .pegs { connector = .dowels }
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Position", value: String(format: "%.1f mm", position - range.lo))
                        Slider(value: $fraction, in: 0.05...0.95)
                    }
                }
                Section {
                    Picker("Verbinder", selection: $connector) {
                        ForEach(ConnectorStyle.allCases) { Text($0.displayName).tag($0) }
                    }
                    if connector != .none {
                        Stepper(value: $count, in: 0...6) {
                            LabeledContent("Anzahl", value: count == 0 ? "Automatisch" : "\(count)")
                        }
                        Stepper(value: $diameter, in: 3...15, step: 1) {
                            LabeledContent("Durchmesser", value: "\(Int(diameter)) mm")
                        }
                        Stepper(value: $depth, in: 3...20, step: 1) {
                            LabeledContent("Tiefe", value: "\(Int(depth)) mm")
                        }
                    }
                } header: {
                    Text("Verbinder")
                } footer: {
                    Text(connector.explanation + " Spiel: 0,2 mm pro Seite.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("„\(object.name)“ teilen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Teilen") {
                        var options = CutOptions(axis: axis, position: position, connector: connector)
                        options.connectorCount = count
                        options.connectorDiameter = diameter
                        options.connectorDepth = depth
                        run { try project.cut(object.id, options: options) }
                    }
                    .accessibilityIdentifier("confirmCut")
                }
            }
            .onAppear {
                if tooBig {
                    let s = box.size
                    axis = s.x >= s.y && s.x >= s.z ? .x : s.y >= s.z ? .y : .z
                    connector = axis == .z ? .pegs : .dowels
                }
            }
        }
    }

    private func run(_ work: () throws -> Void) {
        do {
            try work()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
