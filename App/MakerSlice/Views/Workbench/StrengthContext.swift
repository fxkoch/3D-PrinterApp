import Foundation
import Observation
import SliceKit

/// What the strength check works on: an object with print settings – either inside a print project or on its own
/// ("Werkstatt", without any slicer involved).
@MainActor
@Observable
final class StrengthContext {
    var object: ModelObject
    var settings: PrintSettings
    /// Only in the workshop: the material is chosen here (in a project it is the filament of the object's slot).
    var materialChoice: FEMMaterial
    let standalone: Bool

    private let fetch: (() -> ModelObject?)?
    private let writeSettings: ((_ walls: Int, _ infill: Double) -> Void)?
    private let writeRotation: ((Transform3D) -> Void)?
    private let writeMesh: ((TriangleMesh) -> Void)?

    /// Inside a print project: changes go straight into the project.
    init(project: PrintProject, objectID: ModelObject.ID) {
        let first = project.allObjects.first { $0.id == objectID } ?? ModelObject(name: "–", mesh: TriangleMesh())
        object = first
        settings = project.settings
        standalone = false
        let slot = first.tool
        let type = project.settings.filaments.indices.contains(slot) ? project.settings.filaments[slot].type : "PLA"
        materialChoice = FEMMaterial.matching(filamentType: type)
        fetch = { [weak project] in project?.allObjects.first { $0.id == objectID } }
        writeSettings = { [weak project] walls, infill in project?.settings.wallLoops = walls; project?.settings.infillDensity = infill }
        writeRotation = { [weak project] t in project?.transform(objectID, t) }
        writeMesh = { [weak project] mesh in project?.replaceMesh(objectID, with: mesh) }
    }

    /// On its own: nothing outside this object changes until it is handed over to a print.
    init(standalone object: ModelObject, settings: PrintSettings) {
        self.object = object
        self.settings = settings
        standalone = true
        materialChoice = FEMMaterial.matching(filamentType: settings.filaments.first?.type ?? "PLA")
        fetch = nil; writeSettings = nil; writeRotation = nil; writeMesh = nil
    }

    var filament: Filament? {
        let slot = standalone ? 0 : object.tool
        return settings.filaments.indices.contains(slot) ? settings.filaments[slot] : settings.filaments.first
    }

    var material: FEMMaterial { standalone ? materialChoice : FEMMaterial.matching(filamentType: filament?.type ?? "PLA") }

    func refresh() {
        if let o = fetch?() { object = o }
    }

    func setPrint(walls: Int, infill: Double) {
        settings.wallLoops = walls
        settings.infillDensity = infill
        writeSettings?(walls, infill)
    }

    func rotate(_ t: Transform3D) {
        if standalone { object = object.transformed(t).placedOnBed(center: (0, 0)) } else { writeRotation?(t); refresh() }
    }

    func replaceMesh(_ mesh: TriangleMesh) {
        if standalone { object.mesh = mesh; object.volumes = [] } else { writeMesh?(mesh); refresh() }
    }
}
