import SwiftUI
import UniformTypeIdentifiers

@main
struct WikiReaderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()
    @StateObject private var history = History()
    @StateObject private var downloads = Downloads.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(history)
                .environmentObject(downloads)
        }
    }
}

/// Shows the search screen once a Wikipedia file is open, and how to add one until then.
struct RootView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var history: History
    @EnvironmentObject private var downloads: Downloads
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch store.state {
            case .ready(let library):
                // A different file gets a new search screen, not the old one's articles.
                SearchView(library: library).id(library.stamp)
            case .missing(let reason):
                SetupView(reason: reason)
            }
        }
        // Files arrive, and are replaced, while the app is in the background. So it lets go of
        // them on the way out and looks again when it comes forward.
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: store.reload()
            case .background:
                history.save()
                store.suspend()
            default: break
            }
        }
        // A first Wikipedia that has just arrived is opened at once, in place of the downloads
        // screen. One that arrives while another is open waits for the reader to choose Open, so
        // as not to pull them out of it.
        .onChange(of: downloads.arrivals) { _ in
            if case .missing = store.state {
                store.reload()
                if case .ready = store.state { downloads.showing = false }
            }
        }
        // Here rather than on the screens beneath, which can change while it is up.
        .sheet(isPresented: $downloads.showing) {
            NavigationStack { DownloadsView() }
        }
    }
}

/// What to do when there is no Wikipedia file yet: where to put one, or where to find one.
struct SetupView: View {
    let reason: String
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var downloads: Downloads
    @State private var choosingFolder = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Wiki Reader").font(.largeTitle.bold())
                Text(reason)
                Text("Download Wikipedia here, over Wi-Fi. It comes in several sizes, from under 1 GB to over 50 GB.")
                Button("Download Wikipedia…") { downloads.showing = true }
                    .buttonStyle(.borderedProminent)
                Text("Or copy two files into this app's folder: the Wikipedia file (ending in .zim) and its index (ending in .zim.idx).")
                Text("From a Mac: connect this device, select it in the Finder, open the Files tab and drag both files onto Wiki Reader.")
                Text("They can also stay on an external drive. Connect it and choose the folder that holds them.")
                Button("Choose a folder…") { choosingFolder = true }
                    .buttonStyle(.bordered)
                Button("Look again") { store.reload() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(24)
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { store.choose(folder: folder) }
        }

    }
}
