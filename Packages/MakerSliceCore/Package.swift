// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MakerSliceCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SliceKit", targets: ["SliceKit"]),
        .library(name: "PrinterKit", targets: ["PrinterKit"]),
        .library(name: "MakerWorldKit", targets: ["MakerWorldKit"]),
    ],
    targets: [
        .target(
            name: "CClipper",
            path: "Sources/CClipper",
            exclude: ["clipper2/LICENSE_Clipper2.txt"],
            cxxSettings: [
                .headerSearchPath("clipper2"),
                .unsafeFlags(["-O2"], .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "CZip",
            path: "Sources/CZip",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(name: "SliceKit", dependencies: ["CClipper", "CZip"], resources: [.process("Resources")]),
        .target(name: "PrinterKit"),
        .target(name: "MakerWorldKit"),
        .testTarget(name: "SliceKitTests", dependencies: ["SliceKit"]),
        .testTarget(name: "PrinterKitTests", dependencies: ["PrinterKit"]),
        .testTarget(name: "MakerWorldKitTests", dependencies: ["MakerWorldKit"]),
        // Virtual prints against simulated printers (skipped unless the simulators run, see tools/virtualprinters).
        .testTarget(name: "VirtualPrinterTests", dependencies: ["SliceKit", "PrinterKit"]),
    ],
    cxxLanguageStandard: .cxx17
)
