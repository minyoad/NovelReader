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
                .task { await app.bootstrap() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @State private var selection: Tab = .library

    enum Tab: Hashable {
        case library
        case search
        case sources
        case settings
    }

    var body: some View {
        TabView(selection: $selection) {
            LibraryView()
                .tabItem { Label("书架", systemImage: "books.vertical") }
                .tag(Tab.library)

            SearchView()
                .tabItem { Label("找书", systemImage: "magnifyingglass") }
                .tag(Tab.search)

            SourcesView()
                .tabItem { Label("书源", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(Tab.sources)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .overlay(alignment: .bottom) {
            if let banner = app.banner {
                Banner(text: banner.text, isError: banner.isError)
                    .padding(.bottom, 70)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.banner?.text)
    }
}
#endif
