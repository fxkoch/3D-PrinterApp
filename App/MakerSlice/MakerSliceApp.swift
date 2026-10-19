import SwiftUI

@main
struct MakerSliceApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in
                    if url.isFileURL { model.handleIncoming(url) }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        model.printers.startPolling()
                    } else {
                        model.printers.stopPolling()
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            DiscoverView()
                .tabItem { Label("Entdecken", systemImage: "globe") }
                .tag(AppTab.discover)
            LibraryView()
                .tabItem { Label("Bibliothek", systemImage: "square.stack.3d.up") }
                .tag(AppTab.library)
            PrinterView()
                .tabItem { Label("Drucker", systemImage: "printer") }
                .tag(AppTab.printer)
        }
        .fullScreenCover(item: $model.project) { project in
            PrepareView(project: project)
        }
        .overlay {
            if model.isLoadingModel {
                ProgressView("Modell wird geladen …")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert("Hinweis", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
    }
}
