import SwiftUI

struct SecurityCenterView: View {
    @Environment(AppModel.self) private var model
    @State private var sc = SecurityCenter.shared
    @State private var confirmLockdown = false
    @State private var showAllLogs = false

    var body: some View {
        @Bindable var model = model
        List {
            Section { statusCard.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }

            Section {
                if model.settings.lockdownActive {
                    Button {
                        Task { await model.releaseLockdown() }
                    } label: {
                        SettingRow(icon: "lock.open.fill", tint: .green, title: "解除停機", detail: "需要 \(AppLock.biometryName) 驗證")
                    }
                } else {
                    Button(role: .destructive) { confirmLockdown = true } label: {
                        SettingRow(icon: "power", tint: .red, title: "立即停機", detail: "切斷所有攝影機、停止錄影與值守、鎖住 App")
                    }
                }
                Toggle(isOn: $model.settings.autoLockdown) {
                    SettingRow(icon: "bolt.shield.fill", tint: .red, title: "嚴重異常自動停機",
                               detail: "攝影機被替換、連往外部、紀錄被竄改、手機越獄時立即停機")
                }
                Toggle(isOn: $model.settings.aiReview) {
                    SettingRow(icon: "brain.head.profile", tint: .purple, title: "裝置端 AI 判讀", detail: sc.aiStatus)
                }
                if model.settings.aiReview {
                    Button {
                        sc.runAIReview(reason: "手動檢查")
                        model.toast = "已交給裝置端 AI 檢查，結果會出現在下方紀錄"
                    } label: { Label("現在用 AI 檢查一次", systemImage: "sparkles") }
                }
            } header: { Text("停機與偵測") } footer: {
                Text("「高」等級的異常會立即通知，並詢問是否停機（通知上也能直接按「立即停機」）。AI 的判斷只會通知和詢問，不會自己停機，避免誤判。")
            }

            Section("異常") {
                let list = sc.anomalies.reversed()
                if list.isEmpty {
                    Label("目前沒有異常", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.live)
                }
                ForEach(Array(list.prefix(30))) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(a.severity.label).font(.footnote.weight(.bold)).foregroundStyle(color(a.severity))
                            Text(a.title).font(.body.weight(.semibold))
                        }
                        if !a.detail.isEmpty { Text(a.detail).font(.footnote).foregroundStyle(Theme.secondary).lineSpacing(2) }
                        HStack {
                            Text("\(Fmt.dateTime.string(from: a.date)) · \(a.source)\(a.camera.isEmpty ? "" : " · \(a.camera)")")
                                .font(.caption).foregroundStyle(Theme.tertiary)
                            Spacer()
                            if !a.handled {
                                Button("標記已處理") { sc.markHandled(a.id) }.font(.footnote).buttonStyle(.borderless)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .opacity(a.handled ? 0.6 : 1)
                }
            }

            Section {
                protection("iphone.gen3", "資料綁定這支 iPhone", "加密金鑰只在這台手機的 Keychain；被複製到別台會偵測到並清除")
                protection("lock.doc.fill", "全部加密存放", "設定、事件、逐字稿、截圖、安全紀錄 AES-256 加密；錄影用 iOS 硬體加密")
                protection("cable.connector", "每台攝影機只有一條連線", "看、聽、偵測、錄影共用；App 不開任何對外連接埠")
                protection("network.badge.shield.half.filled", "只連家中區域網路", "任何連往網際網路的位址都會被擋下並告警")
                protection("checkmark.seal.fill", "攝影機身分釘選", "連線時核對序號與串流指紋，被替換就告警")
                protection("link", "防竄改安全紀錄", sc.chainOK ? "雜湊鏈驗證通過" : "⚠️ 驗證失敗，紀錄可能被修改")
                protection("iphone.slash", "執行環境檢查", sc.integrityIssues.isEmpty ? "未發現越獄或注入" : sc.integrityIssues.joined(separator: "；"))
            } header: { Text("防護狀態") }

            Section {
                ForEach(Array(sc.recent.reversed().filter { showAllLogs || $0.severity >= .low }.prefix(200))) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Fmt.dateTime.string(from: e.date)) · \(e.category.label)\(e.camera.isEmpty ? "" : " · \(e.camera)")")
                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
                        Text(e.detail).font(.footnote).foregroundStyle(e.severity >= .medium ? color(e.severity) : Theme.secondary)
                    }
                }
            } header: {
                HStack {
                    Text("安全紀錄")
                    Spacer()
                    Toggle("全部", isOn: $showAllLogs).toggleStyle(.button).font(.caption)
                }
            } footer: {
                Text("所有紀錄只存在這支 iPhone，並加密、串成雜湊鏈：任何一筆被改或刪都會被發現。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("安全中心")
        .onAppear { sc.updateAIStatus() }
        .confirmationDialog("立即停機？所有攝影機會中斷，直到你用 \(AppLock.biometryName) 解除。", isPresented: $confirmLockdown,
                            titleVisibility: .visible) {
            Button("立即停機", role: .destructive) { model.lockdown(reason: "使用者手動停機") }
        }
    }

    private var statusCard: some View {
        let open = sc.anomalies.filter { !$0.handled }
        let worst = open.map(\.severity).max() ?? .info
        let (icon, tint, title): (String, Color, String) = model.settings.lockdownActive
            ? ("power.circle.fill", Theme.rec, "已停機")
            : open.isEmpty ? ("checkmark.shield.fill", Theme.live, "防護中，一切正常")
            : ("exclamationmark.shield.fill", color(worst), "有 \(open.count) 個異常待處理")
        return HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 40, weight: .semibold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(model.settings.lockdownActive ? model.settings.lockdownReason : "所有資料與判斷都只在這支 iPhone 上")
                    .font(.subheadline).foregroundStyle(Theme.secondary)
            }
            Spacer()
        }
        .card()
    }

    private func protection(_ icon: String, _ title: String, _ detail: String) -> some View {
        SettingRow(icon: icon, tint: .teal, title: title, detail: detail)
    }

    private func color(_ s: Severity) -> Color {
        switch s {
        case .critical, .high: return Theme.rec
        case .medium: return Theme.motion
        case .low: return Theme.accent
        case .info: return Theme.secondary
        }
    }
}

/// 停機畫面（解除前不會連任何攝影機）
struct LockdownView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            RadialGradient(colors: [Theme.rec.opacity(0.25), .clear], center: .top, startRadius: 0, endRadius: 420).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "power.circle.fill").font(.system(size: 64)).foregroundStyle(Theme.rec)
                Text("已停機").font(.largeTitle.weight(.bold))
                Text(model.settings.lockdownReason).font(.body).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                Text("所有攝影機連線已中斷，錄影與值守已停止。").font(.subheadline).foregroundStyle(Theme.tertiary)
                Button {
                    Task { await model.releaseLockdown() }
                } label: {
                    Label("確認安全，解除停機", systemImage: "lock.open.fill").font(.headline)
                        .frame(maxWidth: 280).padding(.vertical, 14)
                        .background(Theme.cardRaised, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
                NavigationLink { SecurityCenterView() } label: {
                    Text("查看安全中心").font(.subheadline)
                }
            }
            .padding(32)
        }
    }
}
