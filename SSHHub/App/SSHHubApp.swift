import SwiftUI

@main
struct SSHHubApp: App {
    @StateObject private var store = ServerStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.light)
        }
    }
}

enum AppTab: Hashable {
    case servers
    case settings
}

struct RootView: View {
    @State private var tab: AppTab = .servers

    var body: some View {
        AuroraTabHost(selection: $tab, items: [
            AuroraTabSpec(id: AppTab.servers, title: "服务器", icon: "server.rack"),
            AuroraTabSpec(id: AppTab.settings, title: "设置", icon: "gearshape"),
        ]) { current in
            switch current {
            case .servers: ServersScreen()
            case .settings: SettingsScreen()
            }
        }
        .background(Color.white)
    }
}
