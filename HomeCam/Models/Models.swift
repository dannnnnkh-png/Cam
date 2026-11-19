import Foundation

/// 攝影機設定。密碼不在這裡，存在 Keychain（只限本機、不進 iCloud、不進備份）。
struct CameraConfig: Codable, Identifiable, Hashable {
    enum RecordMode: String, Codable, CaseIterable, Identifiable {
        case off, motion, continuous
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "不錄"
            case .motion: return "有移動才錄"
            case .continuous: return "值守時連續錄"
            }
        }
    }

    enum SDPlayback: String, Codable, CaseIterable, Identifiable {
        case none, hikvision, dahua
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "不支援 / 未設定"
            case .hikvision: return "海康 Hikvision 格式"
            case .dahua: return "大華 / Imou / Amcrest 格式"
            }
        }
    }

    var id: String = UUID().uuidString.prefix(8).lowercased()
    var name: String = "攝影機"
    var host: String = ""
    var username: String = ""
    var mainURL: String = ""          // 不含帳密
    var subURL: String = ""           // 不含帳密；空字串 = 沒有子碼流
    var onvifURL: String = ""
    var profileToken: String = ""
    var ptz: Bool = false
    var brand: String = ""
    var enabled: Bool = true
    var recordMode: RecordMode = .motion
    var recordHighQuality: Bool = true // 手機錄影用主碼流
    var motion: Bool = true
    var motionSensitivity: Int = 50
    var transcribe: Bool = false
    var sdPlayback: SDPlayback = .none

    var liveURL: String { subURL.isEmpty ? mainURL : subURL }
}

struct AppSettings: Codable, Equatable {
    // 隱私與安全
    var appLock: Bool = true
    var lockGraceSeconds: Int = 0
    var hideNotificationContent: Bool = true
    var excludeFromBackup: Bool = true
    var speechOnDeviceOnly: Bool = true
    var blurWhenCaptured: Bool = true
    // 外觀
    var textSize: TextSizeOption = .system
    // 值守
    var guardMode: Bool = false
    var guardKeepScreenOn: Bool = false
    // 錄影
    var segmentMinutes: Int = 10
    var maxStorageGB: Double = 8
    var keepDays: Int = 7
    var motionPostSeconds: Int = 30
    // 通知
    var notifyMotion: Bool = true
    var motionCooldownSeconds: Int = 60
    var notifyKeywords: Bool = true
    var keywords: [String] = ["救命", "小偷", "失火", "help"]
}

struct CameraEvent: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case motion, keyword, offline, online, snapshot, record, system }
    var id: String = UUID().uuidString
    var date: Date = Date()
    var cameraID: String
    var cameraName: String
    var kind: Kind
    var message: String
    var snapshot: String? = nil

    var kindLabel: String {
        switch kind {
        case .motion: return "移動"
        case .keyword: return "關鍵字"
        case .offline: return "離線"
        case .online: return "上線"
        case .snapshot: return "截圖"
        case .record: return "錄影"
        case .system: return "系統"
        }
    }
}

struct TranscriptLine: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var date: Date
    var cameraID: String
    var cameraName: String
    var text: String
}

struct Recording: Identifiable, Hashable {
    var url: URL
    var cameraID: String
    var date: Date
    var size: Int64
    var id: URL { url }
}

enum Fmt {
    static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "zh_TW"); return f
    }()
    static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    static let dateTime: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM/dd HH:mm:ss"; return f
    }()
    static let fileStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static func size(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
