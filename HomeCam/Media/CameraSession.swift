import AVFoundation
import CoreImage
import Observation
import UIKit

/// 包住一個 C 影音核心；C 回呼在核心執行緒上，這裡轉給 CameraSession
final class EngineHandle {
    private(set) var ptr: OpaquePointer?
    weak var session: CameraSession?
    let isRecordEngine: Bool

    init?(url: String, session: CameraSession, recordEngine: Bool) {
        self.session = session
        self.isRecordEngine = recordEngine
        var cb = HCCallbacks()
        cb.ctx = Unmanaged.passUnretained(self).toOpaque()
        cb.on_state = { ctx, state, msg in
            guard let ctx else { return }
            let h = Unmanaged<EngineHandle>.fromOpaque(ctx).takeUnretainedValue()
            h.session?.engineState(state, msg.map { String(cString: $0) } ?? "", recordEngine: h.isRecordEngine)
        }
        cb.on_video_frame = { ctx, frame in
            guard let ctx, let frame else { return }
            let h = Unmanaged<EngineHandle>.fromOpaque(ctx).takeUnretainedValue()
            if !h.isRecordEngine { h.session?.engineFrame(frame) }
        }
        cb.on_audio = { ctx, samples, count in
            guard let ctx, let samples else { return }
            let h = Unmanaged<EngineHandle>.fromOpaque(ctx).takeUnretainedValue()
            if !h.isRecordEngine { h.session?.engineAudio(samples, Int(count)) }
        }
        cb.on_motion = { ctx, ratio, active in
            guard let ctx else { return }
            let h = Unmanaged<EngineHandle>.fromOpaque(ctx).takeUnretainedValue()
            h.session?.engineMotion(ratio, active != 0)
        }
        cb.on_record = { ctx, opened, path, err in
            guard let ctx else { return }
            let h = Unmanaged<EngineHandle>.fromOpaque(ctx).takeUnretainedValue()
            h.session?.engineRecord(opened != 0, path.map { String(cString: $0) } ?? "", err.map { String(cString: $0) })
        }
        guard let p = hc_engine_create(url, cb) else { return nil }
        ptr = p
    }

    func start() { if let ptr { hc_engine_start(ptr) } }

    /// 停止並釋放（在背景執行緒等核心收尾，不卡畫面）
    func shutdown() {
        guard let p = ptr else { return }
        ptr = nil
        session = nil
        DispatchQueue.global(qos: .utility).async {
            let task = UIApplication.shared.beginBackgroundTask(withName: "close-recording")
            hc_engine_destroy(p)
            _ = self            // 確保回呼結束前物件仍存在
            if task != .invalid { DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(task) } }
        }
    }
}

@Observable
final class CameraSession: Identifiable {
    var config: CameraConfig
    var id: String { config.id }

    // 狀態（主執行緒更新，給畫面用）
    var state: Int32 = HC_STATE_STOPPED
    var message = ""
    var fps: Float = 0
    var kbps: Float = 0
    var resolution = ""
    var codec = ""
    var motionActive = false
    var recording = false
    var recordReason = ""
    var audioLevel: Float = 0
    var speaking = false
    var listening = false
    var transcribeStatus = ""
    var hasVideo = false

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored let transcriber = Transcriber()
    @ObservationIgnored private var live: EngineHandle?        // 每台攝影機只有這一條連線
    @ObservationIgnored private var liveURL = ""
    @ObservationIgnored var suspended = false                   // 記憶卡回放時暫停即時連線（維持單一連線）
    @ObservationIgnored private var blockedReported = false
    @ObservationIgnored private var authReported = false
    @ObservationIgnored private var streamChangeReported = false
    @ObservationIgnored private var identityChecked = false
    @ObservationIgnored private let displays = NSHashTable<AVSampleBufferDisplayLayer>.weakObjects()
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var latestFrame: CVPixelBuffer?
    @ObservationIgnored private var showFrames = false
    @ObservationIgnored private var listeningFlag = false
    @ObservationIgnored private var transcribingFlag = false
    @ObservationIgnored private var formatDesc: CMVideoFormatDescription?
    @ObservationIgnored private var lastLevelUpdate = Date.distantPast
    @ObservationIgnored private var wasPlaying = false
    @ObservationIgnored private var everPlayed = false
    @ObservationIgnored private(set) var viewers = 0
    @ObservationIgnored private var background = false
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(config: CameraConfig) {
        self.config = config
        transcriber.onText = { [weak self] text, date in
            DispatchQueue.main.async { if let self { self.model?.transcribed(self, text: text, at: date) } }
        }
        transcriber.onStatus = { [weak self] s in
            DispatchQueue.main.async { self?.transcribeStatus = s }
        }
    }

    // MARK: 網址（帳密只在這裡從 Keychain 組進去）

    private func credentialed(_ url: String) -> String {
        URLCredential.inject(url, user: config.username, password: Keychain.password(for: config.id))
    }

    // MARK: 需求計算：依照「有沒有人在看 / 值守 / 偵測 / 逐字稿 / 錄影」決定要開哪些連線

    func update(appActive: Bool, guardOn: Bool) {
        let c = config
        guard c.enabled, !suspended, !(model?.settings.lockdownActive ?? false) else { stopEngines(); return }
        let monitoring = appActive || guardOn
        let watch = viewers > 0 && appActive
        let motion = c.motion && monitoring
        let stt = c.transcribe && monitoring
        let continuous = c.recordMode == .continuous && guardOn
        let motionRecArmed = motion && c.recordMode == .motion
        let wantRecording = recordReason == "manual" || continuous || (recordReason == "motion" && recording)
        let needLive = watch || motion || stt || listening || wantRecording || motionRecArmed

        if needLive {
            // 連線白名單：只連家中區域網路的位址
            guard NetGuard.allows(url: c.streamURL) else {
                if !blockedReported {
                    blockedReported = true
                    SecurityCenter.shared.log(.blockedHost, .critical, "串流位址不是家中區域網路，已拒絕連線", camera: c.name)
                }
                stopEngines()
                return
            }
            let url = credentialed(c.streamURL)
            if live == nil || url != liveURL {
                live?.shutdown()
                liveURL = url
                identityChecked = false
                live = EngineHandle(url: url, session: self, recordEngine: false)
                live?.start()
            }
        } else if live != nil {
            live?.shutdown(); live = nil
            DispatchQueue.main.async { self.state = HC_STATE_STOPPED; self.motionActive = false }
        }

        if let p = live?.ptr {
            hc_engine_set_video_enabled(p, watch ? 1 : 0)
            hc_engine_set_audio_enabled(p, (listening || stt) ? 1 : 0)
            hc_engine_set_motion(p, motion ? 1 : 0, Int32(c.motionSensitivity))
            hc_engine_set_hw_decode(p, background ? 0 : 1)
        }
        lock.lock()
        showFrames = watch
        listeningFlag = listening
        transcribingFlag = stt
        lock.unlock()

        if stt && !transcriberRunning {
            transcriberRunning = true
            transcriber.start(onDeviceOnly: model?.settings.speechOnDeviceOnly ?? true)
        } else if !stt && transcriberRunning {
            transcriberRunning = false
            transcriber.stop()
            transcribeStatus = ""
        }

        if continuous && !recording && recordReason != "manual" { startRecording(reason: "continuous") }
        if !continuous && recordReason == "continuous" { stopRecording() }
    }
    @ObservationIgnored private var transcriberRunning = false

    func restartTranscriber() {
        if transcriberRunning { transcriber.stop(); transcriberRunning = false }
        requestUpdate()
    }

    func setBackground(_ bg: Bool) {
        background = bg
        if let p = live?.ptr { hc_engine_set_hw_decode(p, bg ? 0 : 1) }   // iOS 背景不能用硬體解碼
    }

    func stopEngines() {
        live?.shutdown(); live = nil
        if transcriberRunning { transcriber.stop(); transcriberRunning = false }
        if listening { setListening(false) }
        state = HC_STATE_STOPPED
        motionActive = false
        recording = false
        recordReason = ""
    }

    /// 有 AppModel 時統一重算；獨立播放（記憶卡回放）時自己更新
    private func requestUpdate() {
        if let model { model.refreshDemand() } else { update(appActive: true, guardOn: false) }
    }

    // MARK: 觀看

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        displays.add(layer)
        viewers += 1
        requestUpdate()
    }

    func detach(_ layer: AVSampleBufferDisplayLayer) {
        displays.remove(layer)
        viewers = max(0, viewers - 1)
        requestUpdate()
    }

    func setListening(_ on: Bool) {
        guard on != listening else { return }
        listening = on
        AudioOut.shared.setListening(on)
        requestUpdate()
    }

    // MARK: 錄影

    func startRecording(reason: String) {
        let seg = Int32((model?.settings.segmentMinutes ?? 10) * 60)
        let post = Int32(model?.settings.motionPostSeconds ?? 30)
        let dir = Storage.cameraDir(Storage.recordings, config.id).path
        if reason == "motion" && (recordReason == "manual" || recordReason == "continuous") { return }
        recordReason = reason
        recording = true
        requestUpdate()
        guard let p = live?.ptr else { return }
        hc_engine_start_recording(p, dir, config.id, seg, reason == "motion" ? post : 0)
    }

    func stopRecording() {
        if let p = live?.ptr { hc_engine_stop_recording(p) }
        recording = false
        recordReason = ""
        requestUpdate()
    }

    /// 每秒更新統計
    func tick() {
        var info = HCInfo()
        if let p = live?.ptr {
            hc_engine_get_info(p, &info)
            fps = info.fps
            kbps = info.kbps
            if info.width > 0 { resolution = "\(info.width)×\(info.height)" }
            codec = cString(info.video_codec)
            checkStreamFingerprint()
        }
        if recording, let p = live?.ptr {
            var ri = HCInfo()
            hc_engine_get_info(p, &ri)
            if ri.recording == 0 && recordReason == "motion" {      // 移動錄影時間到自動結束
                recording = false
                recordReason = ""
                requestUpdate()
            }
        }
    }

    /// 串流指紋（編碼＋解析度）：第一次記住，之後改變就記錄為安全事件（可能被替換或韌體遭竄改）
    private func checkStreamFingerprint() {
        guard model != nil, !codec.isEmpty, !resolution.isEmpty, state == HC_STATE_PLAYING else { return }
        let fp = "\(codec) \(resolution)"
        if config.pinnedVideo.isEmpty {
            var c = config; c.pinnedVideo = fp; model?.updateCamera(c)
        } else if fp != config.pinnedVideo && !streamChangeReported {
            streamChangeReported = true
            SecurityCenter.shared.log(.streamChanged, .medium, "原本 \(config.pinnedVideo)，現在 \(fp)", camera: config.name)
        }
    }

    /// 使用者確認攝影機設定是自己改的之後，重新記住串流指紋
    func resetFingerprint() {
        var c = config; c.pinnedVideo = ""; model?.updateCamera(c)
        streamChangeReported = false
    }

    // MARK: 截圖

    func snapshotJPEG() -> Data? {
        lock.lock(); let pb = latestFrame; lock.unlock()
        guard let pb else { return nil }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = Self.ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
    }

    // MARK: C 核心回呼（核心執行緒）

    fileprivate func engineState(_ s: Int32, _ msg: String, recordEngine: Bool) {
        guard !recordEngine else { return }
        DispatchQueue.main.async {
            self.state = s
            self.message = msg
            let name = self.config.name
            if s == HC_STATE_PLAYING {
                if !self.wasPlaying && self.everPlayed { self.model?.addEvent(self, .online, "已重新連線") }
                if !self.wasPlaying { SecurityCenter.shared.log(.cameraConnected, .info, "已連線", camera: name) }
                self.wasPlaying = true
                self.everPlayed = true
                self.authReported = false
                if !self.identityChecked {
                    self.identityChecked = true
                    self.model?.verifyIdentity(self)
                }
            } else if s == HC_STATE_RETRYING || s == HC_STATE_AUTH_FAILED {
                if self.wasPlaying || s == HC_STATE_AUTH_FAILED { self.model?.addEvent(self, .offline, "離線：\(msg)") }
                if self.wasPlaying { SecurityCenter.shared.log(.cameraDisconnected, .info, msg, camera: name) }
                if s == HC_STATE_AUTH_FAILED && !self.authReported && self.model != nil {
                    self.authReported = true
                    SecurityCenter.shared.log(.authFailure, .high, "攝影機拒絕目前的帳號密碼", camera: name)
                }
                self.wasPlaying = false
                self.hasVideo = false
            }
        }
    }

    fileprivate func engineFrame(_ f: UnsafePointer<HCVideoFrame>) {
        guard let raw = f.pointee.pixel_buffer else { return }       // 背景軟體解碼時沒有可顯示的畫面
        let pb = Unmanaged<CVPixelBuffer>.fromOpaque(raw).takeUnretainedValue()
        lock.lock()
        latestFrame = pb
        let show = showFrames
        lock.unlock()
        guard show, let sb = makeSampleBuffer(pb) else { return }
        DispatchQueue.main.async {
            if !self.hasVideo { self.hasVideo = true }
            for layer in self.displays.allObjects {
                let r = layer.sampleBufferRenderer
                if r.status == .failed { r.flush() }
                r.enqueue(sb)
            }
        }
    }

    private func makeSampleBuffer(_ pb: CVPixelBuffer) -> CMSampleBuffer? {
        if formatDesc == nil || !CMVideoFormatDescriptionMatchesImageBuffer(formatDesc!, imageBuffer: pb) {
            var fd: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fd)
            formatDesc = fd
        }
        guard let fd = formatDesc else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: fd,
                                                       sampleTiming: &timing, sampleBufferOut: &out) == noErr, let sb = out else { return nil }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }

    fileprivate func engineAudio(_ samples: UnsafePointer<Int16>, _ count: Int) {
        lock.lock(); let listen = listeningFlag, stt = transcribingFlag; lock.unlock()
        guard listen || stt, let (buf, rms) = makePCMBuffer(samples, count: count) else { return }
        if listen { AudioOut.shared.play(buf) }
        if stt { transcriber.feed(buf, rms: rms) }
        let now = Date()
        if now.timeIntervalSince(lastLevelUpdate) > 0.15 {
            lastLevelUpdate = now
            let level = min(1, rms * 6)
            let talking = transcriber.speaking
            DispatchQueue.main.async { self.audioLevel = level; self.speaking = talking }
        }
    }

    fileprivate func engineMotion(_ ratio: Float, _ active: Bool) {
        DispatchQueue.main.async {
            if self.motionActive != active { self.motionActive = active }
            if active { self.model?.motionDetected(self, ratio: ratio) }
        }
    }

    fileprivate func engineRecord(_ opened: Bool, _ path: String, _ error: String?) {
        DispatchQueue.main.async {
            if let error, !error.isEmpty {
                self.recording = false
                self.recordReason = ""
                self.model?.addEvent(self, .record, "錄影停止：\(error)")
            }
            if !opened { self.model?.recordingClosed(self, path: path) }
        }
    }
}
