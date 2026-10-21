import SliceKit
import SwiftUI
import UniformTypeIdentifiers

/// Imports a slicer profile (OrcaSlicer / Bambu Studio JSON, e.g. from GitHub or Printables) and shows what would change.
/// Nothing is applied before the user has chosen in the profile sheet.
struct ProfileImportButton: View {
    let project: PrintProject
    @State private var picking = false
    @State private var message: String?

    var body: some View {
        Button { picking = true } label: { Image(systemName: "square.and.arrow.down.on.square") }
            .accessibilityLabel("Profil importieren")
            .accessibilityIdentifier("importProfile")
            .fileImporter(isPresented: $picking, allowedContentTypes: [.json, .plainText, .data]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { message = "Die Datei konnte nicht gelesen werden."; return }
                message = project.offerProfile(data)
            }
            .alert("Profil importieren", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(message ?? "") }
    }
}
