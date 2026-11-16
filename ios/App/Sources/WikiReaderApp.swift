import SwiftUI
import UniformTypeIdentifiers

@main
struct WikiReaderApp: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var history = History()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(history)
        }
    }
}

/// Shows the search screen once a Wikipedia file is open, and how to add one until then.
struct RootView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        switch store.state {
        case .ready(let library):
            SearchView(library: library)
        case .missing(let reason):
            SetupView(reason: reason)
        }
    }
}

/// What to do when there is no Wikipedia file yet: where to put one, or where to find one.
struct SetupView: View {
    let reason: String
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosingFolder = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Wiki Reader").font(.largeTitle.bold())
                Text(reason)
                Text("Copy two files into this app's folder: the Wikipedia file (ending in .zim) and its index (ending in .zim.idx).")
                Text("From a Mac: connect this device, select it in the Finder, open the Files tab and drag both files onto Wiki Reader.")
                Text("They can also stay on an external drive. Connect it and choose the folder that holds them.")
                Button("Choose a folder…") { choosingFolder = true }
                    .buttonStyle(.borderedProminent)
                Button("Look again") { store.reload() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(24)
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { store.choose(folder: folder) }
        }
        // Files usually arrive while the app is in the background, so look when it comes forward.
        .onChange(of: scenePhase) { phase in
            if phase == .active { store.reload() }
        }
    }
}
