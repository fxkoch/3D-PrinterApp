import Foundation

/// Writes arranged objects as an OrcaSlicer/Bambu-compatible 3MF: one object per model object with its
/// tool in `model_settings.config`; connector pegs become extra parts, connector holes negative parts.
public enum ThreeMFWriter {
    public static func write(_ objects: [ModelObject]) -> Data {
        var resources = ""
        var build = ""
        var settings = ""
        var nextID = 1

        for object in objects {
            var parts: [(id: Int, name: String, subtype: String)] = []
            func addMesh(_ mesh: TriangleMesh, name: String, subtype: String) {
                let id = nextID
                nextID += 1
                resources += "  <object id=\"\(id)\" type=\"model\">\n"
                resources += meshXML(mesh)
                resources += "  </object>\n"
                parts.append((id, name, subtype))
            }
            addMesh(object.mesh, name: object.name, subtype: "normal_part")
            for (i, volume) in object.volumes.enumerated() {
                addMesh(volume.mesh, name: "\(object.name) Verbinder \(i + 1)",
                        subtype: volume.kind == .add ? "normal_part" : "negative_part")
            }
            let containerID = nextID
            nextID += 1
            resources += "  <object id=\"\(containerID)\" type=\"model\">\n   <components>\n"
            for part in parts { resources += "    <component objectid=\"\(part.id)\"/>\n" }
            resources += "   </components>\n  </object>\n"
            build += "  <item objectid=\"\(containerID)\" printable=\"1\"/>\n"

            let extruder = object.tool + 1
            settings += "  <object id=\"\(containerID)\">\n"
            settings += "    <metadata key=\"name\" value=\"\(escape(object.name))\"/>\n"
            settings += "    <metadata key=\"extruder\" value=\"\(extruder)\"/>\n"
            for part in parts {
                settings += "    <part id=\"\(part.id)\" subtype=\"\(part.subtype)\">\n"
                settings += "      <metadata key=\"name\" value=\"\(escape(part.name))\"/>\n"
                settings += "      <metadata key=\"extruder\" value=\"\(extruder)\"/>\n"
                settings += "    </part>\n"
            }
            settings += "  </object>\n"
        }

        let model = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
         <metadata name="Application">MakerSlice</metadata>
         <resources>
        \(resources) </resources>
         <build>
        \(build) </build>
        </model>

        """
        var plate = "  <plate>\n    <metadata key=\"plater_id\" value=\"1\"/>\n"
        for line in build.split(separator: "\n") {
            guard let r = line.range(of: "objectid=\""), let end = line[r.upperBound...].firstIndex(of: "\"") else { continue }
            let id = line[r.upperBound..<end]
            plate += "    <model_instance>\n      <metadata key=\"object_id\" value=\"\(id)\"/>\n"
            plate += "      <metadata key=\"instance_id\" value=\"0\"/>\n    </model_instance>\n"
        }
        plate += "  </plate>\n"
        let modelSettings = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<config>\n\(settings)\(plate)</config>\n"

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
         <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
         <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
         <Default Extension="config" ContentType="text/xml"/>
        </Types>

        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
         <Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
        </Relationships>

        """
        return ZipArchive.write([
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rels.utf8)),
            ("3D/3dmodel.model", Data(model.utf8)),
            ("Metadata/model_settings.config", Data(modelSettings.utf8)),
        ])
    }

    private static func meshXML(_ mesh: TriangleMesh) -> String {
        var s = "   <mesh>\n    <vertices>\n"
        s.reserveCapacity(mesh.vertices.count * 60 + mesh.indices.count * 20)
        for v in mesh.vertices {
            s += "     <vertex x=\"\(formatDecimal(v.x, digits: 5))\" y=\"\(formatDecimal(v.y, digits: 5))\" z=\"\(formatDecimal(v.z, digits: 5))\"/>\n"
        }
        s += "    </vertices>\n    <triangles>\n"
        var i = 0
        while i + 2 < mesh.indices.count {
            s += "     <triangle v1=\"\(mesh.indices[i])\" v2=\"\(mesh.indices[i + 1])\" v3=\"\(mesh.indices[i + 2])\"/>\n"
            i += 3
        }
        s += "    </triangles>\n   </mesh>\n"
        return s
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
