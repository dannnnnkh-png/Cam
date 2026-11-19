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
        Storage.append(line: line, to: Storage.events.appendingPathComponent("\(Fmt.day.string(from: e.date)).jsonl"))
    }

    static func loadRecent(days: Int = 3, limit: Int = 500) -> [CameraEvent] {
        var out: [CameraEvent] = []
        for i in stride(from: days - 1, through: 0, by: -1) {
            let day = Fmt.day.string(from: Date().addingTimeInterval(-Double(i) * 86400))
            guard let text = try? String(contentsOf: Storage.events.appendingPathComponent("\(day).jsonl"), encoding: .utf8) else { continue }
            out += text.split(separator: "\n").compactMap { try? dec.decode(CameraEvent.self, from: Data($0.utf8)) }
        }
        return Array(out.suffix(limit))
    }
}

/// 逐字稿：每台攝影機每天一個 .txt（方便閱讀/匯出）＋ .jsonl（搜尋用）
enum TranscriptLog {
    private static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    static func append(_ t: TranscriptLine) {
        let dir = Storage.cameraDir(Storage.transcripts, t.cameraID)
        let day = Fmt.day.string(from: t.date)
        Storage.append(line: "[\(Fmt.time.string(from: t.date))] \(t.text)", to: dir.appendingPathComponent("\(day).txt"))
        if let d = try? enc.encode(t), let line = String(data: d, encoding: .utf8) {
            Storage.append(line: line, to: dir.appendingPathComponent("\(day).jsonl"))
        }
    }

    static func days(cameraID: String) -> [String] {
        let dir = Storage.transcripts.appendingPathComponent(cameraID, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".txt") }.map { String($0.dropLast(4)) }.sorted(by: >)
    }

    static func lines(cameraID: String, day: String) -> [TranscriptLine] {
        let url = Storage.transcripts.appendingPathComponent(cameraID).appendingPathComponent("\(day).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? dec.decode(TranscriptLine.self, from: Data($0.utf8)) }
    }

    static func textFile(cameraID: String, day: String) -> URL {
        Storage.transcripts.appendingPathComponent(cameraID).appendingPathComponent("\(day).txt")
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
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
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
