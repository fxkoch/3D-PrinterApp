import Foundation

/// Many portals deliver models as a ZIP full of STL/3MF/OBJ files. This pulls the printable files out.
public enum ModelArchive {
    /// Printable model files inside a ZIP. Returns nil when the data is not a plain ZIP of models
    /// (a 3MF is a ZIP too, but it is one model, not a collection).
    public static func modelFiles(in data: Data) -> [(name: String, data: Data)]? {
        guard let zip = try? ZipArchive(data: data) else { return nil }
        if zip.entry("3D/3dmodel.model") != nil || zip.entry("[Content_Types].xml") != nil { return nil }
        var result: [(String, Data)] = []
        for entry in zip.entries {
            let path = entry.path
            let name = (path as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            guard ["stl", "3mf", "obj"].contains(ext), !name.hasPrefix("."), !path.hasPrefix("__MACOSX/"),
                  let contents = try? zip.extract(entry), !contents.isEmpty else { continue }
            result.append((name, contents))
        }
        return result.isEmpty ? nil : result.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }
}
