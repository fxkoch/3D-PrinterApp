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
        didSet {
            if settings.printer != oldValue.printer { rearrange(objects) }
            if settings != oldValue { invalidate() }
        }
    }

    enum SliceState {
        case idle
        case slicing(phase: String, fraction: Double)
        case done(SliceJob.Output)
        case failed(String)
    }

    private(set) var state: SliceState = .idle
    private(set) var warning: String?
    private(set) var recommendations: [Recommendation] = []
    private(set) var analyzing = false
    /// Recommendations the user dismissed for this project.
    var dismissed: Set<String> = []

    @ObservationIgnored private var sliceTask: Task<Void, Never>?
    @ObservationIgnored private var adviceTask: Task<Void, Never>?
    @ObservationIgnored var loadedTypes: [String?] = []
    /// Humidity in the ACE Pro dryer, if the printer reports it.
    @ObservationIgnored var dryerHumidity: Double?

    init(name: String, imported: ImportedModel, settings base: PrintSettings) {
        self.name = name
        self.imported = imported
        var s = base
        if let project = imported.projectSettings { s.apply(project) }
        settings = s
        plate = imported.plates.first
        layoutPlate()
        if imported.hasPaintedColors {
            warning = "Das Modell enthält Farbbemalung. Sie wird nicht übernommen – jedes Objekt wird mit einem Slot gedruckt."
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

    var openRecommendations: [Recommendation] {
        recommendations.filter { $0.action != nil && !dismissed.contains($0.id) }
    }

    // MARK: - Editing

    func setTool(_ tool: Int, for objectID: ModelObject.ID) {
        guard let idx = objects.firstIndex(where: { $0.id == objectID }) else { return }
        objects[idx].tool = tool
        changed()
    }

    func remove(_ objectID: ModelObject.ID) {
        objects.removeAll { $0.id == objectID }
        changed()
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
        // Volumes follow the main mesh only for simple objects; lay-flat resets them.
        list[idx].mesh = list[idx].mesh.laidFlat()
        list[idx].volumes = []
        rearrange(list)
    }

    func autoArrange() {
        rearrange(objects)
    }

    /// Replaces an object by the pieces of a cut.
    func cut(_ objectID: ModelObject.ID, options: CutOptions) throws {
        guard let idx = objects.firstIndex(where: { $0.id == objectID }) else { return }
        let parts = try MeshCutter.cut(objects[idx], options)
        var list = objects
        list.remove(at: idx)
        list.insert(contentsOf: parts, at: idx)
        rearrange(list)
    }

    func autoSplit(_ objectID: ModelObject.ID) throws {
        try apply(.autoSplit(objectID: objectID))
    }

    func apply(_ action: Recommendation.Action) throws {
        var s = settings
        var list = objects
        try PrintAdvisor.apply(action, settings: &s, objects: &list)
        objects = list
        settings = s
        if PlateArranger.arrange(objects, bedSize: settings.bedSize) == nil {
            warning = "Die Objekte passen nicht auf das Druckbett."
        }
        changed()
    }

    private func transform(_ objectID: ModelObject.ID, _ t: Transform3D) {
        guard let idx = objects.firstIndex(where: { $0.id == objectID }) else { return }
        var list = objects
        let center = list[idx].boundingBox.center
        let toOrigin = Transform3D.translation(Vec3(-center.x, -center.y, 0))
        list[idx] = list[idx].transformed(toOrigin.then(t))
        rearrange(list)
    }

    private func rearrange(_ list: [ModelObject]) {
        if let arranged = PlateArranger.arrange(list, bedSize: settings.bedSize) {
            objects = arranged
            warning = nil
        } else {
            objects = list
            warning = "Nicht alles passt auf das \(Int(settings.bedSize)) × \(Int(settings.bedSize)) mm Druckbett. Zu große Teile lassen sich über „Teilen“ zerlegen."
        }
        changed()
    }

    private func layoutPlate() {
        let selection = imported.objects.filter { plate == nil || $0.plate == plate || $0.plate == nil }
        // Keep the designer's layout when it fits, otherwise pack the parts.
        if let centered = PlateArranger.recenter(selection, bedSize: settings.bedSize) {
            objects = centered
            warning = nil
            changed()
        } else {
            rearrange(selection)
        }
    }

    private func changed() {
        invalidate()
        refreshRecommendations()
    }

    // MARK: - Advice

    func refreshRecommendations() {
        adviceTask?.cancel()
        let objects = self.objects, settings = self.settings, loaded = loadedTypes, humidity = dryerHumidity
        analyzing = true
        adviceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000) // debounce
            guard !Task.isCancelled else { return }
            let recs = await Task.detached(priority: .utility) {
                PrintAdvisor.recommendations(objects: objects, settings: settings, loadedTypes: loaded,
                                             dryerHumidity: humidity)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.recommendations = recs
            self.analyzing = false
        }
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
                Task { @MainActor in
                    guard let self, case .slicing = self.state else { return }
                    self.state = .slicing(phase: p.phase, fraction: p.fraction)
                }
            }
            let result = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) { () -> Result<SliceJob.Output, Error> in
                    do {
                        return .success(try job.run(isCancelled: { cancelFlag.isSet }, progress: progressHandler))
                    } catch {
                        return .failure(error)
                    }
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
