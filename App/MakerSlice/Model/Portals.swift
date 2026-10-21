import Foundation

/// Websites with free 3D models. They open in the app's browser (the login stays saved) and every STL/3MF/OBJ/ZIP
/// download is taken over into the library automatically.
struct Portal: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let url: URL
    let symbol: String
    let note: String

    static let all: [Portal] = [
        Portal(name: "MakerWorld", url: URL(string: "https://makerworld.com/de")!, symbol: "cube.transparent",
               note: "Bambu Lab – 3MF mit Druckprofilen. Anmeldung nötig für den Download."),
        Portal(name: "Printables", url: URL(string: "https://www.printables.com/")!, symbol: "printer",
               note: "Prusa – große Community, Downloads ohne Konto."),
        Portal(name: "Thingiverse", url: URL(string: "https://www.thingiverse.com/")!, symbol: "wrench.and.screwdriver",
               note: "Der Klassiker. Für Downloads ist ein Konto nötig."),
        Portal(name: "Thangs", url: URL(string: "https://thangs.com/")!, symbol: "magnifyingglass",
               note: "Durchsucht viele Portale gleichzeitig."),
        Portal(name: "MyMiniFactory", url: URL(string: "https://www.myminifactory.com/")!, symbol: "figure.stand",
               note: "Geprüfte, druckbare Modelle, viele Miniaturen."),
        Portal(name: "Cults3D", url: URL(string: "https://cults3d.com/de")!, symbol: "sparkles",
               note: "Design und Kunst; viele Modelle kostenpflichtig, es gibt auch Gratis-Modelle."),
        Portal(name: "Creality Cloud", url: URL(string: "https://www.crealitycloud.com/model-library")!, symbol: "cloud",
               note: "Modellbibliothek von Creality."),
        Portal(name: "Yeggi", url: URL(string: "https://www.yeggi.com/")!, symbol: "text.magnifyingglass",
               note: "Meta-Suche über viele Portale (verlinkt auf die Quellen)."),
        Portal(name: "GrabCAD", url: URL(string: "https://grabcad.com/library")!, symbol: "gearshape.2",
               note: "Technische Bauteile von Ingenieuren. Konto nötig."),
        Portal(name: "CGTrader (gratis)", url: URL(string: "https://www.cgtrader.com/free-3d-print-models")!, symbol: "square.stack.3d.up",
               note: "Gratis-Druckmodelle von CGTrader."),
        Portal(name: "Sketchfab", url: URL(string: "https://sketchfab.com/features/free-3d-models")!, symbol: "rotate.3d",
               note: "Freie 3D-Modelle (oft nur Ansicht, Download je nach Lizenz)."),
    ]
}
