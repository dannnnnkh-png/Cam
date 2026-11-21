import SwiftUI

struct AddCameraView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var scanning = false
    @State private var scanInfo = ""
    @State private var found: [DiscoveredDevice] = []
    @State private var selected: DiscoveredDevice?

    @State private var host = ""
    @State private var username = "admin"
    @State private var password = ""
    @State private var name = ""
    @State private var manualMain = ""
    @State private var manualSub = ""
    @State private var showAdvanced = false
    @State private var working = false
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Task { await scan() }
                    } label: {
                        HStack {
                            Label("搜尋同 WiFi 的攝影機", systemImage: "dot.radiowaves.left.and.right")
                            Spacer()
                            if scanning { ProgressView() }
                        }
                    }
                    .disabled(scanning)
                    if !scanInfo.isEmpty { Text(scanInfo).font(.footnote).foregroundStyle(Theme.secondary) }
                    ForEach(found) { d in
                        Button { pick(d) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(d.host).font(.body.monospacedDigit())
                                    Text([d.name, d.model, d.source].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.footnote).foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                if model.cameras.contains(where: { $0.host == d.host }) { Text("已加入").font(.footnote).foregroundStyle(Theme.secondary) }
                                else if selected == d { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: { Text("自動搜尋") } footer: {
                    Text("第一次會詢問「區域網路」權限，請按允許。搜尋只在你家網路內進行。")
                }

                Section("攝影機帳號") {
                    TextField("IP 位址，例如 192.168.1.23", text: $host)
                        .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("帳號", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("密碼", text: $password).textContentType(.password)
                    TextField("名稱（例如：客廳）", text: $name)
                    ForEach(PasswordCheck.problems(password, user: username), id: \.self) { p in
                        Label(p, systemImage: "exclamationmark.shield").font(.footnote).foregroundStyle(Theme.motion)
                    }
                }

                Section {
                    DisclosureGroup("進階：手動輸入 RTSP 網址", isExpanded: $showAdvanced) {
                        TextField("主碼流 rtsp://IP:554/…", text: $manualMain)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        TextField("子碼流（選填）", text: $manualSub)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    }
                } footer: {
                    Text("Tapo：App →攝影機設定 →進階設定 →「攝影機帳號」先建立帳密。小米/米家多數型號不支援。")
                }

                if !error.isEmpty {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }

                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Spacer()
                            if working { ProgressView().padding(.trailing, 6); Text("連線並偵測串流…") } else { Text("連線並加入").bold() }
                            Spacer()
                        }
                    }
                    .disabled(working || (host.isEmpty && manualMain.isEmpty))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("新增攝影機")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task { if found.isEmpty { await scan() } }
        }
    }

    private func pick(_ d: DiscoveredDevice) {
        selected = d
        host = d.host
        if name.isEmpty { name = d.name }
    }

    private func scan() async {
        scanning = true
        found = []
        let r = await Discovery.discover { msg in Task { @MainActor in scanInfo = msg } }
        found = r
        scanInfo = r.isEmpty ? "沒找到。確認攝影機已開啟 RTSP/ONVIF，或手動輸入 IP。" : "找到 \(r.count) 台裝置"
        scanning = false
    }

    private func connect() async {
        working = true
        error = ""
        defer { working = false }
        var cfg = CameraConfig()
        cfg.username = username
        do {
            if !manualMain.isEmpty {
                let m = URLCredential.strip(manualMain.trimmingCharacters(in: .whitespaces))
                let user = m.user.isEmpty ? username : m.user
                let pwd = m.password.isEmpty ? password : m.password
                guard NetGuard.allows(url: m.url), manualSub.isEmpty || NetGuard.allows(url: manualSub) else {
                    throw ONVIFError(message: "只能加入家中區域網路（例如 192.168.x.x）的攝影機")
                }
                let r = await Probe.run(URLCredential.inject(m.url, user: user, password: pwd), timeoutMs: 8000)
                guard r.code == HC_OK else { throw ONVIFError(message: "無法開啟串流：\(Probe.message(r.code))") }
                cfg.mainURL = m.url
                cfg.subURL = manualSub.isEmpty ? "" : URLCredential.strip(manualSub).url
                cfg.host = URL(string: m.url)?.host ?? host
                cfg.username = user
                password = pwd
            } else {
                let h = host.trimmingCharacters(in: .whitespaces)
                guard NetGuard.isPrivate(host: h) else {
                    throw ONVIFError(message: "只能加入家中區域網路（例如 192.168.x.x）的攝影機")
                }
                var result: CameraSetupResult?
                var errors: [String] = []
                do {
                    result = try await CameraSetup.viaONVIF(host: h, user: username, password: password,
                                                            deviceURL: selected?.host == h && !(selected?.onvifURL ?? "").isEmpty ? selected?.onvifURL : nil)
                    if let r = result {
                        let p = await Probe.run(URLCredential.inject(r.mainURL, user: username, password: password), timeoutMs: 8000)
                        if p.code != HC_OK { errors.append("ONVIF 串流：\(Probe.message(p.code))"); result = nil }
                    }
                } catch {
                    errors.append("ONVIF：\(error.localizedDescription)")
                }
                if result == nil {
                    do {
                        result = try await CameraSetup.guessRTSP(host: h, port: selected?.rtspPort ?? 554, user: username, password: password)
                    } catch {
                        errors.append("RTSP：\(error.localizedDescription)")
                        throw ONVIFError(message: errors.joined(separator: "\n"))
                    }
                }
                guard let r = result else { return }
                cfg.host = h
                cfg.mainURL = r.mainURL
                cfg.subURL = r.subURL
                cfg.onvifURL = r.onvifURL
                cfg.profileToken = r.profileToken
                cfg.ptz = r.ptz
                cfg.brand = r.brand
                cfg.sdPlayback = r.sdPlayback
                cfg.serial = r.serial
            }
            cfg.name = name.isEmpty ? (cfg.brand.isEmpty ? "攝影機 \(cfg.host)" : cfg.brand) : name
            model.addCamera(cfg, password: password)
            password = ""
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
