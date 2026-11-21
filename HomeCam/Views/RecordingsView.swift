import AVKit
import SwiftUI

struct RecordingsView: View {
    @Environment(AppModel.self) private var model
    @State private var source = 0
    @State private var cameraID = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $source) {
                Text("手機錄影").tag(0)
                Text("攝影機記憶卡").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if model.cameras.isEmpty {
                ContentUnavailableView("還沒有攝影機", systemImage: "video.slash")
            } else {
                Picker("攝影機", selection: $cameraID) {
                    ForEach(model.cameras) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                if source == 0 { PhoneRecordings(cameraID: cameraID) } else { SDCardPlayback(cameraID: cameraID) }
            }
        }
        .background(Theme.bg)
        .navigationTitle("回放")
        .onAppear { if cameraID.isEmpty || !model.cameras.contains(where: { $0.id == cameraID }) { cameraID = model.cameras.first?.id ?? "" } }
    }
}

struct PhoneRecordings: View {
    @Environment(AppModel.self) private var model
    let cameraID: String
    @State private var files: [Recording] = []

    var body: some View {
        List {
            Section {
                Text("已用 \(Fmt.size(model.storageUsed))／上限 \(String(format: "%.0f", model.settings.maxStorageGB)) GB。錄影只存在這支手機的 App 內，已加密。")
                    .font(.footnote).foregroundStyle(Theme.secondary)
            }
            ForEach(groups, id: \.0) { day, items in
                Section(day) {
                    ForEach(items) { r in
                        NavigationLink {
                            PlayerView(recording: r)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "play.fill")
                                    .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                                    .frame(width: 40, height: 40)
                                    .background(Theme.accent.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Fmt.time.string(from: r.date)).font(.body.monospacedDigit().weight(.medium))
                                    Text(Fmt.size(r.size)).font(.footnote).foregroundStyle(Theme.tertiary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .onDelete { idx in
                        for i in idx { try? FileManager.default.removeItem(at: items[i].url) }
                        reload()
                    }
                }
            }
            if files.isEmpty {
                Text("還沒有錄影。在攝影機畫面按「錄影」，或設成「有移動才錄」。").foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { reload() }
        .onAppear(perform: reload)
        .onChange(of: cameraID) { _, _ in reload() }
    }

    private var groups: [(String, [Recording])] {
        let d = Dictionary(grouping: files) { Fmt.day.string(from: $0.date) }
        return d.keys.sorted(by: >).map { ($0, d[$0]!) }
    }

    private func reload() { files = Storage.listRecordings(cameraID: cameraID) }
}

struct PlayerView: View {
    let recording: Recording
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        VStack {
            if let player {
                VideoPlayer(player: player).aspectRatio(16 / 9, contentMode: .fit).captureShield()
            }
            Text(Fmt.dateTime.string(from: recording.date)).foregroundStyle(.secondary)
            Spacer()
        }
        .navigationTitle("錄影")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // 分享是你主動按才會發生；檔案不會自動上傳到任何地方
                ShareLink(item: recording.url) { Image(systemName: "square.and.arrow.up") }
                    .simultaneousGesture(TapGesture().onEnded {
                        SecurityCenter.shared.log(.export, .low, "分享錄影 \(recording.url.lastPathComponent)")
                    })
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
            }
        }
        .confirmationDialog("刪除這段錄影？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("刪除", role: .destructive) {
                try? FileManager.default.removeItem(at: recording.url)
                dismiss()
            }
        }
        .onAppear { player = AVPlayer(url: recording.url); player?.play() }
        .onDisappear { player?.pause() }
    }
}

/// 攝影機記憶卡回放：24 小時錄影存在攝影機自己的 microSD 卡，不經雲端
struct SDCardPlayback: View {
    @Environment(AppModel.self) private var model
    let cameraID: String
    @State private var start = Date().addingTimeInterval(-3600)
    @State private var playing: CameraSession?

    var camera: CameraConfig? { model.cameras.first { $0.id == cameraID } }

    var body: some View {
        Form {
            if let cam = camera {
                Section {
                    Picker("格式", selection: Binding(get: { cam.sdPlayback },
                                                     set: { var c = cam; c.sdPlayback = $0; model.updateCamera(c) })) {
                        ForEach(CameraConfig.SDPlayback.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("海康、大華/Imou/Amcrest 可直接從記憶卡回放。Tapo、Reolink 等不開放記憶卡串流，請用該品牌 App 的「本機回放」，並在 App 裡關閉雲端功能。")
                }
                if cam.sdPlayback != .none {
                    Section("從這個時間開始播") {
                        DatePicker("時間", selection: $start, in: ...Date())
                        Button {
                            playing?.stopEngines()
                            // 單一連線：回放期間暫停這台的即時連線
                            model.sessions[cam.id]?.suspended = true
                            model.refreshDemand()
                            var c = cam
                            c.id = cam.id
                            c.mainURL = playbackURL(cam, start)
                            c.subURL = ""
                            c.motion = false
                            c.transcribe = false
                            c.recordMode = .off
                            let s = CameraSession(config: c)
                            playing = s
                        } label: { Label("播放", systemImage: "play.fill") }
                    }
                    if let s = playing {
                        Section {
                            VideoView(session: s)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .listRowInsets(EdgeInsets())
                                .captureShield()
                            Text(s.statusText.isEmpty ? "播放中" : s.statusText).font(.footnote).foregroundStyle(Theme.secondary)
                            HStack {
                                Button { s.setListening(!s.listening) } label: {
                                    Label(s.listening ? "靜音" : "聲音", systemImage: s.listening ? "speaker.wave.2" : "speaker.slash")
                                }
                                Spacer()
                                Button("停止") { s.stopEngines(); playing = nil; resumeLive() }
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .onDisappear { playing?.stopEngines(); playing = nil; resumeLive() }
        .onChange(of: cameraID) { _, _ in playing?.stopEngines(); playing = nil; resumeLive() }
    }

    private func resumeLive() {
        for s in model.sessions.values where s.suspended { s.suspended = false }
        model.refreshDemand()
    }

    private func playbackURL(_ c: CameraConfig, _ t: Date) -> String {
        let port = URLComponents(string: c.mainURL)?.port ?? 554
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        switch c.sdPlayback {
        case .hikvision:
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"          // 海康用攝影機本地時間，但格式帶 Z
            return "rtsp://\(c.host):\(port)/Streaming/tracks/101?starttime=\(f.string(from: t))"
        case .dahua:
            f.dateFormat = "yyyy_MM_dd_HH_mm_ss"
            return "rtsp://\(c.host):\(port)/cam/playback?channel=1&starttime=\(f.string(from: t))"
        case .none:
            return c.mainURL
        }
    }
}
