import SwiftUI

struct LiveView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if model.cameras.isEmpty {
                    EmptyCameras { showAdd = true }
                } else {
                    SummaryBar()
                    if model.settings.guardMode { GuardBanner() }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], spacing: 20) {
                        ForEach(model.orderedSessions) { s in
                            NavigationLink(value: s.id) { CameraTile(session: s) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .navigationTitle("我的攝影機")
        .navigationDestination(for: String.self) { id in
            if let s = model.sessions[id] { CameraDetailView(session: s) }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: {
                    Image(systemName: "plus").font(.body.weight(.semibold))
                }
                .accessibilityLabel("新增攝影機")
            }
        }
        .sheet(isPresented: $showAdd) { AddCameraView() }
    }
}

/// 上方摘要：幾台上線、值守開關
struct SummaryBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let online = model.orderedSessions.filter { $0.state == HC_STATE_PLAYING }.count
        let recording = model.orderedSessions.filter(\.recording).count
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(online) / \(model.cameras.count) 台上線").font(.headline)
                Text(recording > 0 ? "\(recording) 台錄影中" : "全部在家中網路內處理")
                    .font(.subheadline).foregroundStyle(recording > 0 ? Theme.rec : Theme.secondary)
            }
            Spacer()
            Button {
                Theme.haptic(.medium)
                model.settings.guardMode.toggle()
            } label: {
                Label(model.settings.guardMode ? "值守中" : "值守", systemImage: model.settings.guardMode ? "shield.lefthalf.filled" : "shield")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(model.settings.guardMode ? Theme.rec.opacity(0.9) : Theme.cardRaised, in: Capsule())
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
        }
        .card()
    }
}

struct GuardBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bolt.shield.fill").font(.title3).foregroundStyle(Theme.rec)
            Text("值守中：App 在背景也會偵測移動、錄影與逐字稿。建議接上充電器。")
                .font(.subheadline).foregroundStyle(Theme.secondary).lineSpacing(3)
        }
        .card()
    }
}

struct EmptyCameras: View {
    let add: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 88, height: 88)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            VStack(spacing: 6) {
                Text("還沒有攝影機").font(.title3.weight(.semibold))
                Text("iPhone 連上家裡的 WiFi，\n就能自動找到同網路的攝影機")
                    .font(.body).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).lineSpacing(3)
            }
            Button(action: add) {
                Label("自動搜尋攝影機", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 90)
    }
}

struct CameraTile: View {
    let session: CameraSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                if session.config.enabled { VideoView(session: session, fill: true) } else { Theme.card }
                if !session.statusText.isEmpty {
                    VStack(spacing: 10) {
                        if session.state == HC_STATE_CONNECTING || (session.state == HC_STATE_PLAYING && !session.hasVideo) {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: session.config.enabled ? "wifi.exclamationmark" : "pause.circle")
                                .font(.title2).foregroundStyle(Theme.tertiary)
                        }
                        Text(session.statusText).font(.subheadline).foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
                // 上下漸層，讓文字在任何畫面上都清楚
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 64)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom).frame(height: 56)
                }
                .allowsHitTesting(false)
                VStack {
                    HStack(alignment: .top) {
                        LiveIndicator(s: session)
                        Spacer()
                        SessionBadges(s: session)
                    }
                    Spacer()
                    HStack {
                        if session.state == HC_STATE_PLAYING { LiveClock().foregroundStyle(.white.opacity(0.9)) }
                        Spacer()
                        if session.config.ptz {
                            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                                .font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
                .padding(12)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(session.motionActive ? Theme.motion : Theme.hairline, lineWidth: session.motionActive ? 2 : 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
            .captureShield()
            .animation(.easeInOut(duration: 0.25), value: session.motionActive)

            HStack(alignment: .firstTextBaseline) {
                Text(session.config.name).font(.headline)
                Spacer()
                Text(subtitle).font(.subheadline).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 4)
        }
    }

    private var subtitle: String {
        if session.recording { return "錄影中" }
        if session.motionActive { return "偵測到移動" }
        return session.config.host
    }
}
