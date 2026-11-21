import SwiftUI

@main
struct HomeCamApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    @State private var wasBackground = false

    init() { Theme.applyAppearance() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .onChange(of: phase) { _, newPhase in
            switch newPhase {
            case .background:
                wasBackground = true
                model.didEnterBackground()
            case .active:
                if wasBackground {
                    wasBackground = false
                    model.willEnterForeground()
                }
            default:
                break
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @State private var tab = 0

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                NavigationStack { LiveView() }
                    .tabItem { Label("即時", systemImage: "video") }.tag(0)
                NavigationStack { RecordingsView() }
                    .tabItem { Label("回放", systemImage: "play.rectangle") }.tag(1)
                NavigationStack { TranscriptsView() }
                    .tabItem { Label("逐字稿", systemImage: "text.bubble") }.tag(2)
                NavigationStack { EventsView() }
                    .tabItem { Label("事件", systemImage: "bell") }.tag(3)
                NavigationStack { SettingsView() }
                    .tabItem { Label("設定", systemImage: "gearshape") }.tag(4)
            }

            // 停機中：解除前只能看到這個畫面
            if model.settings.lockdownActive {
                NavigationStack { LockdownView() }
                    .transition(.opacity)
            }

            // 隱私遮罩：切到多工畫面時，系統截圖只會看到這個，不會看到家裡畫面
            if phase != .active || model.locked {
                PrivacyCover(showUnlock: model.locked && phase == .active)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) { ToastView() }
        .alert(SecurityCenter.shared.pendingDecision?.title ?? "偵測到異常", isPresented: Binding(
            get: { SecurityCenter.shared.pendingDecision != nil && !model.locked && phase == .active },
            set: { if !$0 { SecurityCenter.shared.pendingDecision = nil } })) {
            Button("立即停機", role: .destructive) {
                let a = SecurityCenter.shared.pendingDecision
                model.lockdown(reason: a?.title ?? "使用者選擇停機")
                if let a { SecurityCenter.shared.markHandled(a.id) }
            }
            Button("先不要", role: .cancel) {
                if let a = SecurityCenter.shared.pendingDecision { SecurityCenter.shared.markHandled(a.id) }
            }
        } message: {
            Text("\(SecurityCenter.shared.pendingDecision?.detail ?? "")\n\n要立即停機嗎？（切斷所有攝影機、停止錄影）")
        }
        .modifier(AppTextSize(option: model.settings.textSize))
        .animation(.snappy, value: model.toast)
    }
}

struct PrivacyCover: View {
    @Environment(AppModel.self) private var model
    let showUnlock: Bool

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            RadialGradient(colors: [Theme.accent.opacity(0.18), .clear], center: .top, startRadius: 0, endRadius: 420)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "video.badge.checkmark")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 96, height: 96)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Theme.hairline))
                Text("HomeCam").font(.title.weight(.semibold)).fontDesign(.rounded)
                Text("你的畫面只存在這支 iPhone").font(.subheadline).foregroundStyle(Theme.secondary)
                if showUnlock {
                    Button {
                        Task { await model.unlock() }
                    } label: {
                        Label("使用 \(AppLock.biometryName) 解鎖", systemImage: "faceid")
                            .font(.headline)
                            .frame(maxWidth: 260)
                            .padding(.vertical, 14)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 18)
                }
            }
            .padding(32)
        }
        .task(id: showUnlock) {
            // 每次上鎖只自動跳一次 Face ID；取消後改按按鈕，避免一直跳出
            if showUnlock && model.autoPromptPending {
                model.autoPromptPending = false
                await model.unlock()
            }
        }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let t = model.toast {
            Text(t)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Theme.hairline))
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                .padding(.horizontal, 24)
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: t) {
                    try? await Task.sleep(nanoseconds: 2_200_000_000)
                    if model.toast == t { model.toast = nil }
                }
        }
    }
}
