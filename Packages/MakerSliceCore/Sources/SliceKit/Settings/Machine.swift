import Foundation

/// Supported printers. Values come from the official OrcaSlicer profiles.
public enum PrinterModel: String, Codable, CaseIterable, Sendable, Identifiable {
    case snapmakerU1
    case kobraS1

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .snapmakerU1: return "Snapmaker U1"
        case .kobraS1: return "Anycubic Kobra S1"
        }
    }

    public var machine: MachineProfile {
        switch self {
        case .snapmakerU1: return .snapmakerU1
        case .kobraS1: return .kobraS1
        }
    }
}

/// How a printer handles several materials.
public enum MultiMaterialKind: String, Codable, Sendable {
    /// Four independent tool heads (Snapmaker U1) – no purge needed.
    case toolChanger
    /// One nozzle fed by a filament switcher (Anycubic ACE Pro) – needs purging.
    case filamentSwitcher
}

public struct MachineProfile: Equatable, Sendable {
    public var model: PrinterModel
    public var bedSize: Double
    public var maxHeight: Double
    public var toolCount: Int
    public var multiMaterial: MultiMaterialKind
    /// Name used in the filament library for printer-specific profiles.
    public var filamentScope: String
    public var supportsPlateTypes: [PlateType]
    /// Short label for slots: "T1" on the U1, "Slot 1" on the ACE.
    public var slotLabel: String

    public static let snapmakerU1 = MachineProfile(
        model: .snapmakerU1, bedSize: 270, maxHeight: 270, toolCount: 4, multiMaterial: .toolChanger,
        filamentScope: "u1", supportsPlateTypes: [.texturedPEI, .highTemp], slotLabel: "T"
    )

    public static let kobraS1 = MachineProfile(
        model: .kobraS1, bedSize: 250, maxHeight: 250, toolCount: 4, multiMaterial: .filamentSwitcher,
        filamentScope: "kobraS1", supportsPlateTypes: [.texturedPEI], slotLabel: "Slot "
    )

    /// Process defaults from "0.20mm Standard" of the respective Orca profile.
    func applyDefaults(to s: inout PrintSettings) {
        switch model {
        case .snapmakerU1:
            s.firstLayerHeight = 0.25
            s.travelSpeed = 500
            s.firstLayerInfillSpeed = 105
            s.retractSpeed = 30
            s.primeTower = false
            s.skirtLoops = 1
        case .kobraS1:
            s.firstLayerHeight = 0.2
            s.travelSpeed = 300
            s.firstLayerInfillSpeed = 80
            s.retractSpeed = 40
            s.primeTower = true
            s.skirtLoops = 0
            s.plateType = .texturedPEI
            s.enableTimelapse = false
        }
    }
}
