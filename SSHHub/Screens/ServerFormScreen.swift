import SwiftUI

// MARK: - 服务器编辑表单

struct ServerFormScreen: View {

    @EnvironmentObject private var store: ServerStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ServerProfile
    @State private var authType: AuthType
    @State private var password = ""
    @State private var keyPEM = ""
    @State private var showKeyError = false

    enum AuthType: String, CaseIterable, Identifiable {
        case password = "密码"
        case ed25519Key = "Ed25519 密钥"
        case rsaKey = "RSA 密钥"
        var id: String { rawValue }
    }

    init(server: ServerProfile) {
        _draft = State(initialValue: server)
        switch server.auth {
        case .password(let p):
            _authType = State(initialValue: .password)
            _password = State(initialValue: p)
        case .ed25519Key(let pem):
            _authType = State(initialValue: .ed25519Key)
            _keyPEM = State(initialValue: pem)
        case .rsaKey(let pem):
            _authType = State(initialValue: .rsaKey)
            _keyPEM = State(initialValue: pem)
        }
    }

    var body: some View {
        AuroraScreen {
            AppTopBar(title: isNew ? "添加服务器" : "编辑服务器", onBack: { dismiss() })
        } content: {
            AuroraScrollView(bottomInset: 40) {
                SectionCard {
                    Text("基本信息")
                        .font(AuroraFont.titleSmall)
                        .foregroundStyle(Aurora.inkSoft)
                    Spacer().frame(height: 10)
                    AuroraTextField(placeholder: "名称（如：Armbian 盒子）", text: $draft.name, systemIcon: "server.rack")
                    Spacer().frame(height: 8)
                    AuroraTextField(placeholder: "用户名", text: $draft.username, systemIcon: "person")
                }

                SectionCard {
                    Text("认证方式")
                        .font(AuroraFont.titleSmall)
                        .foregroundStyle(Aurora.inkSoft)
                    Spacer().frame(height: 10)
                    Picker("认证方式", selection: $authType) {
                        ForEach(AuthType.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    Spacer().frame(height: 12)

                    switch authType {
                    case .password:
                        AuroraTextField(placeholder: "密码（保存在本机）", text: $password, systemIcon: "lock", isSecure: true)
                    case .ed25519Key, .rsaKey:
                        ZStack(alignment: .topLeading) {
                            if keyPEM.isEmpty {
                                Text("粘贴私钥内容（-----BEGIN OPENSSH PRIVATE KEY----- 开头的整段文本）")
                                    .font(AuroraFont.bodySmall)
                                    .foregroundStyle(Aurora.muted)
                                    .padding(.horizontal, 13)
                                    .padding(.top, 14)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $keyPEM)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 110)
                                .padding(6)
                        }
                        .background(AuroraShape.control.fill(Color.white))
                        .overlay(AuroraShape.control.stroke(Aurora.line, lineWidth: 1))
                    }
                }

                SectionCard {
                    HStack {
                        Text("连接线路（至少一条）")
                            .font(AuroraFont.titleSmall)
                            .foregroundStyle(Aurora.inkSoft)
                        Spacer()
                        TextLinkButton(text: "加一条", systemIcon: "plus") {
                            draft.endpoints.append(ServerEndpoint())
                        }
                    }
                    Spacer().frame(height: 10)

                    ForEach($draft.endpoints) { $ep in
                        EndpointRow(endpoint: $ep, canDelete: draft.endpoints.count > 1) {
                            draft.endpoints.removeAll { $0.id == ep.id }
                        }
                        Spacer().frame(height: 8)
                    }
                }
            }
        } bar: {
            GlassBar {
                PrimaryButton(text: "保存", systemIcon: "checkmark", enabled: canSave) {
                    save()
                }
            }
        }
        .alert("私钥格式不对", isPresented: $showKeyError) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("请粘贴 OpenSSH 格式的完整私钥文本（包含 BEGIN / END 行）。")
        }
    }

    private var isNew: Bool {
        !store.servers.contains { $0.id == draft.id }
    }

    private var canSave: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !draft.username.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard draft.endpoints.contains(where: { !$0.host.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        switch authType {
        case .password: return !password.isEmpty
        case .ed25519Key, .rsaKey: return !keyPEM.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func save() {
        if authType == .ed25519Key || authType == .rsaKey {
            let trimmed = keyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("-----BEGIN") else {
                showKeyError = true
                return
            }
        }
        switch authType {
        case .password: draft.auth = .password(password)
        case .ed25519Key: draft.auth = .ed25519Key(keyPEM.trimmingCharacters(in: .whitespacesAndNewlines))
        case .rsaKey: draft.auth = .rsaKey(keyPEM.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        draft.endpoints = draft.endpoints.filter { !$0.host.trimmingCharacters(in: .whitespaces).isEmpty }
        store.upsert(draft)
        dismiss()
    }
}

// MARK: - 线路编辑行

private struct EndpointRow: View {

    @Binding var endpoint: ServerEndpoint
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $endpoint.kind) {
                    ForEach(EndpointKind.allCases) { k in
                        Text(k.rawValue).tag(k)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 108)
                .labelsHidden()

                AuroraTextField(placeholder: "主机 / IP", text: $endpoint.host, systemIcon: "dot.radiowindows")
                AuroraTextField(placeholder: "端口", text: portBinding, systemIcon: "number")
                    .frame(width: 92)
            }
            HStack {
                Text(endpoint.display)
                    .font(AuroraFont.labelSmall)
                    .foregroundStyle(Aurora.muted)
                Spacer()
                if canDelete {
                    TextLinkButton(text: "移除", action: onDelete)
                }
            }
        }
    }

    private var portBinding: Binding<String> {
        Binding(
            get: { String(endpoint.port) },
            set: { endpoint.port = Int($0.filter(\.isNumber)) ?? endpoint.port }
        )
    }
}
