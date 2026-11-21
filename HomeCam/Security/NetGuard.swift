import Foundation

/// 連線白名單：App 只會連到「家中區域網路」的位址，絕不連往網際網路上的主機。
/// App 本身也不開任何對外的連接埠（不接受任何連入）。
enum NetGuard {
    /// 只允許私有 IPv4（10/8、172.16/12、192.168/16、169.254/16）與 IPv6 本地位址（fe80::/10、fc00::/7）
    static func isPrivate(host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let parts = h.split(separator: ".")
        if parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]),
           parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) {
            return a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254)
        }
        if h.contains(":") {
            return h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb")
                || h.hasPrefix("fc") || h.hasPrefix("fd")
        }
        return false     // 網域名稱一律拒絕（可能被 DNS 導向外部）
    }

    static func allows(url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host, !host.isEmpty else { return false }
        return isPrivate(host: host)
    }

    static func allows(_ url: URL) -> Bool { allows(url: url.absoluteString) }
}
