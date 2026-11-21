import CryptoKit
import Foundation
import Observation
import UIKit
import UserNotifications
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - 資料型別

enum Severity: Int, Codable, Comparable, CaseIterable {
    case info, low, medium, high, critical
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    var label: String {
        switch self {
        case .info: return "紀錄"
        case .low: return "低"
        case .medium: return "注意"
        case .high: return "高"
        case .critical: return "嚴重"
        }
    }
}

enum SecCategory: String, Codable {
    case appLaunch, appForeground, appBackground
    case unlockSuccess, unlockFailure
    case cameraConnected, cameraDisconnected, authFailure, identityMismatch, identityVerified, streamChanged
    case blockedHost, integrity, logTamper, binding
    case settingChanged, export, screenshot, screenCapture, networkChange
    case cameraAdded, cameraRemoved, dataWiped
    case lockdown, lockdownReleased, anomaly, aiReview

    var label: String {
        switch self {
        case .appLaunch: return "App 啟動"
        case .appForeground: return "回到前景"
        case .appBackground: return "進入背景"
        case .unlockSuccess: return "解鎖成功"
        case .unlockFailure: return "解鎖失敗"
        case .cameraConnected: return "攝影機連線"
        case .cameraDisconnected: return "攝影機斷線"
        case .authFailure: return "攝影機拒絕密碼"
        case .identityMismatch: return "攝影機身分不符"
        case .identityVerified: return "攝影機身分確認"
        case .streamChanged: return "串流參數改變"
        case .blockedHost: return "阻擋外部連線"
        case .integrity: return "執行環境異常"
        case .logTamper: return "紀錄遭竄改"
        case .binding: return "裝置綁定"
        case .settingChanged: return "設定變更"
        case .export: return "匯出資料"
        case .screenshot: return "截圖"
        case .screenCapture: return "錄螢幕/鏡像"
        case .networkChange: return "網路變化"
        case .cameraAdded: return "新增攝影機"
        case .cameraRemoved: return "移除攝影機"
        case .dataWiped: return "清除資料"
        case .lockdown: return "停機"
        case .lockdownReleased: return "解除停機"
        case .anomaly: return "異常"
        case .aiReview: return "AI 判讀"
        }
    }
}

/// 一筆安全紀錄。hash = SHA256(上一筆 hash + 本筆內容)，任何一筆被改或刪都會讓後面全部對不上
struct SecurityEvent: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var date = Date()
    var category: SecCategory
    var severity: Severity
    var camera: String = ""
    var detail: String
    var prev: String = ""
    var hash: String = ""

    func digest(prev: String) -> String {
        let s = [prev, id, String(date.timeIntervalSince1970), category.rawValue, String(severity.rawValue), camera, detail]
            .joined(separator: "|")
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var line: String {
        "\(Fmt.dateTime.string(from: date)) [\(severity.label)] \(category.label)\(camera.isEmpty ? "" : "「\(camera)」")：\(detail)"
    }
}

struct Anomaly: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var date = Date()
    var severity: Severity
    var title: String
    var detail: String
    var source: String          // 規則引擎 / 裝置端 AI
    var camera: String = ""
    var handled = false
}

// MARK: - 安全中心

@Observable
final class SecurityCenter {
    static let shared = SecurityCenter()

    var recent: [SecurityEvent] = []
    var anomalies: [Anomaly] = []
    var pendingDecision: Anomaly?
    var aiStatus = "準備中"
    var chainOK = true
    var integrityIssues: [String] = []

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var lastHash = "genesis"
    @ObservationIgnored private var started = false
    @ObservationIgnored private let netWatcher = NetworkWatcher()
    @ObservationIgnored private var aiDebounce: Task<Void, Never>?
    @ObservationIgnored private var lastAIRun = Date.distantPast
    @ObservationIgnored private var eventsSinceAI = 0
    @ObservationIgnored private var aiTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored let notificationDelegate = NotificationDelegate()

    private init() {}

    private var logFile: URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; f.locale = Locale(identifier: "en_US_POSIX")
        return Storage.security.appendingPathComponent("security-\(f.string(from: Date())).log")
    }

    // MARK: 啟動

    func start(model: AppModel, binding: Vault.BindingResult) {
        self.model = model
        guard !started else { return }
        started = true
        loadAndVerify()
        if binding == .foreign {
            log(.binding, .critical, "偵測到資料不屬於這支 iPhone（可能被複製或還原到別台），已全部清除")
        }
        log(.appLaunch, .info, "App 啟動")
        checkIntegrity()
        registerNotifications()
        netWatcher.onChange = { [weak self] kind in
            DispatchQueue.main.async { self?.log(.networkChange, .info, "網路切換為 \(kind)") }
        }
        netWatcher.start()
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.userDidTakeScreenshotNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.log(.screenshot, .info, "在 App 內截圖")
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIScreen.capturedDidChangeNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            let captured = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.isCaptured }.contains(true)
            if captured { self?.log(.screenCapture, .low, "畫面正在被錄製或鏡像") }
        })
        aiTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            guard let self, self.eventsSinceAI > 0 else { return }
            self.runAIReview(reason: "定時檢查")
        }
        updateAIStatus()
    }

    func checkIntegrity() {
        var issues = Integrity.jailbreakSignals()
        #if !DEBUG
        if Integrity.debuggerAttached { issues.append("有除錯器附加在 App 上") }
        #endif
        let new = issues.filter { !integrityIssues.contains($0) }
        integrityIssues = issues
        if !new.isEmpty { log(.integrity, .critical, new.joined(separator: "；")) }
    }

    // MARK: 紀錄（防竄改雜湊鏈）

    private func loadAndVerify() {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: Storage.security, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("security-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let dec = JSONDecoder()
        var prev = "genesis"
        var all: [SecurityEvent] = []
        var broken = false
        for f in files {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for raw in text.split(separator: "\n") {
                guard let line = Vault.openLine(raw), let e = try? dec.decode(SecurityEvent.self, from: Data(line.utf8)) else {
                    broken = true; continue
                }
                if e.prev != prev || e.digest(prev: e.prev) != e.hash { broken = true }
                prev = e.hash
                all.append(e)
            }
        }
        lastHash = prev
        recent = Array(all.suffix(500))
        anomalies = all.filter { $0.category == .anomaly }.suffix(100).map {
            Anomaly(date: $0.date, severity: $0.severity, title: $0.detail.components(separatedBy: "｜").first ?? $0.detail,
                    detail: $0.detail.components(separatedBy: "｜").dropFirst().joined(separator: "｜"),
                    source: "紀錄", camera: $0.camera, handled: true)
        }
        if broken {
            chainOK = false
            log(.logTamper, .critical, "安全紀錄驗證失敗：有紀錄被修改、刪除或無法解密")
        }
    }

    /// 寫入一筆安全紀錄並交給規則引擎判斷。任何執行緒都可以呼叫。
    func log(_ category: SecCategory, _ severity: Severity, _ detail: String, camera: String = "") {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.log(category, severity, detail, camera: camera) }
            return
        }
        var e = SecurityEvent(category: category, severity: severity, camera: camera, detail: detail)
        e.prev = lastHash
        e.hash = e.digest(prev: lastHash)
        lastHash = e.hash
        recent.append(e)
        if recent.count > 500 { recent.removeFirst(recent.count - 500) }
        if let d = try? JSONEncoder().encode(e), let s = String(data: d, encoding: .utf8) {
            Storage.appendSealed(line: s, to: logFile)
        }
        guard category != .anomaly && category != .aiReview else { return }
        if severity >= .low { eventsSinceAI += 1 }
        evaluate(e)
        if severity >= .medium { scheduleAIReview() }
    }

    // MARK: 規則引擎（確定性判斷，嚴重異常只由這裡觸發自動停機）

    private func count(_ cat: SecCategory, camera: String? = nil, within seconds: TimeInterval) -> Int {
        let since = Date().addingTimeInterval(-seconds)
        return recent.reversed().prefix(300).filter { $0.category == cat && $0.date >= since && (camera == nil || $0.camera == camera) }.count
    }

    private func evaluate(_ e: SecurityEvent) {
        switch e.category {
        case .blockedHost:
            raise(.critical, "阻擋了連往外部網路的連線", e.detail, camera: e.camera)
        case .identityMismatch:
            raise(.critical, "攝影機身分不符，可能被替換或冒充", e.detail, camera: e.camera)
        case .integrity:
            raise(.critical, "手機執行環境不安全", e.detail)
        case .logTamper:
            raise(.critical, "安全紀錄遭竄改", e.detail)
        case .binding where e.severity == .critical:
            raise(.critical, "資料來源不是這支 iPhone", e.detail)
        case .authFailure:
            raise(.high, "攝影機拒絕登入", "可能有人改了攝影機密碼，或這個 IP 上的已經不是你的攝影機。\(e.detail)", camera: e.camera)
        case .streamChanged:
            raise(.medium, "攝影機串流參數改變", e.detail, camera: e.camera)
        case .cameraDisconnected:
            if count(.cameraDisconnected, camera: e.camera, within: 600) >= 5 {
                raise(.medium, "攝影機頻繁斷線", "10 分鐘內斷線 5 次以上，可能是 WiFi 受到干擾或攻擊", camera: e.camera)
            }
            let cams = model?.cameras.filter(\.enabled).count ?? 0
            let since = Date().addingTimeInterval(-120)
            let downCams = Set(recent.filter { $0.category == .cameraDisconnected && $0.date >= since }.map(\.camera))
            if cams >= 2 && downCams.count >= cams {
                raise(.medium, "所有攝影機同時斷線", "可能是家中網路中斷、路由器重開，或 WiFi 被干擾")
            }
        case .unlockFailure:
            if count(.unlockFailure, within: 300) >= 3 {
                raise(.high, "多次解鎖失敗", "5 分鐘內有 3 次以上解鎖失敗，可能有人試圖打開 App")
            }
        case .screenCapture:
            raise(.low, "畫面正在被錄製或鏡像", e.detail)
        default:
            break
        }
    }

    // MARK: 異常處理：通知、詢問或自動停機

    func raise(_ severity: Severity, _ title: String, _ detail: String, camera: String = "", source: String = "規則引擎") {
        // 10 分鐘內相同異常不重複發
        if anomalies.contains(where: { $0.title == title && $0.camera == camera && Date().timeIntervalSince($0.date) < 600 }) { return }
        let a = Anomaly(severity: severity, title: title, detail: detail, source: source, camera: camera)
        anomalies.append(a)
        if anomalies.count > 100 { anomalies.removeFirst(anomalies.count - 100) }
        log(.anomaly, severity, "\(title)｜\(detail)", camera: camera)
        guard let model else { return }
        let s = model.settings
        if severity >= .medium {
            Notifier.postSecurity(a, hideContent: s.hideNotificationContent, askLockdown: severity >= .high && !(severity == .critical && s.autoLockdown))
        }
        if severity == .critical && s.autoLockdown && source == "規則引擎" {
            model.lockdown(reason: title)
        } else if severity >= .high && !s.lockdownActive {
            pendingDecision = a
        }
    }

    func markHandled(_ id: String) {
        if let i = anomalies.firstIndex(where: { $0.id == id }) { anomalies[i].handled = true }
        if pendingDecision?.id == id { pendingDecision = nil }
    }

    // MARK: 裝置端 AI 判讀（Apple Intelligence，完全離線）

    func updateAIStatus() {
        guard model?.settings.aiReview ?? true else { aiStatus = "已關閉"; return }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: aiStatus = "Apple 裝置端 AI（離線）運作中"
            case .unavailable(let r): aiStatus = "裝置端 AI 不可用（\(Self.reasonText(r))），改用本機規則引擎"
            @unknown default: aiStatus = "裝置端 AI 不可用，改用本機規則引擎"
            }
            return
        }
        #endif
        aiStatus = "此 iOS 版本不支援裝置端 AI，改用本機規則引擎"
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func reasonText(_ r: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch r {
        case .deviceNotEligible: return "此 iPhone 不支援 Apple Intelligence"
        case .appleIntelligenceNotEnabled: return "請到「設定 → Apple Intelligence 與 Siri」開啟"
        case .modelNotReady: return "模型下載中"
        @unknown default: return "暫時無法使用"
        }
    }
    #endif

    private func scheduleAIReview() {
        aiDebounce?.cancel()
        aiDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled else { return }
            if Date().timeIntervalSince(self.lastAIRun) > 300 { self.runAIReview(reason: "新的可疑事件") }
        }
    }

    func runAIReview(reason: String) {
        guard model?.settings.aiReview ?? true else { return }
        lastAIRun = Date()
        eventsSinceAI = 0
        let text = recent.suffix(60).filter { $0.category != .aiReview }.map(\.line).joined(separator: "\n")
        guard !text.isEmpty else { return }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            Task { @MainActor in
                do {
                    let v = try await OnDeviceAI.review(text)
                    self.log(.aiReview, .info, "\(reason)：\(v.anomalous ? "發現異常" : "正常")（\(v.severity)）\(v.reason)")
                    if v.anomalous && v.severity >= 2 {
                        // AI 判斷最多到「高」，只通知並詢問，不會自動停機（避免誤判）
                        let sev: Severity = v.severity >= 3 ? .high : .medium
                        self.raise(sev, "AI 判讀：\(v.title)", v.reason, source: "裝置端 AI")
                    }
                } catch {
                    self.log(.aiReview, .info, "AI 判讀失敗：\(error.localizedDescription)")
                }
            }
            return
        }
        #endif
    }

    // MARK: 通知按鈕

    private func registerNotifications() {
        let stop = UNNotificationAction(identifier: NotificationDelegate.lockdownAction, title: "立即停機",
                                        options: [.destructive, .authenticationRequired])
        let ignore = UNNotificationAction(identifier: NotificationDelegate.ignoreAction, title: "先不要", options: [])
        let cat = UNNotificationCategory(identifier: NotificationDelegate.category, actions: [stop, ignore],
                                         intentIdentifiers: [], options: [])
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([cat])
        notificationDelegate.center = self
        center.delegate = notificationDelegate
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct AIVerdict {
    @Guide(description: "是否有攻擊、入侵、竄改或隱私外洩的跡象")
    var anomalous: Bool
    @Guide(description: "嚴重度：0 正常、1 資訊、2 注意、3 高、4 嚴重", .range(0...4))
    var severity: Int
    @Guide(description: "異常的簡短標題（繁體中文，15 字內）；正常時填「正常」")
    var title: String
    @Guide(description: "判斷原因（繁體中文，一到兩句，只根據紀錄內容）")
    var reason: String
}

@available(iOS 26.0, *)
enum OnDeviceAI {
    static let instructions = """
    你是家用攝影機 App 的資安分析助理，只能根據提供的安全紀錄判斷，不要臆測紀錄以外的事。
    要找的跡象：攝影機被替換或冒充、密碼被改、連往外部網路、紀錄被竄改、手機被越獄或附加除錯器、\
    短時間大量斷線（可能是 WiFi 干擾攻擊）、多次解鎖失敗、深夜異常操作、資料被大量匯出。
    正常情況：使用者開關 App、App 進出背景、攝影機偶爾斷線後很快恢復、單次截圖。
    """

    static func review(_ log: String) async throws -> AIVerdict {
        let session = LanguageModelSession(instructions: instructions)
        let r = try await session.respond(to: "以下是最近的安全紀錄，請判斷：\n\(log)", generating: AIVerdict.self)
        return r.content
    }
}
#endif

/// 處理通知上的「立即停機」按鈕（App 在背景也能執行）
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let category = "SECURITY"
    static let lockdownAction = "LOCKDOWN"
    static let ignoreAction = "IGNORE"
    weak var center: SecurityCenter?

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound, .list])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let action = r.actionIdentifier
        let anomalyID = r.notification.request.content.userInfo["anomaly"] as? String
        DispatchQueue.main.async { [weak self] in
            guard let sc = self?.center else { done(); return }
            if action == Self.lockdownAction {
                sc.model?.lockdown(reason: "從通知按下「立即停機」")
            }
            if let anomalyID { sc.markHandled(anomalyID) }
            done()
        }
    }
}
