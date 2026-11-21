import Darwin
import Foundation
import MachO
import Network
import UIKit

/// 執行環境完整性檢查：越獄、除錯器附加、注入工具、截圖、錄螢幕、網路變化
enum Integrity {
    /// 越獄 / 注入跡象（模擬器不檢查）
    static func jailbreakSignals() -> [String] {
        var out: [String] = []
        #if !targetEnvironment(simulator)
        let paths = ["/Applications/Cydia.app", "/Applications/Sileo.app", "/Library/MobileSubstrate/MobileSubstrate.dylib",
                     "/bin/bash", "/usr/sbin/sshd", "/etc/apt", "/private/var/lib/apt/", "/var/jb", "/usr/bin/ssh"]
        for p in paths where FileManager.default.fileExists(atPath: p) { out.append("可疑檔案：\(p)") }
        let probe = "/private/hc_probe_\(UUID().uuidString)"
        if (try? "x".write(toFile: probe, atomically: true, encoding: .utf8)) != nil {
            out.append("沙盒外可寫入")
            try? FileManager.default.removeItem(atPath: probe)
        }
        let suspicious = ["frida", "substrate", "cycript", "libhooker", "substitute", "ellekit", "sslkillswitch"]
        for i in 0..<_dyld_image_count() {
            guard let c = _dyld_get_image_name(i) else { continue }
            let name = String(cString: c).lowercased()
            if let hit = suspicious.first(where: { name.contains($0) }) { out.append("注入模組：\(hit)") }
        }
        #endif
        return out
    }

    /// 是否有除錯器附加在 App 上（正式版不應該有）
    static var debuggerAttached: Bool {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        let r = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        return r == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
    }
}

/// 監看網路介面變化（例如從家中 WiFi 切到行動網路）
final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private var last = ""
    var onChange: ((String) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            var kind = "無網路"
            if path.status == .satisfied {
                if path.usesInterfaceType(.wifi) { kind = "WiFi" }
                else if path.usesInterfaceType(.cellular) { kind = "行動網路" }
                else if path.usesInterfaceType(.wiredEthernet) { kind = "有線網路" }
                else { kind = "其他網路" }
            }
            if path.usesInterfaceType(.other) && path.status == .satisfied { kind += "（含 VPN）" }
            if kind != self.last {
                let first = self.last.isEmpty
                self.last = kind
                if !first { self.onChange?(kind) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "homecam.netwatch"))
    }
}
