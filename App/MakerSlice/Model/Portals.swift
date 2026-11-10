import Foundation
import SliceKit

/// Websites with free 3D models. They open in the app's browser (the login stays saved) and every STL/3MF/OBJ/ZIP
/// download is taken over into the library automatically.
struct Portal: Identifiable, Hashable {
    enum Group: Int, CaseIterable {
        case maker, popular, more

        var title: String {
            switch self {
            case .maker: return "Von den Druckerherstellern"
            case .popular: return "Beliebt"
            case .more: return "Weitere Quellen"
            }
        }
    }

    var id: String { name }
    let name: String
    let url: URL
    let symbol: String
    let note: String
    let group: Group
    /// Printer this portal belongs to (shown first when that printer is selected).
    var forPrinter: PrinterModel?

    private static func make(_ name: String, _ url: String, _ symbol: String, _ group: Group, _ note: String,
                             printer: PrinterModel? = nil) -> Portal {
        Portal(name: name, url: URL(string: url)!, symbol: symbol, note: note, group: group, forPrinter: printer)
    }

    static let all: [Portal] = [
        // Printer makers: the libraries built into Anycubic Slicer Next and Snapmaker Orca.
        make("Anycubic Maker Online", "https://www.makeronline.com/en/", "a.circle", .maker,
             "Die Modellbibliothek von Anycubic (auch in Slicer Next eingebaut). Kostenlose Modelle, passend für den Kobra S1.", printer: .kobraS1),
        make("Snapmaker Modelle", "https://models.snapmaker.com", "s.circle", .maker,
             "Die Modellbibliothek von Snapmaker (auch in Snapmaker Orca und der Snapmaker-App): druckfertige, oft mehrfarbige Modelle für den U1.", printer: .snapmakerU1),
        make("Creality Cloud", "https://www.crealitycloud.com/", "cloud", .maker, "Modellbibliothek von Creality."),

        // Popular
        make("MakerWorld", "https://makerworld.com/de", "cube.transparent", .popular,
             "Bambu Lab – 3MF mit Druckprofilen, viele Mehrfarb-Modelle. Anmeldung nötig für den Download."),
        make("Printables", "https://www.printables.com/", "printer", .popular, "Prusa – große Community, Downloads ohne Konto."),
        make("Thingiverse", "https://www.thingiverse.com/", "wrench.and.screwdriver", .popular, "Der Klassiker. Für Downloads ist ein Konto nötig."),
        make("Thangs", "https://thangs.com/", "magnifyingglass", .popular, "Durchsucht viele Portale gleichzeitig."),
        make("MyMiniFactory", "https://www.myminifactory.com/", "figure.stand", .popular, "Geprüfte, druckbare Modelle, viele Miniaturen."),
        make("Cults3D", "https://cults3d.com/de", "sparkles", .popular,
             "Design und Kunst; viele Modelle kostenpflichtig, es gibt auch Gratis-Modelle."),

        // More
        make("Yeggi", "https://www.yeggi.com/", "text.magnifyingglass", .more, "Meta-Suche über viele Portale (verlinkt auf die Quellen)."),
        make("STLFinder", "https://www.stlfinder.com/", "doc.text.magnifyingglass", .more, "Suchmaschine für STL-Dateien aus vielen Portalen."),
        make("GrabCAD", "https://grabcad.com/library", "gearshape.2", .more, "Technische Bauteile von Ingenieuren. Konto nötig."),
        make("Pinshape", "https://www.pinshape.com/", "pin", .more, "Community für Design und Funktionsteile."),
        make("CGTrader (gratis)", "https://www.cgtrader.com/free-3d-print-models", "square.stack.3d.up", .more, "Gratis-Druckmodelle von CGTrader."),
        make("NIH 3D", "https://3d.nih.gov/", "cross.case", .more, "Wissenschaft und Medizin, kostenlos vom US-Gesundheitsinstitut."),
        make("Smithsonian 3D", "https://3d.si.edu/", "building.columns", .more, "Museumsstücke als 3D-Scans, frei nutzbar."),
        make("Sketchfab", "https://sketchfab.com/features/free-3d-models", "rotate.3d", .more, "Freie 3D-Modelle (Download je nach Lizenz)."),
        make("Instructables", "https://www.instructables.com/3D-Printing/", "lightbulb", .more, "Bauanleitungen mit druckbaren Dateien."),
    ]

    /// Portals of a group; the selected printer's own portal comes first.
    static func portals(in group: Group, preferring printer: PrinterModel?) -> [Portal] {
        all.filter { $0.group == group }.sorted { a, b in
            let aFirst = a.forPrinter != nil && a.forPrinter == printer
            let bFirst = b.forPrinter != nil && b.forPrinter == printer
            return aFirst && !bFirst
        }
    }
}
