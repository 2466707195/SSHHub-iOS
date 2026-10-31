import SwiftUI

// MARK: - 服务器列表

struct ServersScreen: View {

    @EnvironmentObject private var store: ServerStore
    @State private var probes: [UUID: [EndpointProbeResult]] = [:]
    @State private var probing: Set<UUID> = []
    @State private var formTarget: ServerProfile? = nil
    @State private var showForm = false
    @State private var terminalTarget: ServerProfile? = nil
    @State private var dashboardTarget: ServerProfile? = nil

    var body: some View {
        AuroraScreen {
            AppTopBar(title: "服务器", subtitle: "\(store.servers.count) 台 · 点线路胶囊可单独测速")
        } content: {
            AuroraScrollView {
                if store.servers.isEmpty {
                    EmptyStateView(systemIcon: "server.rack", title: "还没有服务器", message: "添加一台，支持公网 / Tailscale / 局域网多条线路") {
                        PrimaryButton(text: "添加服务器", systemIcon: "plus", expands: false) {
                            formTarget = ServerProfile()
                            showForm = true
                        }
                    }
                    .padding(.top, 60)
                } else {
                    ForEach(store.servers) { server in
                        ServerCard(
                            server: server,
                            results: probes[server.id],
                            isProbing: probing.contains(server.id),
                            onProbe: { probe(server) },
                            onTerminal: { terminalTarget = server },
                            onDashboard: { dashboardTarget = server },
                            onEdit: {
                                formTarget = server
                                showForm = true
                            },
                            onDelete: { store.remove(server) }
                        )
                    }
                }
            }
        } bar: {
            GlassBar {
                HStack(spacing: 10) {
                    TonalButton(text: "全部测速", systemIcon: "bolt.horizontal", expands: false) {
                        Task { await probeAll() }
                    }
                    PrimaryButton(text: "添加服务器", systemIcon: "plus") {
                        formTarget = ServerProfile()
                        showForm = true
                    }
                }
            }
        }
        .sheet(isPresented: $showForm, onDismiss: { formTarget = nil }) {
            if let target = formTarget {
                ServerFormScreen(server: target)
                    .environmentObject(store)
            }
        }
        .fullScreenCover(item: $terminalTarget) { server in
            TerminalScreen(server: server)
        }
        .sheet(item: $dashboardTarget) { server in
            DashboardScreen(server: server)
        }
    }

    private func probe(_ server: ServerProfile) {
        guard !server.endpoints.isEmpty else { return }
        probing.insert(server.id)
        Task {
            let result = await LineProbe.probeAll(server.endpoints)
            await MainActor.run {
                probes[server.id] = result
                probing.remove(server.id)
            }
        }
    }

    private func probeAll() async {
        for server in store.servers { probe(server) }
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
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var confirmDelete = false

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
                Button(action: onProbe) {
                    Image(systemName: isProbing ? "bolt.badge.clock" : "bolt.horizontal.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isProbing ? Aurora.brand : Aurora.inkSoft)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Aurora.brand.tint(0.10)))
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
                SmallTonalButton(text: "编辑", systemIcon: "pencil", expands: false, action: onEdit)
                TextLinkButton(text: "删除", action: { confirmDelete = true })
                Spacer()
            }
        }
        .alert("删除服务器", isPresented: $confirmDelete) {
            Button("删除", role: .destructive, action: onDelete)
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定删除「\(server.title)」吗？此操作不可撤销。")
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
