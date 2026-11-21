import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var keywords = ""
    @State private var confirmWipe = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker(selection: $model.settings.textSize) {
                    ForEach(TextSizeOption.allCases) { Text($0.label).tag($0) }
                } label: {
                    SettingRow(icon: "textformat.size", tint: .indigo, title: "文字大小", detail: "也會跟著 iPhone「設定 → 螢幕顯示與亮度 → 文字大小」")
                }
            } header: { Text("外觀") }

            Section {
                NavigationLink { SecurityCenterView() } label: {
                    SettingRow(icon: "lock.shield.fill", tint: SecurityCenter.shared.anomalies.contains { !$0.handled } ? .red : .green,
                               title: "安全中心", detail: "異常偵測、AI 判讀、停機、安全紀錄")
                }
                NavigationLink { SecurityCheckView() } label: {
                    SettingRow(icon: "checkmark.shield.fill", tint: .green, title: "隱私與安全檢查", detail: "檢查手機密碼、攝影機弱密碼與網路建議")
                }
                Toggle(isOn: $model.settings.appLock) {
                    SettingRow(icon: "faceid", tint: .green, title: "App 鎖", detail: "用 \(AppLock.biometryName) 解鎖才能看畫面")
                }
                if model.settings.appLock {
                    Picker(selection: $model.settings.lockGraceSeconds) {
                        Text("立即").tag(0)
                        Text("1 分鐘").tag(60)
                        Text("5 分鐘").tag(300)
                    } label: {
                        SettingRow(icon: "timer", tint: .gray, title: "離開多久後重新上鎖")
                    }
                }
                Toggle(isOn: $model.settings.hideNotificationContent) {
                    SettingRow(icon: "bell.badge.slash.fill", tint: .red, title: "隱藏通知內容", detail: "鎖定畫面只顯示「有新的事件」")
                }
                SettingRow(icon: "iphone.gen3", tint: .blue, title: "資料綁定這支 iPhone", detail: "加密金鑰只在這台手機，永不備份、無法搬到別台") {
                    Image(systemName: "checkmark").foregroundStyle(Theme.live)
                }
                Toggle(isOn: $model.settings.speechOnDeviceOnly) {
                    SettingRow(icon: "waveform.badge.mic", tint: .orange, title: "語音只在手機上辨識", detail: "聲音不會送到任何伺服器")
                }
                Toggle(isOn: $model.settings.blurWhenCaptured) {
                    SettingRow(icon: "eye.slash.fill", tint: .purple, title: "錄螢幕時遮蔽畫面", detail: "包含 AirPlay 鏡像")
                }
            } header: { Text("隱私") } footer: {
                Text("影像、錄影、逐字稿只存在這支 iPhone 的 App 內並加密，不連任何雲端。攝影機密碼存在 Keychain，不會同步或備份。")
            }

            Section {
                Toggle(isOn: $model.settings.guardMode) {
                    SettingRow(icon: "shield.lefthalf.filled", tint: .red, title: "值守模式", detail: "App 在背景也偵測移動、錄影、逐字稿")
                }
                Toggle(isOn: $model.settings.guardKeepScreenOn) {
                    SettingRow(icon: "sun.max.fill", tint: .yellow, title: "值守時螢幕保持開啟", detail: "適合舊 iPhone 當專用監看機")
                }
                .disabled(!model.settings.guardMode)
            } header: { Text("值守") } footer: {
                Text("建議接上充電器。來電、記憶體不足或重開機時 iOS 仍可能停止它；24 小時不中斷錄影請開啟攝影機的記憶卡錄影。")
            }

            Section {
                Stepper(value: $model.settings.segmentMinutes, in: 1...60) {
                    SettingRow(icon: "film.stack", tint: .teal, title: "每段錄影", detail: "\(model.settings.segmentMinutes) 分鐘")
                }
                Stepper(value: $model.settings.motionPostSeconds, in: 5...300, step: 5) {
                    SettingRow(icon: "figure.walk.motion", tint: .orange, title: "移動停止後再錄", detail: "\(model.settings.motionPostSeconds) 秒（另含觸發前約 4 秒）")
                }
                Stepper(value: $model.settings.maxStorageGB, in: 1...200, step: 1) {
                    SettingRow(icon: "internaldrive.fill", tint: .gray, title: "空間上限",
                               detail: "\(Int(model.settings.maxStorageGB)) GB，已用 \(Fmt.size(model.storageUsed))")
                }
                Stepper(value: $model.settings.keepDays, in: 1...90) {
                    SettingRow(icon: "calendar", tint: .pink, title: "保留天數", detail: "\(model.settings.keepDays) 天")
                }
            } header: { Text("手機錄影") } footer: {
                Text("超過上限或天數會自動刪除最舊的錄影；手機剩不到 2 GB 也會自動清。目前手機剩 \(Fmt.size(Storage.freeSpace()))。")
            }

            Section {
                Toggle(isOn: $model.settings.notifyMotion) {
                    SettingRow(icon: "bell.fill", tint: .red, title: "移動通知", detail: "值守或 App 在背景時")
                }
                Stepper(value: $model.settings.motionCooldownSeconds, in: 10...600, step: 10) {
                    SettingRow(icon: "hourglass", tint: .gray, title: "同一台通知間隔", detail: "\(model.settings.motionCooldownSeconds) 秒")
                }
                Toggle(isOn: $model.settings.notifyKeywords) {
                    SettingRow(icon: "exclamationmark.bubble.fill", tint: .red, title: "關鍵字通知", detail: "逐字稿聽到時一律通知")
                }
                TextField("關鍵字，用逗號分隔", text: $keywords)
                    .onSubmit { saveKeywords() }
            } header: { Text("通知") }

            Section("攝影機") {
                ForEach(model.cameras) { c in
                    NavigationLink { CameraEditView(cameraID: c.id) } label: {
                        SettingRow(icon: "video.fill", tint: Theme.accent, title: c.name, detail: c.host)
                    }
                }
                .onMove { model.moveCameras(from: $0, to: $1) }
            }

            Section {
                Button(role: .destructive) { confirmWipe = true } label: {
                    SettingRow(icon: "trash.fill", tint: .red, title: "清除所有資料", detail: "攝影機、密碼、錄影、截圖、逐字稿、事件")
                }
            }

            Section("關於") {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                Text("影音處理使用 FFmpeg（GPL/LGPL），僅供個人使用。").font(.footnote).foregroundStyle(Theme.tertiary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("設定")
        .toolbar { EditButton() }
        .onAppear { keywords = model.settings.keywords.joined(separator: ", ") }
        .onDisappear { saveKeywords() }
        .confirmationDialog("確定清除所有資料？此動作無法復原。", isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                Task {
                    if await AppLock.authenticate(reason: "確認清除所有資料") { model.wipeAll() }
                }
            }
        }
    }

    private func saveKeywords() {
        model.settings.keywords = keywords.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

struct CameraEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let cameraID: String
    @State private var newPassword = ""
    @State private var confirmDelete = false
    @State private var confirmRotate = false
    @State private var working = false
    @State private var audit: String = ""

    var body: some View {
        if let cam = model.cameras.first(where: { $0.id == cameraID }) {
            Form {
                Section {
                    TextField("名稱", text: bind(cam, \.name))
                    Toggle("啟用", isOn: bind(cam, \.enabled))
                    Toggle("使用高畫質（主碼流）", isOn: bind(cam, \.recordHighQuality))
                    Picker("記憶卡回放格式", selection: bind(cam, \.sdPlayback)) {
                        ForEach(CameraConfig.SDPlayback.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("連線") {
                    LabeledContent("IP", value: cam.host)
                    LabeledContent("帳號", value: cam.username)
                    LabeledContent("品牌", value: cam.brand.isEmpty ? "—" : cam.brand)
                    LabeledContent("方式", value: cam.onvifURL.isEmpty ? "RTSP" : "ONVIF\(cam.ptz ? " + 雲台" : "")")
                    LabeledContent("子碼流", value: cam.subURL.isEmpty ? "無" : "有")
                    LabeledContent("連線數", value: "1（看、聽、偵測、錄影共用）")
                    LabeledContent("身分序號", value: cam.serial.isEmpty ? "未取得（RTSP 攝影機）" : "已釘選 …\(cam.serial.suffix(4))")
                    LabeledContent("串流指紋", value: cam.pinnedVideo.isEmpty ? "尚未記錄" : cam.pinnedVideo)
                    if !cam.pinnedVideo.isEmpty {
                        Button("我改了攝影機畫質，重新記住指紋") { model.sessions[cam.id]?.resetFingerprint() }
                    }
                    SecureField("更換密碼", text: $newPassword)
                    if !newPassword.isEmpty {
                        ForEach(PasswordCheck.problems(newPassword, user: cam.username), id: \.self) {
                            Label($0, systemImage: "exclamationmark.shield").font(.footnote).foregroundStyle(Theme.motion)
                        }
                        Button("儲存新密碼") {
                            Keychain.setPassword(newPassword, for: cam.id)
                            newPassword = ""
                            var c = cam; c.enabled = false; model.updateCamera(c)     // 重新連線以套用
                            c.enabled = true; model.updateCamera(c)
                            model.toast = "已更新密碼"
                        }
                    }
                }
                Section {
                    if !cam.onvifURL.isEmpty {
                        Button { confirmRotate = true } label: {
                            SettingRow(icon: "key.horizontal.fill", tint: .orange, title: "換成只有這支 iPhone 知道的密碼",
                                       detail: "產生 16 字元隨機密碼並寫入攝影機，只存在這支手機；別人（包括原廠 App）都無法再用舊密碼登入")
                        }
                        .disabled(working)
                        Button {
                            Task { await runAudit(cam) }
                        } label: {
                            SettingRow(icon: "person.2.badge.key.fill", tint: .indigo, title: "檢查攝影機上的帳號",
                                       detail: audit.isEmpty ? "找出 App 以外的帳號（可能是後門）" : audit)
                        }
                        .disabled(working)
                    }
                    if working { HStack { ProgressView(); Text("處理中…").foregroundStyle(Theme.secondary) } }
                } header: { Text("防止別人繞過 App") } footer: {
                    Text("App 無法從外部封鎖攝影機，最有效的是讓別人「沒有密碼」。也請到攝影機設定：關閉雲端/P2P、開啟 IP 白名單只允許這支手機（\(Discovery.localIPv4() ?? "手機 IP")）、停用不用的帳號。")
                }
                Section {
                    Button("移除這台攝影機", role: .destructive) { confirmDelete = true }
                } footer: { Text("錄影檔會保留，可在「回放」刪除。") }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle(cam.name)
            .confirmationDialog("把「\(cam.name)」的密碼換成隨機強密碼？", isPresented: $confirmRotate, titleVisibility: .visible) {
                Button("更換密碼") { Task { await rotate(cam) } }
            } message: {
                Text("新密碼只存在這支 iPhone、不會顯示。之後原廠 App 會登不進去；要恢復只能把攝影機重置。換之前會先驗證，失敗會自動換回原密碼。")
            }
            .confirmationDialog("移除「\(cam.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("移除", role: .destructive) { model.removeCamera(cam.id); dismiss() }
            }
        }
    }

    private func rotate(_ cam: CameraConfig) async {
        guard await AppLock.authenticate(reason: "更換攝影機密碼") else { return }
        working = true
        model.sessions[cam.id]?.stopEngines()
        let r = await CameraHardening.rotatePassword(cam)
        working = false
        switch r {
        case .success:
            SecurityCenter.shared.log(.settingChanged, .info, "攝影機密碼已換成隨機強密碼（只存在這支手機）", camera: cam.name)
            model.toast = "已更換，現在只有這支 iPhone 知道密碼"
        case .failed(let msg):
            SecurityCenter.shared.log(.settingChanged, .low, "更換攝影機密碼失敗：\(msg)", camera: cam.name)
            model.toast = msg
        }
        model.refreshDemand()
    }

    private func runAudit(_ cam: CameraConfig) async {
        working = true
        let r = await CameraHardening.auditUsers(cam)
        working = false
        guard let r else { audit = "無法讀取帳號（攝影機可能不支援）"; return }
        if r.others.isEmpty {
            audit = "✅ 只有 App 使用的帳號「\(cam.username)」"
        } else {
            let names = r.others.map { "\($0.name)（\($0.level)）" }.joined(separator: "、")
            audit = "⚠️ 另有帳號：\(names)。不是你建立的請到攝影機設定刪除"
            SecurityCenter.shared.log(.settingChanged, .medium, "攝影機上有其他帳號：\(names)", camera: cam.name)
            SecurityCenter.shared.raise(.medium, "攝影機上有其他帳號", names, camera: cam.name)
        }
    }

    private func bind<T>(_ cam: CameraConfig, _ kp: WritableKeyPath<CameraConfig, T>) -> Binding<T> {
        Binding(get: { model.cameras.first { $0.id == cam.id }?[keyPath: kp] ?? cam[keyPath: kp] },
                set: { v in
                    guard var c = model.cameras.first(where: { $0.id == cam.id }) else { return }
                    c[keyPath: kp] = v
                    model.updateCamera(c)
                })
    }
}

struct SecurityCheckView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("這支 iPhone") {
                check(AppLock.deviceHasPasscode, "手機已設定密碼", "到「設定 → Face ID 與密碼」設定，否則 App 鎖與資料加密都無效")
                check(model.settings.appLock, "App 鎖已開啟", "別人拿到解鎖的手機也打不開 HomeCam")
                check(model.settings.hideNotificationContent, "通知不顯示內容與截圖", "鎖定畫面上的通知可能被旁人看到")
                check(true, "資料綁定這支 iPhone", "加密金鑰只存在這台手機，不備份、無法搬到別台")
                check(model.settings.speechOnDeviceOnly, "語音只在手機上辨識", "關閉時，聲音可能送到 Apple 伺服器辨識")
            }
            Section("攝影機密碼") {
                ForEach(model.cameras) { c in
                    let p = PasswordCheck.problems(Keychain.password(for: c.id), user: c.username)
                    check(p.isEmpty, c.name, p.isEmpty ? "密碼強度足夠" : p.joined(separator: "；") + "。請在攝影機的 App 改密碼，再到「設定 → 攝影機」更新")
                }
                if model.cameras.isEmpty { Text("尚無攝影機").foregroundStyle(.secondary) }
            }
            Section {
                tip("關閉攝影機的雲端 / 遠端觀看功能", "在攝影機原廠 App 關閉雲端儲存、遠端存取、P2P。HomeCam 不需要它們。")
                tip("路由器關閉 UPnP 與連接埠轉發", "避免攝影機被暴露到網際網路上。")
                tip("攝影機放在獨立網路", "用路由器的「訪客網路 / IoT 網路」，並封鎖攝影機連外，只讓家裡網路連得到。")
                tip("家裡 WiFi 使用 WPA2/WPA3 強密碼", "RTSP 串流在家中網路內沒有加密，WiFi 密碼就是第一道防線。")
                tip("更新攝影機韌體", "修補已知漏洞。更新完再把連外封鎖回來。")
                tip("不要在公共 WiFi 下觀看", "HomeCam 只在家裡網路使用；在外面請透過自己的 VPN（如家用路由器內建 VPN）。")
            } header: { Text("建議") }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("安全檢查")
    }

    private func check(_ ok: Bool, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Theme.live : Theme.motion).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(Theme.secondary).lineSpacing(2)
            }
        }
    }

    private func tip(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(detail).font(.footnote).foregroundStyle(Theme.secondary).lineSpacing(2)
        }
    }
}
