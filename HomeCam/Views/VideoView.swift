import AVFoundation
import SwiftUI
import UIKit

final class DisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// 顯示攝影機畫面（硬體解碼後直接送到顯示層，低延遲、省電）
struct VideoView: UIViewRepresentable {
    let session: CameraSession
    var fill = false

    func makeUIView(context: Context) -> DisplayView {
        let v = DisplayView()
        v.backgroundColor = .black
        v.displayLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        let layer = v.displayLayer
        let s = session
        DispatchQueue.main.async { s.attach(layer) }
        context.coordinator.session = s
        return v
    }

    func updateUIView(_ v: DisplayView, context: Context) {
        v.displayLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    static func dismantleUIView(_ v: DisplayView, coordinator: Coordinator) {
        let layer = v.displayLayer
        let s = coordinator.session
        DispatchQueue.main.async { s?.detach(layer) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { weak var session: CameraSession? }
}

/// 被錄螢幕 / AirPlay 鏡像時遮蔽畫面
struct CaptureShield: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var captured = Self.isCaptured

    static var isCaptured: Bool {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.isCaptured }.contains(true)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if captured && model.settings.blurWhenCaptured {
                    ZStack {
                        Rectangle().fill(.black)
                        Label("偵測到錄螢幕或鏡像，已遮蔽", systemImage: "eye.slash").font(.subheadline).foregroundStyle(Theme.secondary)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                captured = Self.isCaptured
            }
    }
}

extension View {
    func captureShield() -> some View { modifier(CaptureShield()) }
}

struct SessionBadges: View {
    let s: CameraSession
    var body: some View {
        HStack(spacing: 6) {
            if !s.config.enabled { Pill(text: "停用", color: Theme.secondary) }
            else if s.state == HC_STATE_AUTH_FAILED { Pill(text: "密碼錯誤", color: Theme.rec, filled: true) }
            else if s.state != HC_STATE_PLAYING && s.state != HC_STATE_STOPPED { Pill(text: "離線", color: Theme.secondary, dot: true) }
            if s.recording { Pill(text: "REC", color: Theme.rec, dot: true, filled: true) }
            if s.motionActive { Pill(text: "移動", color: Theme.motion, dot: true) }
            if s.transcriberActive { Pill(text: "逐字稿", color: Theme.accent) }
        }
        .animation(.snappy, value: s.recording)
        .animation(.snappy, value: s.motionActive)
    }
}

/// 畫面左上角的連線狀態
struct LiveIndicator: View {
    let s: CameraSession
    var body: some View {
        let live = s.state == HC_STATE_PLAYING && s.hasVideo
        Pill(text: live ? "LIVE" : "—", color: live ? Theme.live : Theme.tertiary, dot: true)
    }
}

extension CameraSession {
    var transcriberActive: Bool { !transcribeStatus.isEmpty && config.transcribe }
    var statusText: String {
        if !config.enabled { return "已停用" }
        switch state {
        case HC_STATE_CONNECTING: return "連線中…"
        case HC_STATE_PLAYING: return hasVideo ? "" : "載入畫面…"
        case HC_STATE_STOPPED: return "待機"
        default: return message.isEmpty ? "離線" : message
        }
    }
}
