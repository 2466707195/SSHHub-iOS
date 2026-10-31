import SwiftUI

// MARK: - 服务器列表

struct ServersScreen: View {

    @EnvironmentObject private var store: ServerStore
    @State private var terminalTarget: ServerProfile? = nil
    @State private var dashboardTarget: ServerProfile? = nil

    var body: some View {
        AuroraScreen {
            AppTopBar(title: "服务器", subtitle: "\(store.servers.count) 台 · 点线路胶囊可单独测速 · 添加/编辑在「设置」")
        } content: {
            AuroraScrollView {
                if store.servers.isEmpty {
                    EmptyStateView(systemIcon: "server.rack", title: "还没有服务器", message: "到「设置 → 服务器管理」添加\n支持公网 / Tailscale / 局域网多条线路")
                        .padding(.top, 60)
                } else {
                    ForEach(store.servers) { server in
                        ServerCard(
                            server: server,
                            results: store.probes[server.id],
                            isProbing: store.probing.contains(server.id),
                            onProbe: { store.probe(server) },
                            onTerminal: { terminalTarget = server },
                            onDashboard: { dashboardTarget = server }
                        )
                    }
                }
            }
        } bar: {
            EmptyView()
        }
        .fullScreenCover(item: $terminalTarget) { server in
            TerminalScreen(server: server)
        }
        .sheet(item: $dashboardTarget) { server in
            DashboardScreen(server: server)
        }
    }
}

// MARK: - 单台服务器卡片

private struct ServerCard: View {

    let server: ServerProfile
    let results: [EndpointProbeResult]?
    let isProbing: Bool
    let onProbe: () -> Void
    let onTerminal: () -> Void
    let onDashboard: () -> Void

    var body: some View {
        SectionCard {
            HStack(spacing: 12) {
                Monogram(name: server.title, tone: Aurora.brand)
                VStack(alignment: .leading, spacing: 3) {
                    Text(server.title)
                        .font(AuroraFont.titleMedium)
                        .foregroundStyle(Aurora.ink)
                    Text("\(server.username) · \(authLabel)")
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.inkSoft)
                }
                Spacer()
                // 玻璃圆钮：整卡测速
                Button(action: onProbe) {
                    Image(systemName: isProbing ? "bolt.badge.clock" : "bolt.horizontal.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isProbing ? Aurora.brand : Aurora.inkSoft)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.ultraThinMaterial))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 0.8))
                        .contentShape(Circle())
                }
                .buttonStyle(PressScaleStyle())
                .disabled(isProbing)
            }

            Spacer().frame(height: 12)

            // 线路胶囊
            FlowPills(results: results, endpoints: server.endpoints)

            Spacer().frame(height: 14)

            HStack(spacing: 8) {
                TonalButton(text: "终端", systemIcon: "terminal", expands: false, action: onTerminal)
                SmallTonalButton(text: "监控", systemIcon: "gauge.with.needle", expands: false, action: onDashboard)
                Spacer()
            }
        }
    }

    private var authLabel: String {
        switch server.auth {
        case .password(let p): return p.isEmpty ? "密码未设置" : "密码"
        case .ed25519Key: return "Ed25519 密钥"
        case .rsaKey: return "RSA 密钥"
        }
    }
}

// MARK: - 线路胶囊流式排列

struct FlowPills: View {

    let results: [EndpointProbeResult]?
    let endpoints: [ServerEndpoint]

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 6)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(endpoints) { ep in
                pill(for: ep)
            }
        }
    }

    @ViewBuilder
    private func pill(for ep: ServerEndpoint) -> some View {
        let result = results?.first { $0.endpoint.id == ep.id }
        let color: Color = {
            if let r = result {
                if r.isAlive { return Aurora.success }
                return Aurora.danger
            }
            return Aurora.muted
        }()
        let text: String = {
            if let r = result {
                if let ms = r.latencyMs { return "\(ep.kind.rawValue) \(ms)ms" }
                return "\(ep.kind.rawValue) 不可达"
            }
            return "\(ep.kind.rawValue) \(ep.display)"
        }()

        HStack(spacing: 5) {
            if result == nil {
                Image(systemName: ep.kind.systemIcon)
                    .font(.system(size: 9))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Capsule().fill(color.tint(0.13)))
        .foregroundStyle(color)
    }
}
