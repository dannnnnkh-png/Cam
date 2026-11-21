import Foundation
import Security

/// 讓攝影機只有這支 iPhone 能登入：
/// 把攝影機密碼換成隨機強密碼，只存在這支手機的 Keychain（不顯示、不備份、不同步）。
/// 換完後原廠 App 或任何知道舊密碼的人都登不進去。
enum CameraHardening {
    /// 16 字元英數混合（多數攝影機上限 16 字元、不接受部分符號）
    static func strongPassword() -> String {
        let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ"), lower = Array("abcdefghijkmnopqrstuvwxyz"), digit = Array("23456789")
        let all = upper + lower + digit
        func pick(_ set: [Character]) -> Character {
            var b: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &b) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
            return set[Int(b % UInt32(set.count))]
        }
        var chars = [pick(upper), pick(lower), pick(digit)] + (0..<13).map { _ in pick(all) }
        for i in stride(from: chars.count - 1, to: 0, by: -1) {
            var b: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &b) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
            chars.swapAt(i, Int(b % UInt32(i + 1)))
        }
        return String(chars)
    }

    enum Outcome { case success, failed(String) }

    /// 換密碼並驗證：ONVIF 與 RTSP 都能用新密碼登入才保存；失敗會自動換回舊密碼
    static func rotatePassword(_ c: CameraConfig) async -> Outcome {
        guard let u = URL(string: c.onvifURL), !c.onvifURL.isEmpty else { return .failed("這台攝影機沒有 ONVIF，無法從 App 改密碼") }
        let old = Keychain.password(for: c.id)
        let client = ONVIFClient(deviceURL: u, username: c.username, password: old, timeout: 6)
        let level: String
        do {
            try await client.connect()
            let list = try await client.users()
            guard let me = list.first(where: { $0.name == c.username }) else { return .failed("攝影機上找不到帳號 \(c.username)") }
            level = me.level
        } catch {
            return .failed("無法讀取攝影機帳號：\(error.localizedDescription)")
        }
        let new = strongPassword()
        do {
            try await client.setPassword(user: c.username, level: level, newPassword: new)
        } catch {
            return .failed("攝影機不允許從 App 改密碼：\(error.localizedDescription)")
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        // 驗證 ONVIF 與 RTSP 都能用新密碼
        let check = ONVIFClient(deviceURL: u, username: c.username, password: new, timeout: 6)
        let onvifOK = (try? await check.connect()) != nil
        let rtsp = await Probe.run(URLCredential.inject(c.streamURL, user: c.username, password: new), timeoutMs: 8000)
        if onvifOK && rtsp.code == HC_OK {
            Keychain.setPassword(new, for: c.id)
            return .success
        }
        // 失敗：換回舊密碼，避免把自己鎖在外面
        try? await check.setPassword(user: c.username, level: level, newPassword: old)
        return .failed("新密碼驗證沒通過（\(onvifOK ? "RTSP" : "ONVIF")），已換回原本的密碼")
    }

    /// 列出攝影機上的所有帳號，找出不是 App 使用的帳號
    static func auditUsers(_ c: CameraConfig) async -> (all: [ONVIFClient.CamUser], others: [ONVIFClient.CamUser])? {
        guard let u = URL(string: c.onvifURL), !c.onvifURL.isEmpty else { return nil }
        let client = ONVIFClient(deviceURL: u, username: c.username, password: Keychain.password(for: c.id), timeout: 6)
        guard (try? await client.connect()) != nil, let list = try? await client.users() else { return nil }
        let others = list.filter { $0.name != c.username && $0.level.lowercased() != "anonymous" }
        return (list, others)
    }
}
