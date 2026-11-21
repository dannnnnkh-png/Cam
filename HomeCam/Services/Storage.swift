import Foundation

/// 所有資料都在 App 的私有沙盒內（Application Support），其他 App 讀不到，也不開放「檔案」App 存取。
/// 設定、事件、逐字稿、截圖、安全紀錄：用裝置綁定金鑰（Vault）AES-GCM 加密。
/// 錄影：iOS 硬體資料保護。全部強制不進 iCloud / 電腦備份。
enum Storage {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HomeCam", isDirectory: true)
    }()
    static var recordings: URL { root.appendingPathComponent("recordings", isDirectory: true) }
    static var snapshots: URL { root.appendingPathComponent("snapshots", isDirectory: true) }
    static var transcripts: URL { root.appendingPathComponent("transcripts", isDirectory: true) }
    static var events: URL { root.appendingPathComponent("events", isDirectory: true) }
    static var configFile: URL { root.appendingPathComponent("cameras.json") }
    static var settingsFile: URL { root.appendingPathComponent("settings.json") }
    static var security: URL { root.appendingPathComponent("security", isDirectory: true) }
    static var bindingMarker: URL { root.appendingPathComponent("binding.bin") }

    /// 第一次加密前的舊版明文資料可讀一次（之後一律只讀加密資料）
    static var allowPlaintextMigration = false

    @discardableResult
    static func prepare() -> Vault.BindingResult {
        let fm = FileManager.default
        let hadData = fm.fileExists(atPath: configFile.path) || fm.fileExists(atPath: settingsFile.path)
        for d in [root, recordings, snapshots, transcripts, events, security] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        }
        setExcludedFromBackup(true)
        let r = Vault.checkBinding(marker: bindingMarker, hasExistingData: hadData)
        allowPlaintextMigration = (r == .fresh)
        return r
    }

    static func setExcludedFromBackup(_ exclude: Bool) {
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = exclude
        try? url.setResourceValues(values)
    }

    static func cameraDir(_ base: URL, _ cameraID: String) -> URL {
        let d = base.appendingPathComponent(cameraID, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        return d
    }

    static func write(_ data: Data, to url: URL) {
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    /// 加密後逐行追加
    static func appendSealed(line: String, to url: URL) {
        guard let sealed = Vault.sealLine(line) else { return }
        append(line: sealed, to: url)
    }

    /// 讀取加密的逐行檔
    static func readSealedLines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { Vault.openLine($0) }
    }

    static func writeSealed(_ data: Data, to url: URL) {
        if let s = Vault.seal(data) { write(s, to: url) }
    }

    static func readSealed(_ url: URL) -> Data? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        if let p = Vault.open(d) { return p }
        return allowPlaintextMigration ? d : nil
    }

    /// 截圖（加密存放）
    static func readSnapshot(_ name: String) -> Data? { readSealed(snapshots.appendingPathComponent(name)) }

    static func append(line: String, to url: URL) {
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            write(data, to: url)
        }
    }

    // MARK: 設定（缺少的欄位用預設值補上，App 更新後舊設定仍可讀）

    static func load<T: Codable>(_ type: T.Type, from url: URL, default def: T) -> T {
        guard let data = readSealed(url) else { return def }
        return merge(data, default: def) ?? def
    }

    static func merge<T: Codable>(_ data: Data, default def: T) -> T? {
        guard let stored = try? JSONSerialization.jsonObject(with: data),
              let defData = try? JSONEncoder().encode(def),
              let defObj = try? JSONSerialization.jsonObject(with: defData) else { return nil }
        let merged = mergeJSON(defObj, stored)
        guard let out = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(T.self, from: out)
    }

    private static func mergeJSON(_ def: Any, _ stored: Any) -> Any {
        if var d = def as? [String: Any], let s = stored as? [String: Any] {
            for (k, v) in s { d[k] = d[k].map { mergeJSON($0, v) } ?? v }
            return d
        }
        return stored
    }

    static func loadCameras() -> [CameraConfig] {
        guard let data = readSealed(configFile),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return arr.compactMap { item in
            guard let d = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return merge(d, default: CameraConfig())
        }
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(value) { writeSealed(d, to: url) }
    }

    // MARK: 錄影檔

    static func listRecordings(cameraID: String) -> [Recording] {
        let dir = recordings.appendingPathComponent(cameraID, isDirectory: true)
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension == "mov" }.compactMap { url -> Recording? in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let size = Int64(v?.fileSize ?? 0)
            guard size > 2048 else { return nil }
            return Recording(url: url, cameraID: cameraID, date: dateFromName(url) ?? v?.creationDate ?? Date(), size: size)
        }.sorted { $0.date > $1.date }
    }

    static func dateFromName(_ url: URL) -> Date? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.count >= 15 else { return nil }
        return Fmt.fileStamp.date(from: String(stem.suffix(15)))
    }

    static func usage() -> Int64 {
        guard let en = FileManager.default.enumerator(at: recordings, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in en { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    static func freeSpace() -> Int64 {
        let v = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// 超過天數或容量上限時刪最舊的錄影；手機剩不到 2GB 也會自動清
    static func cleanup(settings: AppSettings, busy: Set<String>) {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: recordings, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var files: [(URL, Int64, Date)] = []
        for case let u as URL in en where u.pathExtension == "mov" {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            files.append((u, Int64(v?.fileSize ?? 0), v?.contentModificationDate ?? Date()))
        }
        files.sort { $0.2 < $1.2 }
        let cutoff = Date().addingTimeInterval(-Double(settings.keepDays) * 86400)
        var total = files.reduce(Int64(0)) { $0 + $1.1 }
        let limit = Int64(settings.maxStorageGB * 1_073_741_824)
        var free = freeSpace()
        for (u, size, date) in files where !busy.contains(u.path) {
            if date < cutoff || total > limit || (free > 0 && free < 2_147_483_648) {
                try? fm.removeItem(at: u)
                total -= size
                free += size
            }
        }
        if let snaps = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for s in snaps {
                let d = (try? s.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                if d < cutoff { try? fm.removeItem(at: s) }
            }
        }
    }

    /// 一鍵清除所有資料
    static func wipeAll() {
        try? FileManager.default.removeItem(at: root)
        clearTemp()
        Keychain.deleteAll()
        Vault.destroyKey()
    }

    /// 匯出用的暫存明文檔，每次啟動清掉
    static func clearTemp() {
        let tmp = FileManager.default.temporaryDirectory
        for f in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: f)
        }
    }
}
