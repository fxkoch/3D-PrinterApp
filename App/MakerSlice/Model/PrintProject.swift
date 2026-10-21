import Foundation
import Observation
import PrinterKit
import SliceKit

/// One model being prepared for printing: arrangement, settings, slice result.
@MainActor
@Observable
final class PrintProject: Identifiable {
    let id = UUID()
    let name: String
    let imported: ImportedModel

    /// Objects per plate (index 0 = plate 1). Every plate is arranged on the bed.
    private(set) var plates: [[ModelObject]] = [[]]
    /// The plate shown, sliced and printed.
    var currentPlate = 1 {
        didSet {
            if currentPlate != oldValue { refreshRecommendations() }
        }
    }
    var plateCount: Int { plates.count }
    /// Objects on the current plate.
    var objects: [ModelObject] { plates[min(max(currentPlate, 1), plates.count) - 1] }
    var allObjects: [ModelObject] { plates.flatMap { $0 } }
    var settings: PrintSettings {
        didSet {
            if settings.printer != oldValue.printer { redistributeAll() }
            if settings != oldValue { invalidate() }
        }
    }

    enum SliceState {
        case idle
        case slicing(phase: String, fraction: Double)
        case done(SliceJob.Output)
        case failed(String)
    }

    private var plateStates: [Int: SliceState] = [:]
    /// Slice state of the current plate.
    var state: SliceState { plateStates[currentPlate] ?? .idle }
    func state(ofPlate plate: Int) -> SliceState { plateStates[plate] ?? .idle }
    private(set) var warning: String?
    private(set) var recommendations: [Recommendation] = []
    private(set) var analyzing = false
    /// Recommendations the user dismissed for this project.
    var dismissed: Set<String> = []

    /// Colours the downloaded model uses, as defined in its file.
    var modelColors: [ModelColor] { imported.modelColors }
    /// File colour → printer slot.
    private(set) var colorMap: [Int: Int] = [:]
    /// True until the user has chosen filaments for a multi-colour model.
    var needsColorSetup = false

    /// Set when this project is a calibration print (fixed settings, built-in slicer only).
    var calibration: CalibrationPlan?

    /// What is special in the profile the downloaded model brings along; shown to the user before anything is taken over.
    private(set) var profileReport: ProfileReport?

    @ObservationIgnored private var sliceTasks: [Int: Task<Void, Never>] = [:]
    /// Plates still waiting while "alle Platten slicen" runs.
    @ObservationIgnored private var sliceQueue: [Int] = []
    @ObservationIgnored private var queueCloud: CloudSliceConfig?
    @ObservationIgnored private var adviceTask: Task<Void, Never>?
    @ObservationIgnored var loadedTypes: [String?] = []
    /// Humidity in the ACE Pro dryer, if the printer reports it.
    @ObservationIgnored var dryerHumidity: Double?

    init(name: String, imported: ImportedModel, settings base: PrintSettings) {
        self.name = name
        self.imported = imported
        var s = base
        if let project = imported.projectSettings {
            s.applyMaterials(project)
            let report = ProfileAdvisor.analyze(project: project, settings: s)
            if !report.isEmpty { profileReport = report }
        }
        settings = s
        layoutImported()
        if imported.isMultiColor {
            // Multi-colour model: keep the file's numbering where possible and ask which filament prints which colour.
            let map = ColorMapper.suggest(colors: imported.modelColors, slotColors: s.filaments.map(\.color))
            applyColorMap(map)
            needsColorSetup = true
        }
        if imported.hasPaintedColors {
            warning = "Das Modell enthält Farbbemalung. Sie wird nicht übernommen – jedes Objekt wird mit einem Slot gedruckt."
        }
    }

    /// Takes over the chosen differences of the model's profile.
    func applyProfile(_ changes: [ProfileChange]) {
        settings = ProfileAdvisor.apply(changes, to: settings)
        profileReport = nil
    }

    func dismissProfile() { profileReport = nil }

    var output: SliceJob.Output? { output(ofPlate: currentPlate) }

    func output(ofPlate plate: Int) -> SliceJob.Output? {
        if case .done(let o) = state(ofPlate: plate) { return o }
        return nil
    }

    var isSlicing: Bool {
        plateStates.values.contains { if case .slicing = $0 { return true } else { return false } }
    }

    /// Plates that hold at least one object.
    var filledPlates: [Int] { plates.indices.filter { !plates[$0].isEmpty }.map { $0 + 1 } }

    var usedTools: [Int] {
        Array(objects.reduce(into: Set<Int>()) { $0.formUnion($1.allTools) }).sorted()
    }

    /// True when the plate prints in more than one colour (several objects, parts or colour changes).
    var isMultiColor: Bool { usedTools.count > 1 }

    var openRecommendations: [Recommendation] {
        recommendations.filter { $0.action != nil && !dismissed.contains($0.id) }
    }

    // MARK: - Editing

    private func locate(_ id: ModelObject.ID) -> (plate: Int, index: Int)? {
        for (p, list) in plates.enumerated() {
            if let i = list.firstIndex(where: { $0.id == id }) { return (p, i) }
        }
        return nil
    }

    func setTool(_ tool: Int, for objectID: ModelObject.ID) {
        guard let loc = locate(objectID) else { return }
        plates[loc.plate][loc.index].tool = tool
        changed(plate: loc.plate + 1)
    }

    /// Assigns the file's colours to printer slots and moves every object/part to its slot.
    func applyColorMap(_ map: [Int: Int]) {
        colorMap = map
        for p in plates.indices {
            for i in plates[p].indices { plates[p][i] = plates[p][i].applyingColorMap(map) }
        }
        changed()
    }

    /// Prints a file colour with a slot and loads the matching material profile (type of the file, colour of the file).
    func assign(color: ModelColor, toSlot slot: Int) {
        var map = colorMap
        map[color.tool] = slot
        applyColorMap(map)
        guard settings.filaments.indices.contains(slot) else { return }
        if let type = color.type, var f = FilamentLibrary.bestMatch(type: type, vendor: color.vendor, printer: settings.printer) {
            f.color = color.colorHex
            settings.filaments[slot] = f
        } else {
            settings.filaments[slot].color = color.colorHex
        }
    }

    func finishColorSetup() { needsColorSetup = false }
    func reopenColorSetup() { needsColorSetup = true }

    /// Height-based colour changes of an object (sorted, one per height).
    func setColorChanges(_ changes: [ColorChange], for objectID: ModelObject.ID) {
        guard let loc = locate(objectID) else { return }
        var seen = Set<Double>()
        plates[loc.plate][loc.index].colorChanges = changes.sorted { $0.z < $1.z }.filter { seen.insert($0.z).inserted }
        changed(plate: loc.plate + 1)
    }

    /// Slot of a coloured part (multi-colour 3MF).
    func setPartTool(_ tool: Int, part: Int, for objectID: ModelObject.ID) {
        guard let loc = locate(objectID), plates[loc.plate][loc.index].parts.indices.contains(part) else { return }
        plates[loc.plate][loc.index].parts[part].tool = tool
        changed(plate: loc.plate + 1)
    }

    func remove(_ objectID: ModelObject.ID) {
        guard let loc = locate(objectID) else { return }
        plates[loc.plate].remove(at: loc.index)
        changed(plate: loc.plate + 1)
    }

    func duplicate(_ objectID: ModelObject.ID) {
        guard let loc = locate(objectID) else { return }
        var copy = plates[loc.plate][loc.index]
        copy.id = UUID()
        put([copy], preferred: loc.plate)
    }

    func rotate(_ objectID: ModelObject.ID, degrees: Double) {
        transform(objectID, .rotationZ(degrees * .pi / 180))
    }

    func scale(_ objectID: ModelObject.ID, factor: Double) {
        transform(objectID, .scale(Vec3(factor, factor, factor)))
    }

    func layFlat(_ objectID: ModelObject.ID) {
        guard let loc = locate(objectID) else { return }
        var list = plates[loc.plate]
        // Volumes follow the main mesh only for simple objects; lay-flat resets them.
        list[loc.index].mesh = list[loc.index].mesh.laidFlat()
        list[loc.index].volumes = []
        rearrangePlate(loc.plate, list)
    }

    /// Arranges the current plate again; what no longer fits moves to the next plates.
    func autoArrange() {
        rearrangePlate(currentPlate - 1, objects)
    }

    /// Distributes all objects over as few plates as possible.
    func redistributeAll() {
        let all = allObjects.map { o -> ModelObject in var c = o; c.plate = nil; return c }
        let layout = PlateArranger.distribute(all, bedSize: settings.bedSize)
        plates = layout.plates.isEmpty ? [[]] : layout.plates
        if !layout.unplaceable.isEmpty { plates[0] += layout.unplaceable.map { var o = $0; o.plate = 1; return o } }
        warning = layout.unplaceable.isEmpty ? nil : tooLargeWarning
        currentPlate = min(currentPlate, plates.count)
        changed()
    }

    /// Adds new objects: each goes to the plate where it fits best (the current one first), new plates are created when needed.
    func addObjects(_ new: [ModelObject]) {
        put(new, preferred: currentPlate - 1)
        if let first = new.first, let loc = locate(first.id) { currentPlate = loc.plate + 1 }
    }

    func addImported(_ model: ImportedModel) {
        addObjects(model.objects)
    }

    /// Replaces an object by the pieces of a cut. Pieces that no longer fit next to the others move to other plates.
    func cut(_ objectID: ModelObject.ID, options: CutOptions) throws {
        guard let loc = locate(objectID) else { return }
        let parts = try MeshCutter.cut(plates[loc.plate][loc.index], options)
        plates[loc.plate].remove(at: loc.index)
        put(parts, preferred: loc.plate)
    }

    func autoSplit(_ objectID: ModelObject.ID) throws {
        try apply(.autoSplit(objectID: objectID))
    }

    func apply(_ action: Recommendation.Action) throws {
        var s = settings
        var list = objects
        try PrintAdvisor.apply(action, settings: &s, objects: &list)
        settings = s
        rearrangePlate(currentPlate - 1, list)
    }

    // MARK: Plates

    func addPlate() {
        plates.append([])
        currentPlate = plates.count
    }

    /// Only empty plates can be removed (move or delete the objects first).
    func removePlate(_ plate: Int) {
        guard plates.count > 1, plates.indices.contains(plate - 1), plates[plate - 1].isEmpty else { return }
        plates.remove(at: plate - 1)
        plateStates = Dictionary(uniqueKeysWithValues: plateStates.compactMap { key, value in
            key == plate ? nil : (key > plate ? (key - 1, value) : (key, value))
        })
        for i in plates.indices { for j in plates[i].indices { plates[i][j].plate = i + 1 } }
        currentPlate = min(currentPlate, plates.count)
        changed()
    }

    /// Moves an object to another plate (if it fits there).
    func move(_ objectID: ModelObject.ID, toPlate target: Int) {
        guard let loc = locate(objectID), plates.indices.contains(target - 1), loc.plate != target - 1 else { return }
        var object = plates[loc.plate][loc.index]
        guard let arranged = PlateArranger.arrangeFitting(plates[target - 1] + [object], bedSize: settings.bedSize) else {
            warning = "Das Objekt passt nicht mehr auf Platte \(target)."
            return
        }
        plates[loc.plate].remove(at: loc.index)
        object.plate = target
        plates[target - 1] = arranged.map { var o = $0; o.plate = target; return o }
        warning = nil
        changed()
    }

    private var tooLargeWarning: String {
        "Ein Teil ist größer als das \(Int(settings.bedSize)) × \(Int(settings.bedSize)) mm Druckbett. Zu große Teile lassen sich über „Teilen“ zerlegen."
    }

    /// Puts objects onto plates (first fit, biggest first) and arranges the plates concerned.
    private func put(_ new: [ModelObject], preferred: Int) {
        let layout = PlateArranger.place(new, into: plates, bedSize: settings.bedSize, preferred: preferred)
        plates = layout.plates
        if !layout.unplaceable.isEmpty {
            let target = min(max(preferred, 0), plates.count - 1)
            plates[target] += layout.unplaceable.map { var o = $0; o.plate = target + 1; return o }
            warning = tooLargeWarning
        } else {
            warning = nil
        }
        changed()
    }

    private func rearrangePlate(_ index: Int, _ list: [ModelObject]) {
        plates[index] = []
        put(list, preferred: index)
    }

    private func transform(_ objectID: ModelObject.ID, _ t: Transform3D) {
        guard let loc = locate(objectID) else { return }
        var list = plates[loc.plate]
        let center = list[loc.index].boundingBox.center
        let toOrigin = Transform3D.translation(Vec3(-center.x, -center.y, 0))
        list[loc.index] = list[loc.index].transformed(toOrigin.then(t))
        rearrangePlate(loc.plate, list)
    }

    /// Initial layout: the designer's plates of a project file; layouts that fit are kept (recentred),
    /// everything else is packed.
    private func layoutImported() {
        let groups = Dictionary(grouping: imported.objects) { $0.plate ?? 1 }
        var overflow: [ModelObject] = []
        var result: [[ModelObject]] = []
        for key in groups.keys.sorted() {
            let group = groups[key] ?? []
            if !PlateArranger.hasOverlap(group), let centered = PlateArranger.recenter(group, bedSize: settings.bedSize) {
                result.append(centered)
            } else {
                overflow += group
            }
        }
        plates = result.isEmpty ? [[]] : result
        for i in plates.indices { for j in plates[i].indices { plates[i][j].plate = i + 1 } }
        currentPlate = 1
        if !overflow.isEmpty { put(overflow, preferred: 0) } else { warning = nil }
        if imported.hasPaintedColors {
            warning = "Das Modell enthält Farbbemalung. Sie wird nicht übernommen – jedes Objekt wird mit einem Slot gedruckt."
        }
    }

    private func changed(plate: Int? = nil) {
        invalidate(plate: plate)
        refreshRecommendations()
    }

    // MARK: - Advice

    func refreshRecommendations() {
        adviceTask?.cancel()
        // Calibration prints must not be changed by recommendations (supports, ironing, …).
        if calibration != nil { recommendations = []; analyzing = false; return }
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

    /// Forgets slice results: of one plate, or of all.
    private func invalidate(plate: Int? = nil) {
        if let plate {
            sliceTasks[plate]?.cancel()
            sliceTasks[plate] = nil
            plateStates[plate] = nil
        } else {
            sliceTasks.values.forEach { $0.cancel() }
            sliceTasks = [:]
            plateStates = [:]
            sliceQueue = []
        }
    }

    /// Slices the current plate on the iPhone, or with OrcaSlicer on GitHub when `cloud` is given.
    func slice(cloud: CloudSliceConfig? = nil) {
        slice(plate: currentPlate, cloud: cloud)
    }

    /// Slices every plate that holds objects, one after the other.
    func sliceAll(cloud: CloudSliceConfig? = nil) {
        var queue = filledPlates
        guard let first = queue.first else { return }
        queue.removeFirst()
        sliceQueue = queue
        queueCloud = cloud
        slice(plate: first, cloud: cloud)
    }

    private func finishPlate() {
        guard !sliceQueue.isEmpty else { return }
        let next = sliceQueue.removeFirst()
        slice(plate: next, cloud: queueCloud)
    }

    private func slice(plate: Int, cloud: CloudSliceConfig?) {
        // Colour changes at a height and painted surfaces are only known to the built-in slicer.
        let needsLocal = calibration != nil || plates[plate - 1].contains { !$0.colorChanges.isEmpty || !$0.paint.isEmpty }
        if needsLocal, cloud?.isComplete == true {
            warning = "Farbwechsel bei Höhe und bemalte Flächen kennt nur der Slicer auf dem iPhone – dieser Druck wird deshalb nicht in der Cloud geslict."
        }
        if let cloud, cloud.isComplete, !needsLocal {
            sliceInCloud(plate: plate, cloud)
            return
        }
        sliceTasks[plate]?.cancel()
        let job = SliceJob(name: plateName(plate), objects: plates[plate - 1], settings: settings)
        plateStates[plate] = .slicing(phase: "Vorbereiten", fraction: 0)
        let cancelFlag = CancelFlag()
        sliceTasks[plate] = Task { [weak self] in
            let progressHandler: @Sendable (SliceProgress) -> Void = { p in
                Task { @MainActor in
                    guard let self, case .slicing = self.state(ofPlate: plate) else { return }
                    self.plateStates[plate] = .slicing(phase: p.phase, fraction: p.fraction)
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
            case .success(let output): self.plateStates[plate] = .done(output)
            case .failure(let error as SliceError) where error == .cancelled: self.plateStates[plate] = nil
            case .failure(let error): self.plateStates[plate] = .failed(error.localizedDescription); self.sliceQueue = []
            }
            self.finishPlate()
        }
    }

    private func sliceInCloud(plate: Int, _ config: CloudSliceConfig) {
        sliceTasks[plate]?.cancel()
        let objects = plates[plate - 1], settings = self.settings, name = plateName(plate)
        plateStates[plate] = .slicing(phase: "Cloud-Auftrag vorbereiten …", fraction: 0.02)
        sliceTasks[plate] = Task { [weak self] in
            do {
                let job = try await Task.detached { try OrcaJob(objects: objects, settings: settings, name: name) }.value
                let client = CloudSliceClient(config: config)
                let started = Date()
                let result = try await client.slice(
                    jobID: job.id,
                    files: [("job.json", job.manifest), (OrcaJob.modelFileName, job.model)]
                ) { phase in
                    Task { @MainActor in
                        guard let self, case .slicing = self.state(ofPlate: plate) else { return }
                        // GitHub reports no percentage; show elapsed time on a slowly filling bar.
                        let elapsed = Date().timeIntervalSince(started)
                        self.plateStates[plate] = .slicing(phase: "\(phase.description) \(Int(elapsed)) s", fraction: min(0.95, 0.05 + elapsed / 300))
                    }
                }
                let gcode = String(decoding: result.gcode, as: UTF8.self)
                let parsed = await Task.detached { GCodePreview.parse(gcode) }.value
                var estimate = parsed.estimate
                if let seconds = result.seconds, estimate.seconds == 0 { estimate.seconds = seconds }
                guard let self, !Task.isCancelled else { return }
                self.plateStates[plate] = .done(SliceJob.Output(layers: parsed.layers, gcode: gcode, estimate: estimate,
                                                                engine: "OrcaSlicer (Cloud)"))
                self.finishPlate()
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.plateStates[plate] = .failed(error.localizedDescription)
                self.sliceQueue = []
            }
        }
    }

    func cancelSlicing() {
        sliceQueue = []
        invalidate(plate: currentPlate)
    }

    private func plateName(_ plate: Int) -> String {
        plates.count > 1 ? "\(name)_Platte\(plate)" : name
    }

    /// File name used on the printer.
    var gcodeFileName: String {
        let base = plateName(currentPlate).replacingOccurrences(of: "/", with: "_")
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
