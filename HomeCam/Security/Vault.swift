import CryptoKit
import Foundation
import Security

/// 裝置綁定的加密保險箱
/// - 金鑰只存在這支 iPhone 的 Keychain（ThisDeviceOnly）：不同步 iCloud、不進備份、換手機或還原到別台都拿不到
/// - 設定、事件、逐字稿、截圖、安全紀錄全部用 AES-256-GCM 加密後才寫入
/// - 錄影檔由 iOS 硬體資料保護加密（金鑰綁在這支手機的晶片上），並且不進備份
enum Vault {
    private static let service = "HomeCam.vault"
    private static let account = "device-key-v1"
    private static var cached: SymmetricKey?
    private static let lock = NSLock()

    /// 取得（或第一次建立）裝置金鑰
    static func key(create: Bool = true) -> SymmetricKey? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, d.count == 32 {
            cached = SymmetricKey(data: d)
            return cached
        }
        guard create else { return nil }
        let k = SymmetricKey(size: .bits256)
        let raw = k.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: raw,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        cached = k
        return k
    }

    static func destroyKey() {
        lock.lock(); defer { lock.unlock() }
        cached = nil
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(q as CFDictionary)
    }

    static func seal(_ data: Data) -> Data? {
        guard let k = key() else { return nil }
        return try? AES.GCM.seal(data, using: k).combined
    }

    static func open(_ data: Data) -> Data? {
        guard let k = key(create: false), let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: k)
    }

    /// 一行文字 → 加密後的 base64（用於逐行追加的紀錄檔）
    static func sealLine(_ s: String) -> String? { seal(Data(s.utf8))?.base64EncodedString() }

    static func openLine<S: StringProtocol>(_ s: S) -> String? {
        guard let d = Data(base64Encoded: String(s)), let p = open(d) else { return nil }
        return String(data: p, encoding: .utf8)
    }

    // MARK: 裝置綁定

    enum BindingResult { case fresh, bound, foreign }

    /// 檢查資料是否屬於這支手機。
    /// fresh：第一次使用（或舊版資料，會自動加密）；bound：正常；foreign：資料不是這台裝置的（被複製或還原到別台）
    static func checkBinding(marker: URL, hasExistingData: Bool) -> BindingResult {
        if let d = try? Data(contentsOf: marker) {
            if let p = open(d), p.count == 16 { return .bound }
            return .foreign
        }
        _ = key()
        var id = Data(count: 16)
        _ = id.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        if let sealed = seal(id) {
            try? sealed.write(to: marker, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        return hasExistingData ? .fresh : .fresh
    }
}
