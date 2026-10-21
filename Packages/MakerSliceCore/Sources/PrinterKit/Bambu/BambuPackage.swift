import Foundation

/// Wraps sliced G-code into the `.gcode.3mf` container Bambu Lab printers print from
/// (`Metadata/plate_1.gcode` plus its MD5 and a small `slice_info.config` for the printer's screen).
public enum BambuPackage {
    public struct Info: Equatable, Sendable {
        public var seconds = 0
        public var grams = 0.0
        public var types: [String] = []
        public var colors: [String] = []
        /// Used filament per slot in grams.
        public var gramsPerSlot: [Double] = []
    }

    /// Reads time, weight, filament types and colours from the comment lines OrcaSlicer-style headers contain.
    public static func info(fromGCode gcode: Data) -> Info {
        var info = Info()
        let text = String(decoding: gcode.prefix(400_000) + gcode.suffix(60_000), as: UTF8.self)
        for line in text.split(separator: "\n") where line.hasPrefix("; ") {
            let l = String(line.dropFirst(2))
            func value(_ key: String) -> String? {
                guard l.hasPrefix(key + " = ") else { return nil }
                return String(l.dropFirst(key.count + 3))
            }
            if let v = value("estimated printing time (normal mode)") { info.seconds = parseDuration(v) }
            else if let v = value("total filament used [g]") { info.grams = Double(v) ?? info.grams }
            else if let v = value("filament_type"), info.types.isEmpty { info.types = v.split(separator: ";").map(String.init) }
            else if let v = value("filament_colour"), info.colors.isEmpty { info.colors = v.split(separator: ";").map(String.init) }
            else if let v = value("filament used [g]"), info.gramsPerSlot.isEmpty { info.gramsPerSlot = v.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
        }
        return info
    }

    /// "1d 2h 3m 4s" → seconds.
    static func parseDuration(_ text: String) -> Int {
        var total = 0
        for part in text.split(separator: " ") {
            guard let unit = part.last, let n = Int(part.dropLast()) else { continue }
            switch unit { case "d": total += n * 86400; case "h": total += n * 3600; case "m": total += n * 60; case "s": total += n; default: break }
        }
        return total
    }

    /// The finished container.
    public static func make(gcode: Data, name: String) -> Data {
        let info = info(fromGCode: gcode)
        let md5 = LANCrypto.md5([UInt8](gcode)).map { String(format: "%02X", $0) }.joined()
        let used = info.gramsPerSlot.enumerated().filter { $0.element > 0 }
        var filaments = ""
        for (i, g) in used {
            let type = info.types.indices.contains(i) ? info.types[i] : "PLA"
            let color = info.colors.indices.contains(i) ? info.colors[i] : "#FFFFFF"
            filaments += "    <filament id=\"\(i + 1)\" tray_info_idx=\"\" type=\"\(xml(type))\" color=\"\(xml(color))\" used_m=\"\(String(format: "%.2f", g / 3.0))\" used_g=\"\(String(format: "%.2f", g))\" />\n"
        }
        let sliceInfo = """
        <?xml version="1.0" encoding="UTF-8"?>
        <config>
          <header>
            <header_item key="X-BBL-Client-Type" value="slicer"/>
            <header_item key="X-BBL-Client-Version" value="01.10.00.00"/>
          </header>
          <plate>
            <metadata key="index" value="1"/>
            <metadata key="printer_model_id" value="C12"/>
            <metadata key="nozzle_diameters" value="0.4"/>
            <metadata key="prediction" value="\(info.seconds)"/>
            <metadata key="weight" value="\(String(format: "%.2f", info.grams))"/>
        \(filaments)  </plate>
        </config>

        """
        let files: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rels.utf8)),
            ("3D/3dmodel.model", Data(model(name: name).utf8)),
            ("Metadata/slice_info.config", Data(sliceInfo.utf8)),
            ("Metadata/plate_1.gcode", gcode),
            ("Metadata/plate_1.gcode.md5", Data(md5.utf8)),
        ]
        return zip(files)
    }

    private static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
    }

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
     <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
     <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
     <Default Extension="gcode" ContentType="text/x.gcode"/>
     <Default Extension="md5" ContentType="text/plain"/>
     <Default Extension="config" ContentType="text/xml"/>
    </Types>
    """

    private static let rels = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
     <Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
    </Relationships>
    """

    private static func model(name: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:BambuStudio="http://schemas.bambulab.com/package/2021">
         <metadata name="Application">BambuStudio-01.10.00.00</metadata>
         <metadata name="BambuStudio:3mfVersion">1</metadata>
         <metadata name="Title">\(xml(name))</metadata>
         <resources/>
         <build/>
        </model>
        """
    }

    // MARK: ZIP (stored, no compression – the G-code is read straight from the SD card)

    static func zip(_ files: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)] }
        for (name, data) in files {
            let crc = crc32(data)
            let nameBytes = Array(name.utf8)
            let offset = UInt32(out.count)
            out.append(contentsOf: le32(0x04034b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0x21) + le32(crc)
                + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(nameBytes.count) + le16(0) + nameBytes)
            out.append(data)
            central.append(contentsOf: le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0x21) + le32(crc)
                + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(nameBytes.count) + le16(0) + le16(0) + le16(0) + le16(0)
                + le32(0) + le32(offset) + nameBytes)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(contentsOf: le32(0x06054b50) + le16(0) + le16(0) + le16(files.count) + le16(files.count)
            + le32(UInt32(central.count)) + le32(centralOffset) + le16(0))
        return out
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for b in p { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFFFFFF
    }
}
