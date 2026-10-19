import Foundation
import Observation
import SliceKit

/// One model being prepared for printing: arrangement, settings, slice result.
@MainActor
@Observable
final class PrintProject: Identifiable {
    let id = UUID()
    let name: String
    let imported: ImportedModel

    var plate: Int? {
        didSet { if plate != oldValue { layoutPlate() } }
    }
    private(set) var objects: [ModelObject] = []
    var settings: PrintSettings {
        didSet { if settings != oldValue { invalidate() } }
    }

    enum SliceState {
        case idle
        case slicing(phase: String, fraction: Double)
        case done(SliceJob.Output)
        case failed(String)
    }

    private(set) var state: SliceState = .idle
    private(set) var warning: String?
    private var sliceTask: Task<Void, Never>?

    init(name: String, imported: ImportedModel, settings base: PrintSettings) {
        self.name = name
        self.imported = imported
        var s = base
        if let project = imported.projectSettings { s.apply(project) }
        settings = s
        plate = imported.plates.first
        layoutPlate()
        if imported.hasPaintedColors {
            warning = "Das Modell enthält Farbbemalung. Sie wird nicht übernommen – jedes Objekt wird mit einem Druckkopf gedruckt."
        }
    }

    var output: SliceJob.Output? {
        if case .done(let o) = state { return o }
        return nil
    }

    var isSlicing: Bool {
        if case .slicing = state { return true }
        return false
    }

    var usedTools: [Int] {
        Array(Set(objects.map(\.tool))).sorted()
    }

    // MARK: - Editing

    func setTool(_ tool: Int, for objectID: ModelObject.ID) {
        guard let idx = objects.firstIndex(where: { $0.id == objectID }) else { return }
        objects[idx].tool = tool
        invalidate()
    }

    func remove(_ objectID: ModelObject.ID) {
        objects.removeAll { $0.id == objectID }
        invalidate()
    }

    func duplicate(_ objectID: ModelObject.ID) {
        guard let obj = objects.first(where: { $0.id == objectID }) else { return }
        var copy = obj
        copy.id = UUID()
        rearrange(objects + [copy])
    }

    func rotate(_ objectID: ModelObject.ID, degrees: Double) {
        transform(objectID, .rotationZ(degrees * .pi / 180))
    }

    func scale(_ objectID: ModelObject.ID, factor: Double) {
        transform(objectID, .scale(Vec3(factor, factor, factor)))
    }

    func layFlat(_ objectID: ModelObject.ID) {
        guard let idx = objects.firstIndex(where: { $0.id == objectID }) else { return }
        var list = objects
        list[idx].mesh = list[idx].mesh.laidFlat()
        rearrange(list)
    }

    func autoArrange() {
        rearrange(objects)
    }

    private func transform(_ objectID: ModelObject.ID, _ t: Transform3D) {
        guard let idx = objects.firstIndex(where: { $0.id == objectID }) else { return }
        var list = objects
        let center = list[idx].mesh.boundingBox.center
        let toOrigin = Transform3D.translation(Vec3(-center.x, -center.y, 0))
        list[idx].mesh = list[idx].mesh.transformed(toOrigin.then(t))
        rearrange(list)
    }

    private func rearrange(_ list: [ModelObject]) {
        if let arranged = PlateArranger.arrange(list, bedSize: settings.bedSize) {
            objects = arranged
            warning = nil
        } else {
            objects = list
            warning = "Die Objekte passen nicht auf das 270 × 270 mm Druckbett."
        }
        invalidate()
    }

    private func layoutPlate() {
        let selection = imported.objects.filter { plate == nil || $0.plate == plate || $0.plate == nil }
        // Keep the designer's layout when it fits, otherwise pack the parts.
        if let centered = PlateArranger.recenter(selection, bedSize: settings.bedSize) {
            objects = centered
            warning = nil
        } else {
            rearrange(selection)
            return
        }
        invalidate()
    }

    // MARK: - Slicing

    private func invalidate() {
        sliceTask?.cancel()
        sliceTask = nil
        state = .idle
    }

    func slice() {
        sliceTask?.cancel()
        let job = SliceJob(name: name, objects: objects, settings: settings)
        state = .slicing(phase: "Vorbereiten", fraction: 0)
        let cancelFlag = CancelFlag()
        sliceTask = Task { [weak self] in
            let progressHandler: @Sendable (SliceProgress) -> Void = { p in
                Task { @MainActor [weak self] in
                    guard let self, case .slicing = self.state else { return }
                    self.state = .slicing(phase: p.phase, fraction: p.fraction)
                }
            }
            let result = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    Result { try job.run(isCancelled: { cancelFlag.isSet }, progress: progressHandler) }
                }.value
            } onCancel: {
                cancelFlag.set()
            }
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let output): self.state = .done(output)
            case .failure(let error as SliceError) where error == .cancelled: self.state = .idle
            case .failure(let error): self.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSlicing() {
        invalidate()
    }

    /// File name used on the printer.
    var gcodeFileName: String {
        let base = name.replacingOccurrences(of: "/", with: "_")
        return "\(base)_\(String(format: "%.2f", settings.layerHeight))mm.gcode"
    }
}

/// Thread-safe cancellation flag shared with the slicer thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
