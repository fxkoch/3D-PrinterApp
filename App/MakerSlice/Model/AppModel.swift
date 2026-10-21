import Foundation
import MakerWorldKit
import Observation
import PrinterKit
import SliceKit
import SwiftUI

enum AppTab: Hashable {
    case discover, library, printers, settings
}

@MainActor
@Observable
final class AppModel {
    let library = Library()
    let printers = PrinterManager()
    let log = EventLog()
    /// Kept for the app's lifetime so the MakerWorld page and login survive tab switches.
    let browser = MakerWorldBrowser()

    var tab: AppTab = .discover
    /// Project shown in the "prepare & slice" screen.
    var project: PrintProject?
    var isLoadingModel = false
    var loadingMessage = "Modell wird geladen …"
    var alert: String?

    enum SendState: Equatable {
        case idle, uploading, done, failed(String)
    }

    var sendState: SendState = .idle

    /// Shows advanced settings everywhere.
    /// Cloud slicing with OrcaSlicer on GitHub Actions.
    var cloud: CloudSliceConfig = CloudStore.load() {
        didSet { if cloud != oldValue { CloudStore.save(cloud) } }
    }
    /// Slice with OrcaSlicer in the cloud instead of on the iPhone.
    var useCloudSlicer: Bool = UserDefaults.standard.bool(forKey: "useCloudSlicer") {
        didSet { UserDefaults.standard.set(useCloudSlicer, forKey: "useCloudSlicer") }
    }

    var expertMode: Bool {
        didSet { UserDefaults.standard.set(expertMode, forKey: "expertMode") }
    }

    /// Settings the user last used per printer model; new projects start from these.
    @ObservationIgnored private var savedSettings: [PrinterModel: PrintSettings] = [:]

    init() {
        // UI tests start without settings remembered by an earlier test run.
        if ProcessInfo.processInfo.arguments.contains("-uiTestReset") {
            for model in PrinterModel.allCases { UserDefaults.standard.removeObject(forKey: "settings-\(model.rawValue)") }
        }
        expertMode = UserDefaults.standard.bool(forKey: "expertMode")
        for model in PrinterModel.allCases {
            if let data = UserDefaults.standard.data(forKey: "settings-\(model.rawValue)"),
               let saved = try? JSONDecoder().decode(PrintSettings.self, from: data), saved.printer == model {
                savedSettings[model] = saved
            }
        }
        printers.log = log
        browser.log = log
        // UI tests start without printers saved by an earlier test run.
        if ProcessInfo.processInfo.arguments.contains("-uiTestReset") {
            for printer in printers.printers { printers.remove(printer) }
        }
        // UI tests: talk to the virtual Kobra S1 (tools/virtualprinters/kobra_s1_sim.py) on this Mac.
        if ProcessInfo.processInfo.arguments.contains("-uiTestVirtualKobra"),
           !printers.printers.contains(where: { $0.host == "127.0.0.1" }) {
            printers.add(PrinterConnection(name: "Virtueller Kobra S1", host: "127.0.0.1",
                                           model: PrinterModel.kobraS1.rawValue, kind: .anycubicLAN))
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestSampleModel") || ProcessInfo.processInfo.arguments.contains("-uiTestProfileModel") || ProcessInfo.processInfo.arguments.contains("-uiTestPlates") || ProcessInfo.processInfo.arguments.contains("-uiTestMultiColorModel") {
            loadSample()
        }
    }

    func settings(for model: PrinterModel) -> PrintSettings {
        savedSettings[model] ?? PrintSettings(printer: model)
    }

    func remember(_ settings: PrintSettings) {
        savedSettings[settings.printer] = settings
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "settings-\(settings.printer.rawValue)")
        }
    }

    // MARK: - Opening models

    func open(_ item: LibraryItem) {
        let url = library.url(for: item)
        let fileName = item.fileName
        load(name: item.name) {
            let data = try Data(contentsOf: url)
            return try ModelImporter.load(data: data, fileName: fileName)
        }
    }

    /// Handles files opened from other apps (Files, AirDrop, "Öffnen in …").
    func handleIncoming(_ url: URL) {
        do {
            let item = try library.importFile(at: url)
            tab = .library
            open(item)
        } catch {
            alert = "Datei konnte nicht geöffnet werden: \(error.localizedDescription)"
        }
    }

    func addDownloaded(data: Data, fileName: String, title: String?, source: LibraryItem.Source,
                       sourceID: String? = nil, coverURL: URL? = nil, open shouldOpen: Bool = true) {
        // Portals often deliver a ZIP of STL/3MF files: unpack and add every model.
        if let files = ModelArchive.modelFiles(in: data) {
            var items: [LibraryItem] = []
            for file in files {
                if let item = try? library.add(data: file.data, fileName: file.name, name: nil, origin: source,
                                               makerWorldID: nil, coverURL: coverURL) { items.append(item) }
            }
            log.add(.info, "ZIP „\(fileName)“ entpackt: \(items.count) Modelle", source: source.displayName)
            if let first = items.first, shouldOpen { open(first) }
            if items.isEmpty { alert = "Im ZIP wurde kein Modell (STL, 3MF, OBJ) gefunden." }
            return
        }
        do {
            let item = try library.add(data: data, fileName: fileName, name: title, origin: source,
                                       makerWorldID: source == .makerWorld ? sourceID.flatMap { Int($0) } : nil,
                                       coverURL: coverURL)
            log.add(.info, "„\(item.name)“ heruntergeladen", source: source.displayName)
            if shouldOpen { open(item) }
        } catch {
            alert = "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func load(name: String, _ work: @escaping @Sendable () throws -> ImportedModel) {
        isLoadingModel = true
        loadingMessage = "Modell wird geladen …"
        let printer = printers.selected
        let model = printer.map { printers.model(of: $0) } ?? .snapmakerU1
        var settings = settings(for: model)
        settings.filaments = printers.suggestedFilaments(for: printer, current: settings.filaments, model: model)
        let loaded = printers.loadedTypes(printer)
        let humidity = printers.status(of: printer)?.filamentBox?.humidity
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ImportedModel, Error> in
                do { return .success(try work()) } catch { return .failure(error) }
            }.value
            isLoadingModel = false
            switch result {
            case .success(let model):
                let p = PrintProject(name: name, imported: model, settings: settings)
                p.loadedTypes = loaded
                p.dryerHumidity = humidity
                p.refreshRecommendations()
                sendState = .idle
                project = p
            case .failure(let error):
                alert = error.localizedDescription
                log.add(.error, "Import fehlgeschlagen: \(error.localizedDescription)", source: "App")
            }
        }
    }

    /// Small built-in test model (used by UI tests and the empty library).
    func loadSample() {
        if ProcessInfo.processInfo.arguments.contains("-uiTestProfileModel") {
            // A temperature tower as downloaded from the internet: own flow, ironing and temperature steps.
            let config = ##"{"print_settings_id":"0.20mm Standard @BBL X1C","printer_model":"Bambu Lab X1 Carbon","layer_height":"0.2","ironing_type":"top","print_flow_ratio":"0.95","seam_gap":"0","filament_type":["PETG"],"nozzle_temperature":["290"],"filament_flow_ratio":["0.93"],"outer_wall_speed":"120"}"##
            let xml = ##"<custom_gcodes_per_layer><plate><plate_info id="1"/><layer top_z="0.2" type="4" extruder="1" color="" extra="M104 S290" gcode="M104 S290"/><layer top_z="5.2" type="4" extruder="1" color="" extra="M104 S280" gcode="M104 S280"/></plate></custom_gcodes_per_layer>"##
            load(name: "Temperaturturm") {
                ImportedModel(objects: [ModelObject(name: "Turm", mesh: SampleModels.cube(20))],
                              projectSettings: ProjectSettings.fromConfig(Data(config.utf8), layerGCodeXML: Data(xml.utf8)))
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestMultiColorModel") {
            // A multi-colour download: a base and a lid in two colours (like a MakerWorld key ring with text).
            let config = ##"{"print_settings_id":"0.20mm Standard","filament_colour":["#F5F5F0","#2B2B2E","#E5483C"],"filament_type":["PLA","PETG","PLA"],"filament_vendor":["Generic","Generic","Generic"]}"##
            load(name: "Mehrfarbiger Schlüsselanhänger") {
                var base = ModelObject(name: "Anhänger", mesh: SampleModels.cube(30), tool: 0)
                base.parts = [ObjectPart(name: "Schrift", mesh: SampleModels.cube(10).transformed(.translation(Vec3(10, 10, 30))), tool: 2)]
                return ImportedModel(objects: [base], projectSettings: ProjectSettings.fromConfig(Data(config.utf8)))
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestPlates") {
            // Three large cubes (only one fits per plate) and two small ones: tests the automatic distribution.
            load(name: "Plattentest") {
                ImportedModel(objects: (0..<3).map { ModelObject(name: "Großer Würfel \($0 + 1)", mesh: SampleModels.cube(150)) }
                              + (0..<2).map { ModelObject(name: "Kleiner Würfel \($0 + 1)", mesh: SampleModels.cube(20)) })
            }
            return
        }
        load(name: "Kalibrierwürfel") {
            ImportedModel(objects: [ModelObject(name: "Würfel 20 mm", mesh: SampleModels.cube(20))])
        }
    }

    // MARK: - Printing

    func send(_ project: PrintProject, startPrint: Bool = true) async {
        guard let output = project.output else { return }
        guard let printer = printers.selected else {
            sendState = .failed("Kein Drucker eingerichtet. Füge im Tab „Drucker“ deinen Drucker hinzu.")
            return
        }
        let model = printers.model(of: printer)
        guard model == project.settings.printer else {
            sendState = .failed("Geslicet für \(project.settings.printer.displayName), ausgewählt ist aber „\(printer.name)“ (\(model.displayName)).")
            return
        }
        sendState = .uploading
        let mapping = project.usedTools.map { tool -> SlotMapping in
            let f = project.settings.filament(for: tool)
            return SlotMapping(tool: tool, slot: tool, materialType: f.type, color: Color(hex: f.color).rgbBytes)
        }
        do {
            let data = Data(output.gcode.utf8)
            try await printers.driver(for: printer).upload(gcode: data, fileName: project.gcodeFileName,
                                                           startPrint: startPrint, mapping: mapping)
            sendState = .done
            log.add(.info, startPrint ? "Druck gestartet: \(project.gcodeFileName)" : "Hochgeladen: \(project.gcodeFileName)",
                    source: printer.name)
            remember(project.settings)
            await printers.refresh(printer)
        } catch {
            sendState = .failed(error.localizedDescription)
            log.add(.error, "Senden fehlgeschlagen: \(error.localizedDescription)", source: printer.name)
        }
    }
}

extension LibraryItem.Source {
    var displayName: String {
        switch self {
        case .file: return "Datei"
        case .makerWorld: return "MakerWorld"
        case .printables: return "Printables"
        case .web: return "Web-Portal"
        }
    }
}

enum SampleModels {
    static func cube(_ size: Double) -> TriangleMesh {
        let s = size
        let v = [Vec3(0, 0, 0), Vec3(s, 0, 0), Vec3(s, s, 0), Vec3(0, s, 0),
                 Vec3(0, 0, s), Vec3(s, 0, s), Vec3(s, s, s), Vec3(0, s, s)]
        let i: [UInt32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4,
                           1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7]
        return TriangleMesh(vertices: v, indices: i)
    }
}
