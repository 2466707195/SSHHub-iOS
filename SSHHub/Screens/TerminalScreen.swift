import SwiftUI
import SwiftTerm
import Citadel
import NIOCore

// MARK: - 交互终端（Citadel PTY + SwiftTerm 渲染）

struct TerminalScreen: View {

    let server: ServerProfile

    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = TerminalViewModel()
    @State private var showInfo = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Aurora.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer().frame(width: 2)

                VStack(alignment: .leading, spacing: 1) {
                    Text(server.title)
                        .font(AuroraFont.titleMedium)
                        .foregroundStyle(Aurora.ink)
                    Text(vm.statusLine)
                        .font(AuroraFont.labelSmall)
                        .foregroundStyle(vm.isError ? Aurora.danger : Aurora.inkSoft)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: { showInfo = true }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Aurora.inkSoft)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .background(Color.white)

            Rectangle().fill(Aurora.line.opacity(0.55)).frame(height: 1)

            ZStack {
                TerminalRepresentable(vm: vm)
                    .ignoresSafeArea(.keyboard, edges: .bottom)

                if vm.connecting {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(vm.statusLine)
                            .font(AuroraFont.bodySmall)
                            .foregroundStyle(Aurora.inkSoft)
                    }
                    .padding(20)
                    .background(AuroraShape.sheet.fill(Color.white))
                    .shadow(color: Aurora.cardShadow, radius: 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.white)
        .onAppear { vm.start(server: server) }
        .onDisappear { vm.stop() }
        .alert("连接失败", isPresented: $vm.showError) {
            Button("关闭终端", role: .destructive) { dismiss() }
        } message: {
            Text(vm.errorMessage)
        }
        .sheet(isPresented: $showInfo) {
            VStack(alignment: .leading, spacing: 10) {
                Text("连接信息")
                    .font(AuroraFont.titleLarge)
                    .foregroundStyle(Aurora.ink)
                Text(vm.infoText)
                    .font(AuroraFont.bodySmall)
                    .foregroundStyle(Aurora.inkSoft)
                    .textSelection(.enabled)
                Spacer()
                TonalButton(text: "关闭", action: { showInfo = false })
            }
            .padding(AuroraMetrics.cardPadding)
            .presentationDetents([.height(240)])
        }
    }
}

// MARK: - UIViewRepresentable 包装

struct TerminalRepresentable: UIViewRepresentable {

    @ObservedObject var vm: TerminalViewModel

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.backgroundColor = UIColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1)
        view.delegate = vm
        vm.attach(view: view)
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}
}

// MARK: - 终端视图模型

@MainActor
final class TerminalViewModel: NSObject, ObservableObject, TerminalViewDelegate {

    @Published var statusLine = "准备连接…"
    @Published var connecting = true
    @Published var isError = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var infoText = ""

    private var termView: TerminalView?
    private var client: SSHClient?
    private var writer: TTYStdinWriter?
    private var connectedEndpoint: ServerEndpoint?
    private var sessionTask: Task<Void, Never>?

    func attach(view: TerminalView) {
        termView = view
    }

    func start(server: ServerProfile) {
        statusLine = "正在选择最快的可用线路…"
        connecting = true
        isError = false

        sessionTask = Task {
            do {
                // 1. 并行探测线路，取最快
                let probes = await LineProbe.probeAll(server.endpoints)
                guard !Task.isCancelled else { return }
                guard let best = probes.first(where: { $0.isAlive }) else {
                    let detail = probes.map { "\($0.endpoint.kind.rawValue) \($0.endpoint.display)：\($0.error ?? "?")" }
                        .joined(separator: "\n")
                    await fail("所有线路都不可达\n\(detail)")
                    return
                }
                statusLine = "经 \(best.endpoint.kind.rawValue) 连接 \(best.endpoint.display)（\(best.latencyMs ?? 0)ms）…"

                // 2. SSH 连接
                let auth = try SSHHub.makeAuth(server.auth, username: server.username)
                let settings = SSHClientSettings(
                    host: best.endpoint.host,
                    port: best.endpoint.port,
                    authenticationMethod: { auth },
                    hostKeyValidator: .acceptAnything()
                )
                settings.connectTimeout = .seconds(10)
                let client = try await SSHClient.connect(to: settings)
                guard !Task.isCancelled else { await client.close(); return }
                self.client = client
                self.connectedEndpoint = best.endpoint
                self.infoText = """
                服务器：\(server.title)
                用户：\(server.username)
                线路：\(best.endpoint.kind.rawValue) \(best.endpoint.display)
                探测延迟：\(best.latencyMs ?? 0) ms
                """

                // 3. 打开 PTY 会话（交互 shell）
                statusLine = "已连接，正在打开 shell…"
                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: 80,
                    terminalRowHeight: 24,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([.ECHO: 1])
                )

                try await client.withPTY(request) { inbound, outbound in
                    self.writer = outbound
                    await MainActor.run {
                        self.connecting = false
                        self.statusLine = "\(best.endpoint.kind.rawValue) · 已连接 \(server.username)@\(best.endpoint.host)"
                        self.termView?.feed(text: "已通过 \(best.endpoint.kind.rawValue) 连接 \(server.username)@\(best.endpoint.display)\r\n输入 exit 或点左上角返回断开。\r\n\r\n")
                    }
                    for try await chunk in inbound {
                        guard !Task.isCancelled else { return }
                        switch chunk {
                        case .stdout(let buffer), .stderr(let buffer):
                            let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes) ?? []
                            let slice = ArraySlice(bytes)
                            await MainActor.run {
                                self.termView?.feed(byteArray: slice)
                            }
                        }
                    }
                }
                // shell 正常退出
                await MainActor.run {
                    self.statusLine = "会话已结束"
                    self.connecting = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await fail("连接失败：\(error.localizedDescription)")
            }
        }
    }

    private func fail(_ message: String) {
        statusLine = message
        isError = true
        connecting = false
        errorMessage = message
        showError = true
    }

    func stop() {
        sessionTask?.cancel()
        writer = nil
        Task { try? await client?.close() }
        client = nil
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let writer = self.writer
        Task {
            try? await writer?.write(ByteBuffer(bytes: data))
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        let writer = self.writer
        Task {
            try? await writer?.changeSize(cols: newCols, rows: newRows, pixelWidth: 0, pixelHeight: 0)
        }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            UIApplication.shared.open(url)
        }
    }

    func bell(source: TerminalView) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.setData(content)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        UIPasteboard.general.data(forPasteboardType: "public.utf8-plain-text")
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
