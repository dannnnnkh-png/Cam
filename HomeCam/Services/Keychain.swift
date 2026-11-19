import Foundation
import Security

/// 攝影機密碼只存在 Keychain：
/// - ThisDeviceOnly：不同步到 iCloud 鑰匙圈、不進備份、換手機不會帶走
/// - AfterFirstUnlock：開機解鎖過一次後，值守模式在鎖屏時仍能重新連線攝影機
enum Keychain {
    private static let service = "HomeCam.camera"

    static func setPassword(_ password: String, for cameraID: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: cameraID,
        ]
        SecItemDelete(base as CFDictionary)
        guard !password.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = kCFBooleanFalse
        SecItemAdd(add as CFDictionary, nil)
    }

    static func password(for cameraID: String) -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: cameraID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    static func delete(cameraID: String) {
        setPassword("", for: cameraID)
    }

    static func deleteAll() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(q as CFDictionary)
    }
}

/// 組合含帳密的網址（只在記憶體中使用，不寫入任何檔案或日誌）
enum URLCredential {
    static func inject(_ url: String, user: String, password: String) -> String {
        guard !user.isEmpty, var comps = URLComponents(string: url), comps.user == nil else { return url }
        comps.percentEncodedUser = encode(user)
        comps.percentEncodedPassword = encode(password)
        return comps.string ?? url
    }

    static func strip(_ url: String) -> (url: String, user: String, password: String) {
        guard var comps = URLComponents(string: url) else { return (url, "", "") }
        let u = comps.user ?? "", p = comps.password ?? ""
        comps.user = nil
        comps.password = nil
        return (comps.string ?? url, u, p)
    }

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
