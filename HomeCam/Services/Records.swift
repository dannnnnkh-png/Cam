import Foundation
import LocalAuthentication
import UIKit
import UserNotifications

/// 事件紀錄：每天一個 JSONL 檔
enum EventLog {
    private static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    static func append(_ e: CameraEvent) {
        guard let d = try? enc.encode(e), let line = String(data: d, encoding: .utf8) else { return }
        Storage.appendSealed(line: line, to: Storage.events.appendingPathComponent("\(Fmt.day.string(from: e.date)).jsonl"))
    }

    static func loadRecent(days: Int = 3, limit: Int = 500) -> [CameraEvent] {
        var out: [CameraEvent] = []
        for i in stride(from: days - 1, through: 0, by: -1) {
            let day = Fmt.day.string(from: Date().addingTimeInterval(-Double(i) * 86400))
            let lines = Storage.readSealedLines(Storage.events.appendingPathComponent("\(day).jsonl"))
            out += lines.compactMap { try? dec.decode(CameraEvent.self, from: Data($0.utf8)) }
        }
        return Array(out.suffix(limit))
    }
}

/// 逐字稿：每台攝影機每天一個加密 .jsonl；匯出時才暫時產生明文 .txt
enum TranscriptLog {
    private static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    static func append(_ t: TranscriptLine) {
        let dir = Storage.cameraDir(Storage.transcripts, t.cameraID)
        let day = Fmt.day.string(from: t.date)
        if let d = try? enc.encode(t), let line = String(data: d, encoding: .utf8) {
            Storage.appendSealed(line: line, to: dir.appendingPathComponent("\(day).jsonl"))
        }
    }

    static func days(cameraID: String) -> [String] {
        let dir = Storage.transcripts.appendingPathComponent(cameraID, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".jsonl") }.map { String($0.dropLast(6)) }.sorted(by: >)
    }

    static func lines(cameraID: String, day: String) -> [TranscriptLine] {
        let url = Storage.transcripts.appendingPathComponent(cameraID).appendingPathComponent("\(day).jsonl")
        return Storage.readSealedLines(url).compactMap { try? dec.decode(TranscriptLine.self, from: Data($0.utf8)) }
    }

    static func hasDay(cameraID: String, day: String) -> Bool {
        FileManager.default.fileExists(atPath: Storage.transcripts.appendingPathComponent(cameraID).appendingPathComponent("\(day).jsonl").path)
    }

    /// 你按分享時才產生明文 .txt（暫存，下次啟動自動刪除）
    static func exportText(cameraID: String, day: String) -> URL? {
        let text = lines(cameraID: cameraID, day: day)
            .map { "[\(Fmt.time.string(from: $0.date))] \($0.text)" }.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HomeCam_\(day).txt")
        try? Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func search(_ q: String, cameraIDs: [String]) -> [TranscriptLine] {
        var out: [TranscriptLine] = []
        for id in cameraIDs {
            for day in days(cameraID: id) {
                out += lines(cameraID: id, day: day).filter { $0.text.localizedCaseInsensitiveContains(q) }
                if out.count > 300 { break }
            }
        }
        return out.sorted { $0.date > $1.date }
    }
}

/// 本機通知（不經任何第三方伺服器）。預設隱藏內容：鎖定畫面只顯示「有新事件」
enum Notifier {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// 安全警示：可直接在通知上按「立即停機」
    static func postSecurity(_ a: Anomaly, hideContent: Bool, askLockdown: Bool) {
        let c = UNMutableNotificationContent()
        c.title = "HomeCam 安全警示（\(a.severity.label)）"
        c.body = hideContent ? "偵測到異常，打開 App 查看" : "\(a.title)\(a.camera.isEmpty ? "" : "：\(a.camera)")"
        if askLockdown { c.body += "\n要立即停機嗎？" }
        c.sound = a.severity >= .high ? .defaultCritical : .default
        c.categoryIdentifier = NotificationDelegate.category
        c.userInfo = ["anomaly": a.id]
        c.threadIdentifier = "homecam-security"
        c.interruptionLevel = a.severity >= .high ? .timeSensitive : .active
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: a.id, content: c, trigger: nil))
    }

    static func post(title: String, body: String, image: Data?, hideContent: Bool) {
        let c = UNMutableNotificationContent()
        if hideContent {
            c.title = "HomeCam"
            c.body = "有新的事件，打開 App 查看"
        } else {
            c.title = title
            c.body = body
            if let image {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                if (try? image.write(to: tmp, options: .completeFileProtection)) != nil,
                   let a = try? UNNotificationAttachment(identifier: "snap", url: tmp) {
                    c.attachments = [a]
                }
            }
        }
        c.sound = .default
        c.threadIdentifier = "homecam"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

/// Face ID / 密碼鎖
enum AppLock {
    static func authenticate(reason: String = "解鎖 HomeCam") async -> Bool {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "取消"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }  // 手機未設密碼時無法鎖
        let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        SecurityCenter.shared.log(ok ? .unlockSuccess : .unlockFailure, ok ? .info : .low, reason)
        return ok
    }

    static var deviceHasPasscode: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static var biometryName: String {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch c.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "密碼"
        }
    }
}

/// 密碼強度檢查（新增攝影機與安全檢查用）
enum PasswordCheck {
    static let common: Set<String> = ["", "admin", "12345", "123456", "1234567", "12345678", "123456789", "888888", "666666",
                                      "password", "admin123", "1111", "0000", "000000", "111111", "abc123", "pass", "root"]

    static func problems(_ pwd: String, user: String) -> [String] {
        var p: [String] = []
        if common.contains(pwd.lowercased()) { p.append("密碼是常見的預設密碼，很容易被猜到") }
        else if pwd.count < 8 { p.append("密碼少於 8 個字元") }
        if !pwd.isEmpty && pwd.lowercased() == user.lowercased() { p.append("密碼和帳號相同") }
        return p
    }
}
