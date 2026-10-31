import SwiftUI

// MARK: - 设置页

struct SettingsScreen: View {

    @EnvironmentObject private var store: ServerStore

    @State private var formTarget: ServerProfile? = nil
    @State private var showForm = false
    @State private var deleteTarget: ServerProfile? = nil

    var body: some View {
        AuroraScreen {
            AppTopBar(title: "设置", subtitle: "SSHHub v1.0.1")
        } content: {
            AuroraScrollView(bottomInset: 40) {
                manageCard

                SectionCard {
                    Label("三种线路是怎么工作的", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(AuroraFont.titleSmall)
                        .foregroundStyle(Aurora.ink)
                    Spacer().frame(height: 10)
                    lineRow(icon: "globe", color: Aurora.info, title: "公网", desc: "服务器有公网 IP 时任意网络可用")
                    lineRow(icon: "dot.radiowaves.left.and.right", color: Aurora.success, title: "Tailscale", desc: "手机需登录同一 Tailscale 账号（装 Tailscale App 并开启 VPN）")
                    lineRow(icon: "house", color: Aurora.warning, title: "局域网", desc: "手机与服务器在同一 Wi-Fi 时可用")
                    Spacer().frame(height: 10)
                    Text("连接时 App 会并行探测所有线路，自动选延迟最低的可达线路。")
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.inkSoft)
                }

                SectionCard {
                    Label("安全说明", systemImage: "lock.shield")
                        .font(AuroraFont.titleSmall)
                        .foregroundStyle(Aurora.ink)
                    Spacer().frame(height: 10)
                    Text("· 密码与私钥只保存在手机本地（App 沙盒），不上传任何服务器\n· 连接使用 SSH 加密通道\n· 首次连接不做主机指纹校验（homelab 场景够用，如需严格校验请配指纹）")
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.inkSoft)
                        .lineSpacing(3)
                }

                SectionCard {
                    Label("数据", systemImage: "externaldrive")
                        .font(AuroraFont.titleSmall)
                        .foregroundStyle(Aurora.ink)
                    Spacer().frame(height: 10)
                    HStack {
                        Text("已保存 \(store.servers.count) 台服务器（本机 servers.json）")
                            .font(AuroraFont.bodySmall)
                            .foregroundStyle(Aurora.inkSoft)
                        Spacer()
                    }
                }
            }
        } bar: {
            GlassBar {
                HStack {
                    Text("SSHHub · 多线路 SSH 管理器")
                        .font(AuroraFont.labelSmall)
                        .foregroundStyle(Aurora.muted)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .sheet(isPresented: $showForm, onDismiss: { formTarget = nil }) {
            if let target = formTarget {
                ServerFormScreen(server: target)
                    .environmentObject(store)
            }
        }
        .confirmationDialog(
            "删除「\(deleteTarget?.title ?? "")」？",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let target = deleteTarget { store.remove(target) }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("此操作不可撤销。")
        }
    }

    // MARK: 服务器管理卡片

    private var manageCard: some View {
        SectionCard {
            HStack(spacing: 10) {
                Label("服务器管理", systemImage: "server.rack")
                    .font(AuroraFont.titleSmall)
                    .foregroundStyle(Aurora.ink)
                Spacer()
                SmallTonalButton(text: "全部测速", systemIcon: "bolt.horizontal", action: { store.probeAll() })
            }
            Spacer().frame(height: 6)

            if store.servers.isEmpty {
                Text("还没有服务器，点下面按钮添加第一台。")
                    .font(AuroraFont.bodySmall)
                    .foregroundStyle(Aurora.inkSoft)
            } else {
                ForEach(store.servers) { server in
                    HStack(spacing: 10) {
                        Monogram(name: server.title, tone: Aurora.brand, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.title)
                                .font(AuroraFont.labelMedium)
                                .foregroundStyle(Aurora.ink)
                                .lineLimit(1)
                            Text("\(server.endpoints.count) 条线路")
                                .font(AuroraFont.labelSmall)
                                .foregroundStyle(Aurora.muted)
                        }
                        Spacer()
                        SmallTonalButton(text: "编辑", systemIcon: "pencil", action: { openForm(server) })
                        SmallDangerButton(text: "删除", action: { deleteTarget = server })
                    }
                    .padding(.vertical, 4)
                }
            }

            Spacer().frame(height: 12)
            PrimaryButton(text: "添加服务器", systemIcon: "plus") {
                openForm(ServerProfile())
            }
        }
    }

    private func openForm(_ server: ServerProfile) {
        formTarget = server
        showForm = true
    }

    private func lineRow(icon: String, color: Color, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AuroraFont.titleSmall)
                    .foregroundStyle(Aurora.ink)
                Text(desc)
                    .font(AuroraFont.bodySmall)
                    .foregroundStyle(Aurora.inkSoft)
            }
        }
    }
}
