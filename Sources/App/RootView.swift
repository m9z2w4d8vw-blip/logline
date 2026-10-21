import SwiftUI

enum RootTab: Hashable {
    case feed
    case accounts
    case settings
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: RootTab = .feed

    var body: some View {
        TabView(selection: $tab) {
            FeedView()
                .tabItem { Label("Feed", systemImage: "ticket") }
                .tag(RootTab.feed)
                .badge(model.unreadCount)

            AccountsView()
                .tabItem { Label("Accounts", systemImage: "person.2") }
                .tag(RootTab.accounts)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(RootTab.settings)
                .badge(model.availableUpdate == nil ? 0 : 1)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .background && tab == .feed {
                model.markAllRead()
            }
            model.scenePhaseChanged(phase)
        }
        .onChange(of: tab) { previous, _ in
            if previous == .feed {
                model.markAllRead()
            }
        }
        .sheet(item: $model.presentedItem) { item in
            ActivityDetailView(item: item)
                .environmentObject(model)
        }
    }
}
