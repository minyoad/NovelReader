#if canImport(SwiftUI)
import SwiftUI
import NovelKit

@main
struct NovelReaderApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    /// Which tab the bar shows. Local to the bar, not shared: search is no
    /// longer a tab, so nothing outside needs to change it.
    @State private var tab: AppTab = .library
    /// The book to reopen, once the shelf and settings are on screen.
    ///
    /// Held separately from the launch task so that closing the reader leaves
    /// the shelf behind instead of immediately reopening the book.
    @State private var resumedBook: Book?
    /// The resume runs once per process: `.task` can fire again after the scene
    /// is rebuilt, and reopening the reader mid-session would be hostile.
    @State private var didResume = false
    /// Set when the user switches away from the shelf before the launch task
    /// finishes. Sync can take seconds; if the tap lands on 设置 first, the
    /// reader must not pop up over it afterwards.
    @State private var userLeftShelf = false

    var body: some View {
        TabView(selection: $tab) {
            LibraryView()
                .tabItem { Label("书架", systemImage: "books.vertical") }
                .tag(AppTab.library)

            ExploreView()
                .tabItem { Label("发现", systemImage: "safari") }
                .tag(AppTab.explore)

            SourcesView()
                .tabItem { Label("书源", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(AppTab.sources)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        // Search is reached from the discover page rather than from the bar.
        // It has to be outside `TabView`: a child without `.tabItem` still
        // reserves a blank slot, which leaves a dead gap in the bar.
        .sheet(isPresented: $app.isSearching) {
            SearchView()
        }
        .overlay(alignment: .bottom) {
            if let banner = app.banner {
                Banner(text: banner.text, isError: banner.isError)
                    .padding(.bottom, 70)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.banner?.text)
        // Restoring is a full-screen cover rather than a navigation push: it
        // opens over whatever tab is selected, and closing it reveals that tab
        // untouched instead of leaving a reader in the stack.
        .fullScreenCover(item: $resumedBook) { book in
            ReaderView(book: book, app: app)
        }
        .task {
            // Loading the shelf and opening the last book are one flow: the
            // resume decision needs the books that `bootstrap` fetches.
            await app.bootstrap()
            // Sync before resuming: the progress being resumed may have been
            // advanced on the other device. Bounded, because a slow or
            // unreachable server must not leave the app on the shelf for
            // minutes while the user wonders whether it launched at all.
            await app.runStartupSync()
            resumeLastReading()
        }
        .onChange(of: tab) { _, newTab in
            // Any deliberate navigation beats a deferred auto-resume. Once the
            // user is on 设置 or 发现, opening a book over that screen is
            // taking the app away from them.
            if newTab != .library {
                userLeftShelf = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding is the last moment the app is guaranteed to run;
            // it is where a sync can still reach the network without holding
            // the user on launch.
            if phase == .background {
                Task { await app.runSync() }
            }
        }
    }

    /// Reopens the book that was most recently read.
    ///
    /// Everything here is best effort. An empty shelf, the feature switched off,
    /// or a fresh install all simply leave the library on screen — the launch
    /// path must never block on the network, and a book whose chapters fail to
    /// load shows the reader's own error rather than a stuck app.
    private func resumeLastReading() {
        guard !didResume else { return }
        didResume = true
        // The user got somewhere on their own while sync was running; do not
        // yank them into a book from under it.
        guard !userLeftShelf else { return }
        guard app.settings.reading.resumeLastReading,
              let book = ReadingRecents.mostRecent(in: app.books) else { return }
        resumedBook = book
    }
}
#endif
