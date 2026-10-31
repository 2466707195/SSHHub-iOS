import Foundation
import Network
import NIOCore
import Citadel
import Crypto

// MARK: - 线路探测（并行 TCP 连通性 + 延迟）

struct EndpointProbeResult: Identifiable {
    let endpoint: ServerEndpoint
    var latencyMs: Int? = nil
    var error: String? = nil

    var id: UUID { endpoint.id }
    var isAlive: Bool { latencyMs != nil }
}

enum LineProbe {

    /// 对单个线路做 TCP 握手测延迟
    static func probe(_ endpoint: ServerEndpoint, timeout: TimeInterval = 3) async -> EndpointProbeResult {
        await withCheckedContinuation { cont in
            let connection = NWConnection(
                host: NWEndpoint.Host(endpoint.host),
                port: NWEndpoint.Port(rawValue: UInt16(endpoint.port)) ?? 22,
                using: .tcp
            )

            var finished = false
            let start = Date()

            func finish(_ result: EndpointProbeResult) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                cont.resume(returning: result)
            }

            let queue = DispatchQueue(label: "probe.\(endpoint.id.uuidString)")
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    finish(EndpointProbeResult(endpoint: endpoint, latencyMs: max(ms, 1)))
                case .failed(let err):
                    finish(EndpointProbeResult(endpoint: endpoint, error: err.localizedDescription))
                case .cancelled:
                    finish(EndpointProbeResult(endpoint: endpoint, error: "已取消"))
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + timeout) {
                finish(EndpointProbeResult(endpoint: endpoint, error: "超时"))
            }

            connection.start(queue: queue)
        }
    }

    /// 并行探测所有线路，返回按延迟排序的结果
    static func probeAll(_ endpoints: [ServerEndpoint]) async -> [EndpointProbeResult] {
        let results = await withTaskGroup(of: EndpointProbeResult.self) { group in
            for ep in endpoints {
                group.addTask { await probe(ep) }
            }
            var list: [EndpointProbeResult] = []
            for await r in group { list.append(r) }
            return list
        }
        return results.sorted { a, b in
            switch (a.latencyMs, b.latencyMs) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return false
            }
        }
    }
}

// MARK: - SSH 连接封装

struct SSHHubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum SSHHub {

    static func makeAuth(_ auth: AuthMethod, username: String) throws -> SSHAuthenticationMethod {
        switch auth {
        case .password(let pwd):
            guard !pwd.isEmpty else {
                throw SSHHubError(message: "还没有填写密码，请先编辑服务器信息")
            }
            return .passwordBased(username: username, password: pwd)
        case .ed25519Key(let pem):
            do {
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: pem)
                return .ed25519(username: username, privateKey: key)
            } catch {
                throw SSHHubError(message: "Ed25519 私钥解析失败：\(error.localizedDescription)")
            }
        case .rsaKey(let pem):
            do {
                let key = try Insecure.RSA.PrivateKey(sshRsa: pem)
                return .rsa(username: username, privateKey: key)
            } catch {
                throw SSHHubError(message: "RSA 私钥解析失败：\(error.localizedDescription)")
            }
        }
    }

    static func connect(
        server: ServerProfile,
        endpoint: ServerEndpoint?,
        timeout: TimeInterval = 6
    ) async throws -> (client: SSHClient, endpoint: ServerEndpoint) {
        // 未指定线路时自动探测，取最快的可用线路
        let target: ServerEndpoint
        if let endpoint {
            target = endpoint
        } else {
            let probes = await LineProbe.probeAll(server.endpoints)
            guard let best = probes.first(where: { $0.isAlive })?.endpoint else {
                let detail = probes.map { "\($0.endpoint.display)：\($0.error ?? "?")" }.joined(separator: "；")
                throw SSHHubError(message: "所有线路都不可达 → \(detail)")
            }
            target = best
        }

        let auth = try makeAuth(server.auth, username: server.username)
        var settings = SSHClientSettings(
            host: target.host,
            port: target.port,
            authenticationMethod: { auth },
            hostKeyValidator: .acceptAnything()
        )
        settings.connectTimeout = .seconds(Int64(timeout))
        let client = try await SSHClient.connect(to: settings)
        return (client, target)
    }

    /// 执行单条命令，返回 stdout（含 stderr）
    static func run(_ client: SSHClient, _ command: String) async -> String {
        do {
            let buffer = try await client.executeCommand(command, maxResponseSize: 1 << 20, mergeStreams: true)
            return buffer.getString(at: 0, length: buffer.readableBytes) ?? ""
        } catch {
            return "⚠️ \(error.localizedDescription)"
        }
    }
}

// MARK: - 监控数据

struct ServerStats {
    var hostname = "—"
    var uptime = "—"
    var load = "—"
    var cpuCores = "—"
    var memLine = "—"
    var memUsedPercent: Double? = nil
    var diskLine = "—"
    var diskUsedPercent: Double? = nil
    var kernel = "—"

    static func parseMem(_ free: String) -> (String, Double?) {
        // 取 Mem: 行，单位 MiB
        for line in free.split(separator: "\n") where line.hasPrefix("Mem:") {
            let nums = line.split(separator: " ").compactMap { Double($0) }
            guard nums.count >= 2, nums[0] > 0 else { break }
            let percent = nums[1] / nums[0] * 100
            return (line.replacingOccurrences(of: "Mem:", with: "内存").trimmingCharacters(in: .whitespaces), percent)
        }
        return ("—", nil)
    }

    static func parseDisk(_ df: String) -> (String, Double?) {
        // 取根分区行
        for line in df.split(separator: "\n") {
            let cols = line.split(separator: " ")
            if cols.count >= 5, cols.last == "/" {
                let percentStr = cols[4].replacingOccurrences(of: "%", with: "")
                let percent = Double(percentStr)
                return ("根分区 \(cols[2]) / \(cols[1])（已用 \(cols[4])）", percent)
            }
        }
        return ("—", nil)
    }
}

enum StatsCollector {

    static func collect(client: SSHClient) async -> ServerStats {
        async let hostname = SSHHub.run(client, "hostname")
        async let uptime = SSHHub.run(client, "uptime -p 2>/dev/null || uptime")
        async let load = SSHHub.run(client, "cat /proc/loadavg")
        async let cores = SSHHub.run(client, "nproc")
        async let free = SSHHub.run(client, "free -m")
        async let dfh = SSHHub.run(client, "df -h / 2>/dev/null")
        async let kernel = SSHHub.run(client, "uname -r")

        var s = ServerStats()
        s.hostname = await hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        s.uptime = await uptime.trimmingCharacters(in: .whitespacesAndNewlines)
        s.load = await load.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").prefix(3).joined(separator: " ")
        s.cpuCores = await cores.trimmingCharacters(in: .whitespacesAndNewlines)
        let (memLine, memPct) = ServerStats.parseMem(await free)
        s.memLine = memLine
        s.memUsedPercent = memPct
        let (diskLine, diskPct) = ServerStats.parseDisk(await dfh)
        s.diskLine = diskLine
        s.diskUsedPercent = diskPct
        s.kernel = await kernel.trimmingCharacters(in: .whitespacesAndNewlines)
        return s
    }
}
