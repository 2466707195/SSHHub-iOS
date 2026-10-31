import SwiftUI
import Citadel

// MARK: - 监控面板（SSH exec）

struct DashboardScreen: View {

    let server: ServerProfile

    @Environment(\.dismiss) private var dismiss
    @State private var stats: ServerStats? = nil
    @State private var connectedEndpoint: ServerEndpoint? = nil
    @State private var status = "正在选择线路并连接…"
    @State private var isError = false
    @State private var client: SSHClient? = nil
    @State private var loading = false

    @State private var cmdText = ""
    @State private var cmdOutput = ""
    @State private var cmdRunning = false

    var body: some View {
        AuroraScreen {
            AppTopBar(
                title: server.title,
                subtitle: connectedEndpoint.map { "\($0.kind.rawValue) · \($0.display)" } ?? "未连接"
            )
        } content: {
            AuroraScrollView(bottomInset: 40) {
                if let stats {
                    statsCards(stats)
                    runCommandCard
                } else if isError {
                    EmptyStateView(systemIcon: "wifi.exclamationmark", title: "连接失败", message: status)
                    TonalButton(text: "重试", systemIcon: "arrow.clockwise", expands: false) { load() }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(status)
                            .font(AuroraFont.bodySmall)
                            .foregroundStyle(Aurora.inkSoft)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                }
            }
        } bar: {
            GlassBar {
                HStack(spacing: 10) {
                    TonalButton(text: "刷新", systemIcon: "arrow.clockwise", enabled: !loading, expands: false) { load() }
                    DangerTonalButton(text: "断开", systemIcon: "xmark", expands: false) {
                        Task { try? await client?.close() }
                        dismiss()
                    }
                }
            }
        }
        .onAppear { load() }
        .onDisappear { Task { try? await client?.close() } }
    }

    // MARK: - 卡片

    @ViewBuilder
    private func statsCards(_ s: ServerStats) -> some View {
        HStack(spacing: 10) {
            MetricCard(title: "主机", value: s.hostname, icon: "server.rack")
            MetricCard(title: "运行时长", value: s.uptime, icon: "clock")
        }
        HStack(spacing: 10) {
            MetricCard(title: "CPU 核心数", value: s.cpuCores, icon: "cpu")
            MetricCard(title: "负载（1/5/15min）", value: s.load, icon: "waveform.path.ecg")
        }
        if let pct = s.memUsedPercent {
            BarCard(title: "内存", subtitle: s.memLine, percent: pct, color: pct > 85 ? Aurora.rose : Aurora.brand)
        }
        if let pct = s.diskUsedPercent {
            BarCard(title: "磁盘", subtitle: s.diskLine, percent: pct, color: pct > 85 ? Aurora.rose : Aurora.teal)
        }
        SectionCard {
            HStack {
                Text("内核")
                    .font(AuroraFont.labelMedium)
                    .foregroundStyle(Aurora.inkSoft)
                Spacer()
                Text(s.kernel)
                    .font(AuroraFont.labelMedium)
                    .foregroundStyle(Aurora.ink)
            }
        }
    }

    private var runCommandCard: some View {
        SectionCard {
            Text("执行命令")
                .font(AuroraFont.titleSmall)
                .foregroundStyle(Aurora.inkSoft)
            Spacer().frame(height: 10)
            HStack(spacing: 8) {
                AuroraTextField(placeholder: "如：uname -a", text: $cmdText, systemIcon: "chevron.right")
                PrimaryButton(text: "运行", enabled: !cmdText.isEmpty && !cmdRunning, expands: false) {
                    runCmd()
                }
            }
            if !cmdOutput.isEmpty {
                Spacer().frame(height: 10)
                ScrollView {
                    Text(cmdOutput)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Aurora.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
            }
        }
    }

    // MARK: - 动作

    private func load() {
        loading = true
        isError = false
        status = "正在选择线路并连接…"
        Task {
            do {
                let (c, ep) = try await SSHHub.connect(server: server, endpoint: nil, timeout: 8)
                await MainActor.run {
                    client = c
                    connectedEndpoint = ep
                    status = "已连接"
                }
                let s = await StatsCollector.collect(client: c)
                await MainActor.run {
                    stats = s
                    loading = false
                }
            } catch {
                await MainActor.run {
                    isError = true
                    status = error.localizedDescription
                    loading = false
                }
            }
        }
    }

    private func runCmd() {
        let command = cmdText
        cmdRunning = true
        Task {
            guard let client else { return }
            let out = await SSHHub.run(client, command)
            await MainActor.run {
                cmdOutput = "❯ \(command)\n" + out
                cmdRunning = false
            }
        }
    }
}

// MARK: - 指标小卡

struct MetricCard: View {

    let title: String
    let value: String
    let icon: String

    var body: some View {
        SectionCard {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Aurora.brand)
                Text(title)
                    .font(AuroraFont.labelSmall)
                    .foregroundStyle(Aurora.inkSoft)
            }
            Spacer().frame(height: 8)
            Text(value)
                .font(AuroraFont.titleSmall)
                .foregroundStyle(Aurora.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
    }
}

struct BarCard: View {

    let title: String
    let subtitle: String
    let percent: Double
    let color: Color

    var body: some View {
        SectionCard {
            HStack {
                Text(title)
                    .font(AuroraFont.labelMedium)
                    .foregroundStyle(Aurora.inkSoft)
                Spacer()
                StatusPill(text: String(format: "%.0f%%", percent), color: color)
            }
            Spacer().frame(height: 8)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Aurora.surfaceVariant)
                    Capsule().fill(color).frame(width: geo.size.width * min(percent / 100, 1))
                }
            }
            .frame(height: 8)
            Spacer().frame(height: 8)
            Text(subtitle)
                .font(AuroraFont.labelSmall)
                .foregroundStyle(Aurora.muted)
        }
    }
}
