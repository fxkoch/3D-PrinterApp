import Foundation

/// One printable object of an imported file, already in build-plate coordinates.
public struct ModelObject: Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var name: String
    public var mesh: TriangleMesh
    /// Zero-based tool/extruder index (U1: 0...3).
    public var tool: Int
    /// Plate number from a Bambu/Orca project (1-based), if known.
    public var plate: Int?

    public init(name: String, mesh: TriangleMesh, tool: Int = 0, plate: Int? = nil) {
        self.name = name
        self.mesh = mesh
        self.tool = tool
        self.plate = plate
    }
}

/// Result of importing a model file.
public struct ImportedModel: Sendable {
    public var objects: [ModelObject]
    /// Settings found in a Bambu Studio / Orca project (Metadata/project_settings.config).
    public var projectSettings: ProjectSettings?
    public var plates: [Int] {
        Array(Set(objects.compactMap(\.plate))).sorted()
    }
    /// True when the file used per-triangle colour painting, which we print single-colour.
    public var hasPaintedColors: Bool

    public init(objects: [ModelObject], projectSettings: ProjectSettings? = nil, hasPaintedColors: Bool = false) {
        self.objects = objects
        self.projectSettings = projectSettings
        self.hasPaintedColors = hasPaintedColors
    }
}

/// Subset of Bambu/Orca project settings that map onto our profile.
public struct ProjectSettings: Sendable, Equatable {
    public var layerHeight: Double?
    public var firstLayerHeight: Double?
    public var wallLoops: Int?
    public var topLayers: Int?
    public var bottomLayers: Int?
    public var infillDensity: Double?
    public var supportEnabled: Bool?
    public var filamentColors: [String] = []
    public var filamentTypes: [String] = []
    public var printerModel: String?

    static func parse(_ data: Data) -> ProjectSettings? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func string(_ key: String) -> String? {
            if let s = json[key] as? String { return s }
            if let a = json[key] as? [String], let first = a.first { return first }
            return nil
        }
        func double(_ key: String) -> Double? {
            string(key).flatMap { Double($0.replacingOccurrences(of: "%", with: "")) }
        }
        var s = ProjectSettings()
        s.layerHeight = double("layer_height")
        s.firstLayerHeight = double("initial_layer_print_height")
        s.wallLoops = double("wall_loops").map { Int($0) }
        s.topLayers = double("top_shell_layers").map { Int($0) }
        s.bottomLayers = double("bottom_shell_layers").map { Int($0) }
        s.infillDensity = double("sparse_infill_density").map { $0 / 100 }
        if let support = string("enable_support") { s.supportEnabled = support == "1" || support == "true" }
        s.filamentColors = json["filament_colour"] as? [String] ?? []
        s.filamentTypes = json["filament_type"] as? [String] ?? []
        s.printerModel = string("printer_model")
        return s
    }
}

public enum ModelImporter {
    /// Imports STL, 3MF or OBJ data. `fileName` is used to pick the format.
    public static func load(data: Data, fileName: String) throws -> ImportedModel {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let baseName = ((fileName as NSString).lastPathComponent as NSString).deletingPathExtension
        switch ext {
        case "stl":
            return ImportedModel(objects: [ModelObject(name: baseName, mesh: try STLReader.read(data))])
        case "3mf":
            return try ThreeMFReader.read(data)
        case "obj":
            return ImportedModel(objects: [ModelObject(name: baseName, mesh: try OBJReader.read(data))])
        default:
            // Some downloads arrive without an extension; sniff the content.
            if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return try ThreeMFReader.read(data) }
            if let mesh = try? STLReader.read(data) { return ImportedModel(objects: [ModelObject(name: baseName, mesh: mesh)]) }
            throw ModelImportError.unsupportedFormat(ext.isEmpty ? "?" : ext)
        }
    }
}

public enum ThreeMFReader {
    private struct ObjectResource {
        var mesh = TriangleMesh()
        var components: [(path: String?, objectID: String, transform: Transform3D)] = []
        var name: String?
        var type: String?
    }

    private struct ObjectSettings {
        var name: String?
        var extruder: Int?
        /// Part id → (subtype, extruder)
        var parts: [String: (subtype: String?, extruder: Int?)] = [:]
    }

    public static func read(_ data: Data) throws -> ImportedModel {
        let zip = try ZipArchive(data: data)
        let rootPath = rootModelPath(zip)
        guard let rootData = try zip.contents(of: rootPath) else {
            throw ModelImportError.corrupted("3D-Modell fehlt im 3MF-Paket")
        }

        var files: [String: [String: ObjectResource]] = [:]
        var painted = false
        func resources(in path: String) throws -> [String: ObjectResource] {
            let key = normalize(path)
            if let cached = files[key] { return cached }
            guard let d = try zip.contents(of: key) else { return [:] }
            let (objects, hasPaint) = parseModel(d)
            painted = painted || hasPaint
            files[key] = objects
            return objects
        }

        let (rootObjects, rootPaint) = parseModel(rootData)
        painted = painted || rootPaint
        files[normalize(rootPath)] = rootObjects
        let buildItems = parseBuild(rootData)

        let settings: (objects: [String: ObjectSettings], plateForObject: [String: Int]) =
            try zip.contents(of: "Metadata/model_settings.config").map(parseModelSettings) ?? ([:], [:])
        let project = try zip.contents(of: "Metadata/project_settings.config").flatMap(ProjectSettings.parse)

        var result: [ModelObject] = []
        for (index, item) in buildItems.enumerated() where item.printable {
            guard let object = rootObjects[item.objectID] else { continue }
            let objectSettings = settings.objects[item.objectID]
            var mesh = TriangleMesh()

            // Collect the object's own mesh plus all (nested) components.
            func collect(_ obj: ObjectResource, file: String, transform: Transform3D, partID: String?, depth: Int) throws {
                guard depth < 16 else { return }
                if let partID, let subtype = objectSettings?.parts[partID]?.subtype,
                   subtype != "normal_part" && !subtype.isEmpty {
                    return // modifiers, negative volumes, support blockers
                }
                if !obj.mesh.isEmpty { mesh.append(obj.mesh.transformed(transform)) }
                for component in obj.components {
                    let compFile = component.path.map(normalize) ?? file
                    let pool = try resources(in: compFile)
                    guard let child = pool[component.objectID] else { continue }
                    try collect(child, file: compFile, transform: component.transform.then(transform),
                                partID: component.objectID, depth: depth + 1)
                }
            }
            try collect(object, file: normalize(rootPath), transform: item.transform, partID: nil, depth: 0)
            guard !mesh.isEmpty else { continue }

            let name = objectSettings?.name ?? object.name ?? "Objekt \(index + 1)"
            let extruder = objectSettings?.extruder ?? objectSettings?.parts.values.compactMap({ $0.extruder }).first ?? 1
            result.append(ModelObject(name: name, mesh: mesh, tool: max(0, extruder - 1),
                                      plate: settings.plateForObject[item.objectID]))
        }
        guard !result.isEmpty else { throw ModelImportError.empty }
        return ImportedModel(objects: result, projectSettings: project, hasPaintedColors: painted)
    }

    private static func normalize(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    private static func rootModelPath(_ zip: ZipArchive) -> String {
        if let rels = try? zip.contents(of: "_rels/.rels") {
            var target: String?
            XMLTagScanner(data: rels).forEachTag { tag in
                if tag.localName == "Relationship", tag.attribute("Type")?.hasSuffix("/3dmodel") == true {
                    target = tag.attribute("Target")
                }
            }
            if let target { return normalize(target) }
        }
        return "3D/3dmodel.model"
    }

    private static func parseModel(_ data: Data) -> ([String: ObjectResource], Bool) {
        var objects: [String: ObjectResource] = [:]
        var current: ObjectResource?
        var currentID: String?
        var vertices: [Vec3] = []
        var indices: [UInt32] = []
        var painted = false

        XMLTagScanner(data: data).forEachTag { tag in
            switch tag.localName {
            case "object":
                if tag.isClosing {
                    if var obj = current, let id = currentID {
                        if !indices.isEmpty { obj.mesh = TriangleMesh(vertices: vertices, indices: indices) }
                        objects[id] = obj
                    }
                    current = nil; currentID = nil
                } else {
                    current = ObjectResource(name: tag.attribute("name"), type: tag.attribute("type"))
                    currentID = tag.attribute("id")
                    vertices.removeAll(keepingCapacity: true)
                    indices.removeAll(keepingCapacity: true)
                    if tag.isSelfClosing, let id = currentID { objects[id] = current; current = nil }
                }
            case "vertex":
                if let x = tag.attributes["x"].flatMap(Double.init),
                   let y = tag.attributes["y"].flatMap(Double.init),
                   let z = tag.attributes["z"].flatMap(Double.init) {
                    vertices.append(Vec3(x, y, z))
                }
            case "triangle":
                if let a = tag.attributes["v1"].flatMap(UInt32.init),
                   let b = tag.attributes["v2"].flatMap(UInt32.init),
                   let c = tag.attributes["v3"].flatMap(UInt32.init),
                   a < vertices.count, b < vertices.count, c < vertices.count {
                    indices.append(a); indices.append(b); indices.append(c)
                    if !painted, tag.attributes["paint_color"] != nil || tag.attributes["slic3rpe:mmu_segmentation"] != nil {
                        painted = true
                    }
                }
            case "component":
                guard let objectID = tag.attribute("objectid") else { return }
                let transform = tag.attribute("transform").flatMap(Transform3D.init(threeMF:)) ?? .identity
                current?.components.append((tag.attribute("path"), objectID, transform))
            default:
                break
            }
        }
        return (objects, painted)
    }

    private static func parseBuild(_ data: Data) -> [(objectID: String, transform: Transform3D, printable: Bool)] {
        var items: [(String, Transform3D, Bool)] = []
        var inBuild = false
        XMLTagScanner(data: data).forEachTag { tag in
            if tag.localName == "build" { inBuild = !tag.isClosing }
            guard inBuild, tag.localName == "item", !tag.isClosing, let id = tag.attribute("objectid") else { return }
            let transform = tag.attribute("transform").flatMap(Transform3D.init(threeMF:)) ?? .identity
            let printable = tag.attribute("printable").map { $0 != "0" } ?? true
            items.append((id, transform, printable))
        }
        return items.map { (objectID: $0.0, transform: $0.1, printable: $0.2) }
    }

    private static func parseModelSettings(_ data: Data) -> (objects: [String: ObjectSettings], plateForObject: [String: Int]) {
        var objects: [String: ObjectSettings] = [:]
        var plateForObject: [String: Int] = [:]
        var objectID: String?
        var partID: String?
        var plateID: Int?
        var inInstance = false

        XMLTagScanner(data: data).forEachTag { tag in
            switch tag.localName {
            case "object":
                if tag.isClosing { objectID = nil } else {
                    objectID = tag.attribute("id")
                    if let id = objectID, objects[id] == nil { objects[id] = ObjectSettings() }
                }
            case "part":
                if tag.isClosing { partID = nil } else {
                    partID = tag.attribute("id")
                    if let o = objectID, let p = partID {
                        objects[o]?.parts[p] = (tag.attribute("subtype"), nil)
                    }
                    if tag.isSelfClosing { partID = nil }
                }
            case "plate":
                if tag.isClosing { plateID = nil } else { plateID = 0 }
            case "model_instance":
                inInstance = !tag.isClosing && !tag.isSelfClosing
            case "metadata":
                guard let key = tag.attribute("key"), let value = tag.attribute("value") else { return }
                if let o = objectID {
                    if let p = partID {
                        if key == "extruder" { objects[o]?.parts[p]?.extruder = Int(value) }
                    } else if key == "name" {
                        objects[o]?.name = value
                    } else if key == "extruder" {
                        objects[o]?.extruder = Int(value)
                    }
                } else if plateID != nil {
                    if key == "plater_id" { plateID = Int(value) }
                    if inInstance, key == "object_id", let plate = plateID { plateForObject[value] = plate }
                }
            default:
                break
            }
        }
        return (objects, plateForObject)
    }
}

public enum OBJReader {
    public static func read(_ data: Data) throws -> TriangleMesh {
        var vertices: [Vec3] = []
        var tris: [(Vec3, Vec3, Vec3)] = []
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let head = parts.first else { continue }
            if head == "v", parts.count >= 4, let x = Double(parts[1]), let y = Double(parts[2]), let z = Double(parts[3]) {
                vertices.append(Vec3(x, y, z))
            } else if head == "f", parts.count >= 4 {
                let idx: [Int] = parts.dropFirst().compactMap { token in
                    guard let raw = Int(token.split(separator: "/").first ?? "") else { return nil }
                    return raw < 0 ? vertices.count + raw : raw - 1
                }
                guard idx.count >= 3, idx.allSatisfy({ $0 >= 0 && $0 < vertices.count }) else { continue }
                for k in 1..<(idx.count - 1) {
                    tris.append((vertices[idx[0]], vertices[idx[k]], vertices[idx[k + 1]]))
                }
            }
        }
        guard !tris.isEmpty else { throw ModelImportError.empty }
        return TriangleMesh(soup: tris)
    }
}
