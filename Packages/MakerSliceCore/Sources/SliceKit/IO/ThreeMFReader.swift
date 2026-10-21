import Foundation

/// Extra geometry attached to an object: added (e.g. connector pegs) or
/// subtracted (connector holes) when slicing.
public struct ObjectVolume: Sendable, Equatable {
    public enum Kind: String, Sendable { case add, subtract }
    public var kind: Kind
    public var mesh: TriangleMesh

    public init(kind: Kind, mesh: TriangleMesh) {
        self.kind = kind
        self.mesh = mesh
    }
}

/// A further body of an object printed in another colour/material (a part of a multi-colour 3MF).
public struct ObjectPart: Sendable, Equatable {
    public var name: String
    public var mesh: TriangleMesh
    /// Zero-based tool/slot index (0...3).
    public var tool: Int
    /// Extruder/colour index this part had in the imported file (before the user mapped colours to slots).
    public var sourceTool: Int?

    public init(name: String, mesh: TriangleMesh, tool: Int, sourceTool: Int? = nil) {
        self.name = name
        self.mesh = mesh
        self.tool = tool
        self.sourceTool = sourceTool ?? tool
    }
}

/// From this height (mm above the bed) the object is printed with another slot.
public struct ColorChange: Sendable, Equatable, Hashable, Codable {
    public var z: Double
    public var tool: Int

    public init(z: Double, tool: Int) {
        self.z = z
        self.tool = tool
    }
}

/// One printable object of an imported file, already in build-plate coordinates.
public struct ModelObject: Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var name: String
    public var mesh: TriangleMesh
    /// Zero-based tool/slot index (0...3).
    public var tool: Int
    /// Plate number from a Bambu/Orca project (1-based), if known.
    public var plate: Int?
    public var volumes: [ObjectVolume]
    /// Extruder/colour index the main body had in the imported file.
    public var sourceTool: Int?
    /// Further bodies with their own slot (multi-colour parts). The main `mesh` uses `tool`.
    public var parts: [ObjectPart] = []
    /// Surface painted with other colours (MakerWorld / Bambu Studio multi-colour painting), as small triangles.
    public var paint: [PaintedFacet] = []
    /// Height-based slot changes of the main body, sorted by height.
    public var colorChanges: [ColorChange] = []

    /// True when the object is printed in more than one colour.
    public var isMultiColor: Bool { !parts.isEmpty || !colorChanges.isEmpty || !paint.isEmpty }

    /// Slot used by the main body at height `z` (mm).
    public func tool(atHeight z: Double) -> Int {
        var result = tool
        for change in colorChanges.sorted(by: { $0.z < $1.z }) where change.z <= z { result = change.tool }
        return result
    }

    /// Every slot this object can use.
    public var allTools: Set<Int> { Set([tool] + parts.map(\.tool) + colorChanges.map(\.tool) + paint.map(\.tool)) }

    public init(name: String, mesh: TriangleMesh, tool: Int = 0, plate: Int? = nil, volumes: [ObjectVolume] = []) {
        self.name = name
        self.mesh = mesh
        self.tool = tool
        self.sourceTool = tool
        self.plate = plate
        self.volumes = volumes
    }

    /// The object with its colours mapped to printer slots (`map`: file colour → slot).
    public func applyingColorMap(_ map: [Int: Int]) -> ModelObject {
        var copy = self
        copy.tool = map[sourceTool ?? tool] ?? tool
        copy.parts = parts.map { part in
            var p = part
            p.tool = map[part.sourceTool ?? part.tool] ?? part.tool
            return p
        }
        copy.paint = paint.map { facet in
            var f = facet
            f.tool = map[facet.sourceTool] ?? facet.tool
            return f
        }
        return copy
    }

    /// Bounds of the printed shape (mesh plus added volumes).
    public var boundingBox: BoundingBox {
        var box = mesh.boundingBox
        for v in volumes where v.kind == .add { box.include(v.mesh.boundingBox) }
        for part in parts { box.include(part.mesh.boundingBox) }
        return box
    }

    public func transformed(_ t: Transform3D) -> ModelObject {
        var copy = self
        copy.mesh = mesh.transformed(t)
        copy.volumes = volumes.map { ObjectVolume(kind: $0.kind, mesh: $0.mesh.transformed(t)) }
        copy.parts = parts.map { ObjectPart(name: $0.name, mesh: $0.mesh.transformed(t), tool: $0.tool, sourceTool: $0.sourceTool) }
        copy.paint = paint.map { $0.transformed(t) }
        return copy
    }

    /// Moves the object so it rests on z = 0 with its XY centre at `center`.
    public func placedOnBed(center: (x: Double, y: Double)) -> ModelObject {
        let box = boundingBox
        guard !box.isEmpty else { return self }
        return transformed(.translation(Vec3(center.x - box.center.x, center.y - box.center.y, -box.min.z)))
    }
}

/// A colour/material of an imported project, as the file defines it.
public struct ModelColor: Identifiable, Equatable, Sendable {
    public var id: Int { tool }
    /// Zero-based extruder index in the file.
    public var tool: Int
    /// "#RRGGBB"
    public var colorHex: String
    /// Material type from the project (PLA, PETG …), if known.
    public var type: String?
    public var vendor: String?
    /// Names of the objects/parts printed in this colour.
    public var users: [String]
}

/// Result of importing a model file.
public struct ImportedModel: Sendable {
    public var objects: [ModelObject]
    /// Settings found in a Bambu Studio / Orca project (Metadata/project_settings.config).
    public var projectSettings: ProjectSettings?
    /// Colours the project really uses (an extruder counts when an object or part is printed with it).
    public var modelColors: [ModelColor] {
        var users: [Int: [String]] = [:]
        for object in objects {
            users[object.sourceTool ?? object.tool, default: []].append(object.name)
            for part in object.parts { users[part.sourceTool ?? part.tool, default: []].append(part.name) }
            for tool in Set(object.paint.map(\.sourceTool)) { users[tool, default: []].append("\(object.name) (bemalt)") }
        }
        func at(_ list: [String]?, _ i: Int) -> String? { list.flatMap { $0.indices.contains(i) ? $0[i] : nil } }
        return users.keys.sorted().map { tool in
            let raw = at(projectSettings?.filamentColors, tool) ?? "#888888"
            let hex = raw.hasPrefix("#") && raw.count >= 7 ? String(raw.prefix(7)) : "#888888"
            let vendor = at(projectSettings?.filamentVendors, tool).flatMap { $0.isEmpty ? nil : $0 }
            return ModelColor(tool: tool, colorHex: hex, type: at(projectSettings?.filamentTypes, tool), vendor: vendor, users: users[tool] ?? [])
        }
    }

    /// True when the project prints in more than one colour.
    public var isMultiColor: Bool { modelColors.count > 1 }

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
    public var supportOnBuildPlateOnly: Bool?
    public var infillPattern: InfillPattern?
    public var brimWidth: Double?
    public var ironing: Bool?
    public var filamentColors: [String] = []
    public var filamentTypes: [String] = []
    public var filamentVendors: [String] = []
    public var printerModel: String?
    /// Name of the process preset the file was made with (`print_settings_id`).
    public var profileName: String?
    /// Every single-valued setting of the project, OrcaSlicer key → value.
    public var raw: [String: String] = [:]
    /// Per-filament settings (temperatures, flow, fan …), OrcaSlicer key → one value per filament.
    public var perFilament: [String: [String]] = [:]
    /// G-code the project inserts at certain heights (e.g. temperature towers change the nozzle temperature).
    public var layerGCodes: [LayerGCode] = []

    /// Reads `Metadata/project_settings.config` (JSON) and optionally `Metadata/custom_gcode_per_layer.xml`.
    public static func fromConfig(_ config: Data, layerGCodeXML: Data? = nil) -> ProjectSettings? {
        guard var project = parse(config) else { return nil }
        if let xml = layerGCodeXML { project.layerGCodes = LayerGCode.parse(xml) }
        return project
    }

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
        if let plate = string("support_on_build_plate_only") { s.supportOnBuildPlateOnly = plate == "1" || plate == "true" }
        switch string("sparse_infill_pattern") {
        case "gyroid": s.infillPattern = .gyroid
        case "cubic", "adaptivecubic", "supportcubic": s.infillPattern = .cubic
        case "triangles", "tri-hexagon", "stars": s.infillPattern = .triangles
        case "line", "zig-zag", "crosshatch": s.infillPattern = .lines
        case "grid", "rectilinear", "alignedrectilinear": s.infillPattern = .grid
        default: break
        }
        if string("brim_type") == "no_brim" { s.brimWidth = 0 } else { s.brimWidth = double("brim_width") }
        if let ironing = string("ironing_type") { s.ironing = ironing != "no ironing" }
        s.filamentVendors = json["filament_vendor"] as? [String] ?? []
        s.filamentColors = json["filament_colour"] as? [String] ?? []
        s.filamentTypes = json["filament_type"] as? [String] ?? []
        // A profile file of its own (from GitHub/Printables) has no printer_model: it names the printers it fits instead.
        s.printerModel = string("printer_model") ?? (json["compatible_printers"] as? [String])?.first
        s.profileName = string("print_settings_id") ?? string("name") ?? string("filament_settings_id")
        for (key, value) in json {
            if let v = value as? String { s.raw[key] = v }
            else if let list = value as? [String] {
                if list.count == 1 { s.raw[key] = list[0] }
                s.perFilament[key] = list
            }
        }
        return s
    }
}

extension ProjectSettings {
    func withLayerGCodes(_ codes: [LayerGCode]) -> ProjectSettings {
        var copy = self
        copy.layerGCodes = codes
        return copy
    }
}

/// G-code a project inserts before the layer at height `z`.
public struct LayerGCode: Codable, Sendable, Hashable {
    public var z: Double
    public var lines: [String]

    public init(z: Double, lines: [String]) {
        self.z = z
        self.lines = lines
    }

    /// Commands that only change temperature, fan, speed, flow or pressure advance – the only ones taken over from a file.
    static let allowedPrefixes = ["M104", "M109", "M140", "M190", "M106", "M107", "M220", "M221", "M900", "M572", "SET_PRESSURE_ADVANCE", "M117"]

    static func isAllowed(_ line: String) -> Bool {
        let command = line.trimmingCharacters(in: .whitespaces).uppercased()
        return allowedPrefixes.contains { command == $0 || command.hasPrefix($0 + " ") }
    }

    /// Reads `Metadata/custom_gcode_per_layer.xml` (Bambu Studio / OrcaSlicer).
    static func parse(_ data: Data) -> [LayerGCode] {
        var result: [LayerGCode] = []
        XMLTagScanner(data: data).forEachTag { tag in
            guard tag.localName == "layer", !tag.isClosing, let z = tag.attribute("top_z").flatMap(Double.init) else { return }
            let type = tag.attribute("type").flatMap(Int.init)
            let gcode = tag.attribute("gcode").flatMap { $0.isEmpty ? nil : $0 } ?? (type == 4 ? tag.attribute("extra") : nil)
            guard let gcode else { return }
            let lines = gcode.replacingOccurrences(of: "&#10;", with: "\n").replacingOccurrences(of: "&#13;", with: "")
                .split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !lines.isEmpty { result.append(LayerGCode(z: z, lines: lines)) }
        }
        return result.sorted { $0.z < $1.z }
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
        /// Triangle index → `paint_color` text (multi-colour painting).
        var paint: [Int: String] = [:]
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
        var project = try zip.contents(of: "Metadata/project_settings.config").flatMap(ProjectSettings.parse)
        if let xml = try zip.contents(of: "Metadata/custom_gcode_per_layer.xml") {
            let codes = LayerGCode.parse(xml)
            if !codes.isEmpty { project = (project ?? ProjectSettings()).withLayerGCodes(codes) }
        }

        var result: [ModelObject] = []
        var paintFailed = false
        for (index, item) in buildItems.enumerated() where item.printable {
            guard let object = rootObjects[item.objectID] else { continue }
            let objectSettings = settings.objects[item.objectID]
            // Meshes per extruder (1-based): parts of a multi-colour project keep their own slot.
            var paintFacets: [PaintedFacet] = []
            var byExtruder: [Int: TriangleMesh] = [:]
            var partNames: [Int: String] = [:]
            let objectExtruder = objectSettings?.extruder ?? objectSettings?.parts.values.compactMap({ $0.extruder }).first ?? 1

            // Collect the object's own mesh plus all (nested) components.
            func collect(_ obj: ObjectResource, file: String, transform: Transform3D, partID: String?, extruder inherited: Int?, depth: Int) throws {
                guard depth < 16 else { return }
                if let partID, let subtype = objectSettings?.parts[partID]?.subtype,
                   subtype != "normal_part" && !subtype.isEmpty {
                    return // modifiers, negative volumes, support blockers
                }
                let extruder = partID.flatMap { objectSettings?.parts[$0]?.extruder } ?? inherited
                if !obj.mesh.isEmpty {
                    let slot = extruder ?? objectExtruder
                    byExtruder[slot, default: TriangleMesh()].append(obj.mesh.transformed(transform))
                    if partNames[slot] == nil { partNames[slot] = obj.name }
                    for (triangle, text) in obj.paint {
                        let m = obj.mesh
                        guard triangle * 3 + 2 < m.indices.count else { continue }
                        let v = (0..<3).map { transform.apply(m.vertices[Int(m.indices[triangle * 3 + $0])]) }
                        if let facets = PaintDecoder.decode(text, a: v[0], b: v[1], c: v[2]) { paintFacets += facets } else { paintFailed = true }
                    }
                }
                for component in obj.components {
                    let compFile = component.path.map(normalize) ?? file
                    let pool = try resources(in: compFile)
                    guard let child = pool[component.objectID] else { continue }
                    try collect(child, file: compFile, transform: component.transform.then(transform),
                                partID: component.objectID, extruder: extruder, depth: depth + 1)
                }
            }
            try collect(object, file: normalize(rootPath), transform: item.transform, partID: nil, extruder: nil, depth: 0)
            // The main body is the one with the most triangles; the rest become coloured parts.
            guard let mainSlot = byExtruder.max(by: { $0.value.triangleCount < $1.value.triangleCount })?.key,
                  let mesh = byExtruder[mainSlot], !mesh.isEmpty else { continue }

            let name = objectSettings?.name ?? object.name ?? "Objekt \(index + 1)"
            var imported = ModelObject(name: name, mesh: mesh, tool: max(0, mainSlot - 1),
                                       plate: settings.plateForObject[item.objectID])
            for slot in byExtruder.keys.sorted() where slot != mainSlot {
                guard let partMesh = byExtruder[slot], !partMesh.isEmpty else { continue }
                imported.parts.append(ObjectPart(name: partNames[slot] ?? "Teil \(slot)", mesh: partMesh, tool: max(0, slot - 1)))
            }
            imported.paint = paintFacets
            result.append(imported)
        }
        guard !result.isEmpty else { throw ModelImportError.empty }
        // Painted colours are taken over; the warning stays only for paint data that could not be read.
        return ImportedModel(objects: result, projectSettings: project, hasPaintedColors: painted && paintFailed)
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
                    if let text = tag.attributes["paint_color"] ?? tag.attributes["slic3rpe:mmu_segmentation"], !text.isEmpty {
                        painted = true
                        current?.paint[indices.count / 3 - 1] = text
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
