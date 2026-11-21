import Foundation
import Observation
import Speech
import UIKit

@Observable
final class AppModel {
    var cameras: [CameraConfig] = []
    var sessions: [String: CameraSession] = [:]
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            Storage.save(settings, to: Storage.settingsFile)
            applySettings(old: oldValue)
        }
    }
    var events: [CameraEvent] = []
    var liveTranscripts: [TranscriptLine] = []
    var locked: Bool { didSet { if locked && !oldValue { autoPromptPending = true } } }
    @ObservationIgnored var autoPromptPending = true
    var appActive = true
    var storageUsed: Int64 = 0
    var toast: String?

    @ObservationIgnored private var lastMotionNotify: [String: Date] = [:]
    @ObservationIgnored private var lastMotionRecord: [String: Date] = [:]
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var cleanupTimer: Timer?

    init() {
        // 1. 先確認資料屬於這支 iPhone；不是的話全部清掉（防止資料被複製到別台裝置使用）
        var binding = Storage.prepare()
        if binding == .foreign {
            Storage.wipeAll()
            binding = Storage.prepare()
            binding = .foreign
        }
        Storage.clearTemp()
        let s = Storage.load(AppSettings.self, from: Storage.settingsFile, default: AppSettings())
        settings = s
        locked = s.appLock || s.lockdownActive
        cameras = Storage.loadCameras()
        if Storage.allowPlaintextMigration {          // 舊版明文資料：立即改存成加密格式
            Storage.save(s, to: Storage.settingsFile)
            Storage.save(cameras, to: Storage.configFile)
            Storage.allowPlaintextMigration = false
        }
        events = EventLog.loadRecent()
        for c in cameras { makeSession(c) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.sessions.values.forEach { $0.tick() }
        }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.cleanup() }
        cleanup()
        SecurityCenter.shared.start(model: self, binding: binding)
        applySettings(old: nil)
        refreshDemand()
    }

    var orderedSessions: [CameraSession] { cameras.compactMap { sessions[$0.id] } }

    @discardableResult
    private func makeSession(_ c: CameraConfig) -> CameraSession {
        let s = CameraSession(config: c)
        s.model = self
        sessions[c.id] = s
        return s
    }

    // MARK: 攝影機管理

    func addCamera(_ c: CameraConfig, password: String) {
        Keychain.setPassword(password, for: c.id)
        cameras.append(c)
        saveCameras()
        makeSession(c)
        addEvent(nil, .system, "已新增攝影機「\(c.name)」")
        SecurityCenter.shared.log(.cameraAdded, .info, "\(c.host)\(c.serial.isEmpty ? "" : "，序號已記錄")", camera: c.name)
        Task { _ = await Notifier.requestPermission() }
        refreshDemand()
    }

    func updateCamera(_ c: CameraConfig) {
        guard let i = cameras.firstIndex(where: { $0.id == c.id }) else { return }
        cameras[i] = c
        sessions[c.id]?.config = c
        saveCameras()
        refreshDemand()
        if c.transcribe && SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            Task {
                _ = await Transcriber.requestAuthorization()
                await MainActor.run { self.sessions[c.id]?.restartTranscriber() }
            }
        }
    }

    func removeCamera(_ id: String) {
        if let c = cameras.first(where: { $0.id == id }) { SecurityCenter.shared.log(.cameraRemoved, .low, c.host, camera: c.name) }
        sessions[id]?.stopEngines()
        sessions[id] = nil
        cameras.removeAll { $0.id == id }
        Keychain.delete(cameraID: id)
        saveCameras()
    }

    func moveCameras(from: IndexSet, to: Int) {
        cameras.move(fromOffsets: from, toOffset: to)
        saveCameras()
    }

    private func saveCameras() { Storage.save(cameras, to: Storage.configFile) }

    // MARK: 生命週期

    func refreshDemand() {
        for s in sessions.values { s.update(appActive: appActive, guardOn: settings.guardMode && !settings.lockdownActive) }
    }

    // MARK: 停機

    /// 立即停機：切斷所有攝影機、停止錄影與值守、鎖住 App。解除必須通過 Face ID
    func lockdown(reason: String) {
        guard !settings.lockdownActive else { return }
        var s = settings
        s.lockdownActive = true
        s.lockdownReason = reason
        s.guardMode = false
        settings = s
        for x in sessions.values { x.stopEngines() }
        if settings.appLock { locked = true }
        SecurityCenter.shared.pendingDecision = nil
        SecurityCenter.shared.log(.lockdown, .high, reason)
        addEvent(nil, .system, "已停機：\(reason)")
        Notifier.post(title: "HomeCam 已停機", body: reason, image: nil, hideContent: settings.hideNotificationContent)
    }

    func releaseLockdown() async {
        guard await AppLock.authenticate(reason: "解除停機") else { return }
        await MainActor.run {
            var s = self.settings
            s.lockdownActive = false
            s.lockdownReason = ""
            self.settings = s
            SecurityCenter.shared.log(.lockdownReleased, .medium, "使用者驗證後解除停機")
            self.refreshDemand()
        }
    }

    /// 連線後核對攝影機身分（ONVIF 序號）。序號不同代表這個 IP 上已經是另一台裝置
    func verifyIdentity(_ s: CameraSession) {
        let c = s.config
        guard !c.onvifURL.isEmpty, let u = URL(string: c.onvifURL) else { return }
        Task {
            let client = ONVIFClient(deviceURL: u, username: c.username, password: Keychain.password(for: c.id), timeout: 5)
            let info = await client.deviceInfo()
            await MainActor.run {
                guard !info.serial.isEmpty else { return }
                if c.serial.isEmpty {
                    var n = c; n.serial = info.serial; self.updateCamera(n)
                    SecurityCenter.shared.log(.identityVerified, .info, "首次記錄攝影機序號", camera: c.name)
                } else if c.serial != info.serial {
                    SecurityCenter.shared.log(.identityMismatch, .critical,
                                              "序號應為 …\(c.serial.suffix(4))，實際為 …\(info.serial.suffix(4))", camera: c.name)
                } else {
                    SecurityCenter.shared.log(.identityVerified, .info, "序號相符", camera: c.name)
                }
            }
        }
    }

    func didEnterBackground() {
        SecurityCenter.shared.log(.appBackground, .info, settings.guardMode ? "值守中進入背景" : "進入背景，攝影機連線全部中斷")
        appActive = false
        backgroundedAt = Date()
        sessions.values.forEach { $0.setBackground(true) }
        refreshDemand()          // 沒開值守：全部斷線（隱私＋省電）；有值守：繼續偵測/錄影/逐字稿
    }

    func willEnterForeground() {
        if settings.appLock, let t = backgroundedAt, Date().timeIntervalSince(t) >= Double(settings.lockGraceSeconds) {
            locked = true
        }
        appActive = true
        SecurityCenter.shared.log(.appForeground, .info, "回到前景")
        SecurityCenter.shared.checkIntegrity()
        sessions.values.forEach { $0.setBackground(false) }
        refreshDemand()
        storageUsed = Storage.usage()
    }

    func unlock() async {
        if await AppLock.authenticate() {
            await MainActor.run { self.locked = false }
        }
    }

    private func applySettings(old: AppSettings?) {
        if let old { logSettingChanges(old) }
        SecurityCenter.shared.updateAIStatus()
        if old?.guardMode != settings.guardMode {
            AudioOut.shared.setKeepAlive(settings.guardMode)
            if old != nil {
                addEvent(nil, .system, settings.guardMode ? "值守模式：開啟" : "值守模式：關閉")
                if settings.guardMode { Task { _ = await Notifier.requestPermission() } }
            }
        }
        UIApplication.shared.isIdleTimerDisabled = settings.guardMode && settings.guardKeepScreenOn
        if old?.speechOnDeviceOnly != settings.speechOnDeviceOnly, old != nil {
            // 重新啟動逐字稿以套用新設定
            for s in sessions.values where s.config.transcribe {
                var c = s.config; c.transcribe = false; s.config = c; s.update(appActive: appActive, guardOn: settings.guardMode)
                c.transcribe = true; s.config = c
            }
        }
        refreshDemand()
    }

    /// 降低安全性的設定變更會記錄下來給 AI 判讀
    private func logSettingChanges(_ old: AppSettings) {
        let s = settings
        var weakened: [String] = []
        if old.appLock && !s.appLock { weakened.append("關閉 App 鎖") }
        if old.hideNotificationContent && !s.hideNotificationContent { weakened.append("通知改為顯示內容") }
        if old.speechOnDeviceOnly && !s.speechOnDeviceOnly { weakened.append("允許語音送到伺服器辨識") }
        if old.autoLockdown && !s.autoLockdown { weakened.append("關閉自動停機") }
        if old.aiReview && !s.aiReview { weakened.append("關閉 AI 判讀") }
        if old.blurWhenCaptured && !s.blurWhenCaptured { weakened.append("關閉錄螢幕遮蔽") }
        if !weakened.isEmpty { SecurityCenter.shared.log(.settingChanged, .low, weakened.joined(separator: "、")) }
        if old.guardMode != s.guardMode { SecurityCenter.shared.log(.settingChanged, .info, s.guardMode ? "開啟值守" : "關閉值守") }
    }

    // MARK: 事件

    func addEvent(_ s: CameraSession?, _ kind: CameraEvent.Kind, _ message: String, snapshot: String? = nil) {
        let e = CameraEvent(cameraID: s?.id ?? "", cameraName: s?.config.name ?? "系統", kind: kind, message: message, snapshot: snapshot)
        events.append(e)
        if events.count > 500 { events.removeFirst(events.count - 500) }
        EventLog.append(e)
    }

    func saveSnapshot(_ s: CameraSession, tag: String) -> String? {
        guard let jpg = s.snapshotJPEG() else { return nil }
        let name = "\(s.id)_\(Fmt.fileStamp.string(from: Date()))_\(tag).jpg"
        Storage.writeSealed(jpg, to: Storage.snapshots.appendingPathComponent(name))
        return name
    }

    func takeSnapshot(_ s: CameraSession) {
        if let name = saveSnapshot(s, tag: "snap") {
            addEvent(s, .snapshot, "手動截圖", snapshot: name)
            toast = "已截圖，可在「事件」查看"
        } else {
            toast = "目前沒有畫面"
        }
    }

    func motionDetected(_ s: CameraSession, ratio: Float) {
        let now = Date()
        if s.config.recordMode == .motion, now.timeIntervalSince(lastMotionRecord[s.id] ?? .distantPast) > 1 {
            lastMotionRecord[s.id] = now
            s.startRecording(reason: "motion")         // 持續有移動就一直延長
        }
        guard now.timeIntervalSince(lastMotionNotify[s.id] ?? .distantPast) > Double(settings.motionCooldownSeconds) else { return }
        lastMotionNotify[s.id] = now
        let snap = saveSnapshot(s, tag: "motion")
        addEvent(s, .motion, String(format: "偵測到移動（%.1f%%）", ratio * 100), snapshot: snap)
        if settings.notifyMotion && (settings.guardMode || !appActive) {
            let img = snap.flatMap { Storage.readSnapshot($0) }
            Notifier.post(title: "\(s.config.name)：偵測到移動", body: Fmt.dateTime.string(from: now), image: img,
                          hideContent: settings.hideNotificationContent)
        }
    }

    func transcribed(_ s: CameraSession, text: String, at date: Date) {
        let line = TranscriptLine(date: date, cameraID: s.id, cameraName: s.config.name, text: text)
        TranscriptLog.append(line)
        liveTranscripts.append(line)
        if liveTranscripts.count > 300 { liveTranscripts.removeFirst(liveTranscripts.count - 300) }
        guard settings.notifyKeywords else { return }
        for kw in settings.keywords where !kw.isEmpty && text.localizedCaseInsensitiveContains(kw) {
            let snap = saveSnapshot(s, tag: "keyword")
            addEvent(s, .keyword, "聽到「\(kw)」：\(text)", snapshot: snap)
            let img = snap.flatMap { Storage.readSnapshot($0) }
            Notifier.post(title: "\(s.config.name)：聽到「\(kw)」", body: text, image: img,
                          hideContent: settings.hideNotificationContent)
            break
        }
    }

    func recordingClosed(_ s: CameraSession, path: String) {
        storageUsed = Storage.usage()
    }

    // MARK: 儲存空間 / 清除

    func cleanup() {
        let busy = Set<String>()     // 錄影中的檔案修改時間是最新的，不會被當成最舊而刪除
        DispatchQueue.global(qos: .utility).async { [settings] in
            Storage.cleanup(settings: settings, busy: busy)
            let used = Storage.usage()
            DispatchQueue.main.async { self.storageUsed = used }
        }
    }

    func wipeAll() {
        for s in sessions.values { s.stopEngines() }
        sessions.removeAll()
        cameras.removeAll()
        events.removeAll()
        liveTranscripts.removeAll()
        SecurityCenter.shared.log(.dataWiped, .medium, "使用者清除所有資料")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            Storage.wipeAll()
            Storage.prepare()
        }
        settings = AppSettings()
    }
}
