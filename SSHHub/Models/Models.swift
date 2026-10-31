import Foundation

// MARK: - 数据模型

/// 线路类型
enum EndpointKind: String, Codable, CaseIterable, Identifiable {
    case publicNet = "公网"
    case tailscale = "Tailscale"
    case lan = "局域网"

    var id: String { rawValue }

    /// 胶囊配色（按 Aurora 语义色）
    var tintLevel: Int {
        switch self {
        case .publicNet: return 1   // info 蓝
        case .tailscale: return 2   // success 绿
        case .lan: return 3         // warning 橙
        }
    }

    var systemIcon: String {
        switch self {
        case .publicNet: return "globe"
        case .tailscale: return "dots.and.line.waveform.and.cursorarrow"
        case .lan: return "house"
        }
    }
}

/// 一条连接线路
struct ServerEndpoint: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var kind: EndpointKind = .publicNet
    var host: String = ""
    var port: Int = 22

    var display: String { "\(host):\(port)" }
}

/// 认证方式
enum AuthMethod: Codable, Equatable {
    case password(String)
    case ed25519Key(String)       // OpenSSH PEM 文本
    case rsaKey(String)

    var label: String {
        switch self {
        case .password: return "密码"
        case .ed25519Key: return "Ed25519 密钥"
        case .rsaKey: return "RSA 密钥"
        }
    }
}

/// 服务器档案
struct ServerProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = ""
    var username: String = "root"
    var auth: AuthMethod = .password("")
    var endpoints: [ServerEndpoint] = []

    var title: String { name.isEmpty ? "未命名服务器" : name }
}

// MARK: - 服务器仓库（JSON 持久化）

@MainActor
final class ServerStore: ObservableObject {

    @Published var servers: [ServerProfile] = [] { didSet { persist() } }
    /// 线路测速结果：serverId -> 各线路探测结果
    @Published var probes: [UUID: [EndpointProbeResult]] = [:]
    /// 正在测速的服务器
    @Published var probing: Set<UUID> = []

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("servers.json")
    }

    init(seedIfEmpty: Bool = true) {
        load()
        if servers.isEmpty && seedIfEmpty { seed() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let list = try? JSONDecoder().decode([ServerProfile].self, from: data) else { return }
        servers = list
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    func upsert(_ server: ServerProfile) {
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
        } else {
            servers.append(server)
        }
    }

    func remove(_ server: ServerProfile) {
        servers.removeAll { $0.id == server.id }
        probes[server.id] = nil
    }

    /// 测一台服务器的所有线路
    func probe(_ server: ServerProfile) {
        guard !server.endpoints.isEmpty, !probing.contains(server.id) else { return }
        probing.insert(server.id)
        Task {
            let result = await LineProbe.probeAll(server.endpoints)
            self.probes[server.id] = result
            self.probing.remove(server.id)
        }
    }

    /// 全部服务器测速
    func probeAll() {
        for server in servers { probe(server) }
    }

    /// 首次启动的示例数据（占位密码，用户需在 App 内填写真实凭证）
    private func seed() {
        servers = [
            ServerProfile(
                name: "Armbian 盒子",
                username: "root",
                auth: .password(""),
                endpoints: [
                    ServerEndpoint(kind: .tailscale, host: "100.77.190.58", port: 2222),
                    ServerEndpoint(kind: .lan, host: "192.168.10.6", port: 2222),
                ]
            ),
            ServerProfile(
                name: "阿里云",
                username: "root",
                auth: .password(""),
                endpoints: [
                    ServerEndpoint(kind: .publicNet, host: "8.160.187.185", port: 22),
                ]
            ),
        ]
    }
}
