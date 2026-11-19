import SwiftUI

struct CameraDetailView: View {
    @Environment(AppModel.self) private var model
    let session: CameraSession
    @State private var fullscreen = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                player
                controls
                if session.config.ptz { PTZPanel(session: session) }
                transcriptCard
                settingsCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Theme.bg)
        .navigationTitle(session.config.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { session.setListening(false) }
        .fullScreenCover(isPresented: $fullscreen) { FullscreenPlayer(session: session) }
    }

    // MARK: 畫面

    private var player: some View {
        ZStack {
            VideoView(session: session)
            if !session.statusText.isEmpty {
                VStack(spacing: 10) {
                    if session.state != HC_STATE_AUTH_FAILED && session.state != HC_STATE_RETRYING {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "wifi.exclamationmark").font(.title2).foregroundStyle(Theme.tertiary)
                    }
                    Text(session.statusText).font(.subheadline).foregroundStyle(Theme.secondary)
                }
            }
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom).frame(height: 56)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom).frame(height: 56)
            }
            .allowsHitTesting(false)
            VStack {
                HStack(alignment: .top) {
                    LiveIndicator(s: session)
                    Spacer()
                    SessionBadges(s: session)
                }
                Spacer()
                HStack(alignment: .bottom) {
                    if session.state == HC_STATE_PLAYING { LiveClock().foregroundStyle(.white.opacity(0.9)) }
                    Spacer()
                    Text(quality).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                }
                if session.listening || session.config.transcribe { AudioMeter(level: session.audioLevel, speaking: session.speaking) }
            }
            .padding(12)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .stroke(session.motionActive ? Theme.motion : Theme.hairline, lineWidth: session.motionActive ? 2 : 1))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
        .captureShield()
        .onTapGesture(count: 2) { fullscreen = true }
        .padding(.top, 4)
    }

    private var quality: String {
        [session.resolution, session.fps > 0 ? String(format: "%.0f fps", session.fps) : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: 控制列

    private var controls: some View {
        HStack(spacing: 4) {
            CircleControl(icon: session.recording ? "stop.fill" : "record.circle",
                          title: session.recording ? "停止錄影" : "錄影",
                          active: session.recording, activeColor: Theme.rec) {
                if session.recording { session.stopRecording(); model.addEvent(session, .record, "停止錄影") }
                else { session.startRecording(reason: "manual"); model.addEvent(session, .record, "開始錄影") }
            }
            CircleControl(icon: "camera.fill", title: "截圖") { model.takeSnapshot(session) }
            CircleControl(icon: session.listening ? "speaker.wave.2.fill" : "speaker.slash.fill",
                          title: session.listening ? "收聽中" : "聲音", active: session.listening) {
                session.setListening(!session.listening)
            }
            CircleControl(icon: "arrow.up.left.and.arrow.down.right", title: "全螢幕") { fullscreen = true }
        }
        .padding(.vertical, 14)
        .card(padding: 8)
    }

    // MARK: 逐字稿

    private var transcriptCard: some View {
        let lines = Array(model.liveTranscripts.filter { $0.cameraID == session.id }.suffix(30).reversed())
        return VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "即時逐字稿", icon: "text.bubble.fill",
                      trailing: session.config.transcribe ? (session.speaking ? "聽到說話…" : "聆聽中") : nil)
            if !session.config.transcribe {
                Text("在下方「這台的設定」開啟後，說話內容會自動轉成文字並存檔。")
                    .font(.subheadline).foregroundStyle(Theme.secondary).lineSpacing(3)
            } else if lines.isEmpty {
                Text(session.transcribeStatus.isEmpty ? "等待說話聲…" : session.transcribeStatus)
                    .font(.subheadline).foregroundStyle(Theme.secondary)
            }
            ForEach(lines) { l in
                VStack(alignment: .leading, spacing: 3) {
                    Text(Fmt.time.string(from: l.date)).font(.footnote.monospacedDigit()).foregroundStyle(Theme.tertiary)
                    Text(l.text).font(.body).lineSpacing(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            }
        }
        .card()
    }

    // MARK: 設定

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "這台的設定", icon: "slider.horizontal.3")
            HStack {
                Text("手機錄影")
                Spacer()
                Picker("手機錄影", selection: binding(\.recordMode)) {
                    ForEach(CameraConfig.RecordMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            }
            Divider().overlay(Theme.hairline)
            Toggle("移動偵測", isOn: binding(\.motion))
            if session.config.motion {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("敏感度").foregroundStyle(Theme.secondary)
                        Spacer()
                        Text(sensitivityLabel).foregroundStyle(Theme.secondary).monospacedDigit()
                    }
                    .font(.subheadline)
                    Slider(value: Binding(get: { Double(session.config.motionSensitivity) },
                                          set: { v in var c = session.config; c.motionSensitivity = Int(v); model.updateCamera(c) }),
                           in: 1...100, step: 1)
                }
            }
            Divider().overlay(Theme.hairline)
            Toggle("即時逐字稿", isOn: binding(\.transcribe))
            Text("App 開著或「值守」時才偵測與做逐字稿。24 小時連續錄影請用攝影機的記憶卡。")
                .font(.footnote).foregroundStyle(Theme.tertiary).lineSpacing(2)
        }
        .card()
    }

    private var sensitivityLabel: String {
        let v = session.config.motionSensitivity
        return v < 34 ? "低" : (v < 67 ? "中" : "高")
    }

    private func binding<T>(_ kp: WritableKeyPath<CameraConfig, T>) -> Binding<T> {
        Binding(get: { session.config[keyPath: kp] },
                set: { v in var c = session.config; c[keyPath: kp] = v; model.updateCamera(c); Theme.haptic() })
    }
}

/// 聲音音量條
struct AudioMeter: View {
    let level: Float
    let speaking: Bool
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(speaking ? Theme.motion : Theme.live)
                    .frame(width: max(4, g.size.width * CGFloat(level)))
                    .animation(.easeOut(duration: 0.15), value: level)
            }
        }
        .frame(height: 4)
        .padding(.top, 6)
    }
}

// MARK: - 全螢幕（可旋轉、雙指放大）

struct FullscreenPlayer: View {
    @Environment(\.dismiss) private var dismiss
    let session: CameraSession
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VideoView(session: session)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(MagnificationGesture()
                    .onChanged { scale = max(1, min(6, lastScale * $0)) }
                    .onEnded { _ in lastScale = scale; if scale == 1 { offset = .zero; lastOffset = .zero } })
                .simultaneousGesture(DragGesture()
                    .onChanged { v in
                        guard scale > 1 else { return }
                        offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height)
                    }
                    .onEnded { _ in lastOffset = offset })
                .onTapGesture(count: 2) { withAnimation { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero } }
                .ignoresSafeArea()
                .captureShield()
            HStack {
                SessionBadges(s: session)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).padding(12).background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding()
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}

// MARK: - 雲台

@Observable
final class PTZController {
    let session: CameraSession
    var presets: [(token: String, name: String)] = []
    var error = ""
    @ObservationIgnored private var client: ONVIFClient?
    @ObservationIgnored private var keepAlive: Task<Void, Never>?

    init(session: CameraSession) { self.session = session }

    private func get() async throws -> ONVIFClient {
        if let client { return client }
        guard let u = URL(string: session.config.onvifURL) else { throw ONVIFError(message: "未設定 ONVIF") }
        let c = ONVIFClient(deviceURL: u, username: session.config.username, password: Keychain.password(for: session.config.id))
        try await c.connect()
        client = c
        return c
    }

    func start(x: Double, y: Double, zoom: Double) {
        keepAlive?.cancel()
        let task = Task {
            // 按住時每 1 秒續送；放開、網路斷掉或 App 離開時最多 2 秒內一定會停
            while !Task.isCancelled {
                do { try await get().move(token: session.config.profileToken, x: x, y: y, zoom: zoom) }
                catch { await MainActor.run { self.error = error.localizedDescription }; client = nil; break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        keepAlive = task
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000_000)          // 按住最長 30 秒保護
            if let k = self.keepAlive, k == task { self.stop() }
        }
    }

    func stop() {
        keepAlive?.cancel()
        keepAlive = nil
        Task { try? await get().stop(token: session.config.profileToken) }
    }

    func loadPresets() async {
        let p = (try? await get().presets(token: session.config.profileToken)) ?? []
        await MainActor.run { presets = p }
    }

    func goto(_ preset: String) { Task { try? await get().gotoPreset(token: session.config.profileToken, preset: preset) } }
    func home() { Task { try? await get().gotoHome(token: session.config.profileToken) } }
    func savePreset(_ name: String) async {
        try? await get().setPreset(token: session.config.profileToken, name: name)
        await loadPresets()
    }
}

struct PTZPanel: View {
    @State private var ptz: PTZController
    @State private var speed = 0.5
    @State private var newPreset = ""
    @State private var askName = false

    init(session: CameraSession) { _ptz = State(initialValue: PTZController(session: session)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardTitle(title: "雲台控制", icon: "move.3d", trailing: "按住移動，放開停止")
            HStack(spacing: 28) {
                Spacer(minLength: 0)
                // 圓形方向盤
                ZStack {
                    Circle().fill(Theme.cardRaised)
                    Circle().stroke(Theme.hairline, lineWidth: 1)
                    VStack { arrow("chevron.up", 0, 1); Spacer(); arrow("chevron.down", 0, -1) }.padding(6)
                    HStack { arrow("chevron.left", -1, 0); Spacer(); arrow("chevron.right", 1, 0) }.padding(6)
                    Button { Theme.haptic(); ptz.home() } label: {
                        Image(systemName: "scope").font(.title3.weight(.semibold))
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(Theme.card))
                            .overlay(Circle().stroke(Theme.hairline))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("回原點")
                }
                .frame(width: 196, height: 196)
                // 縮放
                VStack(spacing: 0) {
                    HoldButton(icon: "plus", style: .top) { ptz.start(x: 0, y: 0, zoom: speed) } onRelease: { ptz.stop() }
                    Divider().overlay(Theme.hairline).frame(width: 40)
                    HoldButton(icon: "minus", style: .bottom) { ptz.start(x: 0, y: 0, zoom: -speed) } onRelease: { ptz.stop() }
                }
                .background(Theme.cardRaised, in: Capsule())
                .overlay(Capsule().stroke(Theme.hairline))
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("轉動速度").font(.subheadline).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text(speed < 0.4 ? "慢" : (speed < 0.75 ? "中" : "快")).font(.subheadline).foregroundStyle(Theme.secondary)
                }
                Slider(value: $speed, in: 0.15...1)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("預置點").font(.subheadline).foregroundStyle(Theme.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ptz.presets, id: \.token) { p in
                            Button { Theme.haptic(); ptz.goto(p.token) } label: {
                                Text(p.name).font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(Theme.cardRaised, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        Button { askName = true } label: {
                            Label("存目前位置", systemImage: "plus").font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .overlay(Capsule().stroke(Theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !ptz.error.isEmpty { Text(ptz.error).font(.footnote).foregroundStyle(Theme.rec) }
        }
        .card()
        .task { await ptz.loadPresets() }
        .onDisappear { ptz.stop() }
        .alert("預置點名稱", isPresented: $askName) {
            TextField("例如：門口", text: $newPreset)
            Button("儲存") { let n = newPreset; Task { await ptz.savePreset(n.isEmpty ? "預置點" : n) }; newPreset = "" }
            Button("取消", role: .cancel) {}
        }
    }

    private func arrow(_ icon: String, _ x: Double, _ y: Double) -> some View {
        HoldButton(icon: icon, style: .circle) {
            ptz.start(x: x * speed, y: y * speed, zoom: 0)
        } onRelease: {
            ptz.stop()
        }
    }
}

struct HoldButton: View {
    enum Style { case circle, top, bottom }
    let icon: String
    var style: Style = .circle
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: icon)
            .font(.title3.weight(.bold))
            .foregroundStyle(pressed ? Color.white : Theme.secondary)
            .frame(width: 56, height: 56)
            .background {
                if pressed { Circle().fill(Theme.accent).padding(style == .circle ? 0 : 4) }
            }
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.15), value: pressed)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed { pressed = true; onPress(); Theme.haptic() }
                }
                .onEnded { _ in pressed = false; onRelease() })
            .accessibilityAddTraits(.isButton)
    }
}
