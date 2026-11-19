import Foundation
import Network

struct DiscoveredDevice: Identifiable, Hashable {
    var host: String
    var onvifURL: String = ""
    var name: String = ""
    var model: String = ""
    var rtspPort: Int = 554
    var source: String = ""
    var id: String { host }
}

/// 自動搜尋同 WiFi 的攝影機
/// 1. ONVIF WS-Discovery 多播（需要 Apple 核准的 multicast 權限；沒有就自動略過）
/// 2. 掃描同網段 RTSP / ONVIF 連接埠（只需「區域網路」權限）
enum Discovery {
    private static let queue = DispatchQueue(label: "homecam.scan", attributes: .concurrent)

    static func localIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") { continue }
            if name == "en0" { return ip }                 // WiFi
            if fallback == nil && (name.hasPrefix("en") || name.hasPrefix("bridge")) { fallback = ip }
        }
        return fallback
    }

    static func discover(progress: @escaping (String) -> Void) async -> [DiscoveredDevice] {
        guard let ip = localIPv4() else {
            progress("請先連上家裡的 WiFi")
            return []
        }
        progress("搜尋中（\(ip) 同網段）…")
        async let onvif = wsDiscovery(timeout: 3)
        async let scanned = portScan(localIP: ip)
        let (a, b) = await (onvif, scanned)
        var map: [String: DiscoveredDevice] = [:]
        for d in b { map[d.host] = d }
        for var d in a {
            if let s = map[d.host] { d.rtspPort = s.rtspPort; d.source = "ONVIF + RTSP" }
            map[d.host] = d
        }
        return map.values.sorted { ipKey($0.host) < ipKey($1.host) }
    }

    private static func ipKey(_ ip: String) -> [Int] { ip.split(separator: ".").map { Int($0) ?? 0 } }

    // MARK: 連接埠掃描

    static func isOpen(_ host: String, _ port: UInt16, timeout: TimeInterval = 0.8) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            guard let p = NWEndpoint.Port(rawValue: port) else { cont.resume(returning: false); return }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let lock = NSLock()
            var done = false
            let finish: (Bool) -> Void = { v in
                lock.lock()
                let first = !done
                done = true
                lock.unlock()
                guard first else { return }
                conn.cancel()
                cont.resume(returning: v)
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: finish(true)
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    static func portScan(localIP: String) async -> [DiscoveredDevice] {
        let parts = localIP.split(separator: ".")
        guard parts.count == 4 else { return [] }
        let prefix = parts[0..<3].joined(separator: ".")
        let hosts = (1...254).map { "\(prefix).\($0)" }.filter { $0 != localIP }
        let ports: [UInt16] = [554, 8554, 2020, 8000, 8899, 80]
        let jobs = hosts.flatMap { h in ports.map { (h, $0) } }
        var open: [String: Set<UInt16>] = [:]
        var i = 0
        while i < jobs.count {
            let chunk = Array(jobs[i..<min(i + 96, jobs.count)])
            i += 96
            await withTaskGroup(of: (String, UInt16, Bool).self) { g in
                for (h, p) in chunk { g.addTask { (h, p, await isOpen(h, p)) } }
                for await (h, p, ok) in g where ok { open[h, default: []].insert(p) }
            }
        }
        var out: [DiscoveredDevice] = []
        for (h, ps) in open {
            if let rtsp = [554, 8554].first(where: { ps.contains(UInt16($0)) }) {
                var d = DiscoveredDevice(host: h, rtspPort: rtsp, source: "RTSP:\(rtsp)")
                if let op = [2020, 8000, 8899, 80].first(where: { ps.contains(UInt16($0)) }),
                   await looksLikeONVIF(h, op) {
                    d.onvifURL = "http://\(h):\(op)/onvif/device_service"
                    d.source = "ONVIF + RTSP"
                }
                out.append(d)
            } else if let op = [2020, 8000, 8899].first(where: { ps.contains(UInt16($0)) }), await looksLikeONVIF(h, op) {
                out.append(DiscoveredDevice(host: h, onvifURL: "http://\(h):\(op)/onvif/device_service", source: "ONVIF"))
            }
        }
        return out
    }

    /// 不帶帳密問時間（ONVIF 規定可匿名），能回應就是 ONVIF 裝置
    static func looksLikeONVIF(_ host: String, _ port: Int) async -> Bool {
        guard let u = URL(string: "http://\(host):\(port)/onvif/device_service") else { return false }
        let c = ONVIFClient(deviceURL: u, username: "", password: "", timeout: 2)
        let r = try? await c.call(u, "<GetSystemDateAndTime xmlns=\"\(ONVIFClient.nsDevice)\"/>", auth: false)
        return r?.first("SystemDateAndTime") != nil
    }

    // MARK: WS-Discovery

    static func wsDiscovery(timeout: TimeInterval) async -> [DiscoveredDevice] {
        guard let group = try? NWMulticastGroup(for: [.hostPort(host: "239.255.255.250", port: 3702)]) else { return [] }
        let conn = NWConnectionGroup(with: group, using: .udp)
        let lock = NSLock()
        var found: [String: DiscoveredDevice] = [:]
        conn.setReceiveHandler(maximumMessageSize: 65535, rejectOversizedMessages: true) { message, content, _ in
            guard let content, let text = String(data: content, encoding: .utf8),
                  case let .hostPort(host, _)? = message.remoteEndpoint else { return }
            let ip = "\(host)".components(separatedBy: "%")[0]
            guard var d = parseProbeMatch(text, ip: ip) else { return }
            d.source = "ONVIF"
            lock.lock(); found[ip] = d; lock.unlock()
        }
        conn.stateUpdateHandler = { st in
            if case .ready = st {
                for types in ["<d:Types>dn:NetworkVideoTransmitter</d:Types>", "<d:Types>tds:Device</d:Types>", ""] {
                    conn.send(content: Data(probe(types).utf8)) { _ in }
                }
            }
        }
        conn.start(queue: queue)
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        conn.cancel()
        lock.lock(); defer { lock.unlock() }
        return Array(found.values)
    }

    private static func probe(_ types: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?><e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" \
        xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" \
        xmlns:dn="http://www.onvif.org/ver10/network/wsdl" xmlns:tds="http://www.onvif.org/ver10/device/wsdl">\
        <e:Header><w:MessageID>uuid:\(UUID().uuidString)</w:MessageID>\
        <w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>\
        <w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>\
        </e:Header><e:Body><d:Probe>\(types)</d:Probe></e:Body></e:Envelope>
        """
    }

    static func parseProbeMatch(_ text: String, ip: String) -> DiscoveredDevice? {
        guard let root = XNode.parse(Data(text.utf8)) else { return nil }
        let xaddrs = root.value("XAddrs").split(separator: " ").map(String.init).filter { $0.hasPrefix("http") }
        guard !xaddrs.isEmpty else { return nil }
        let x = xaddrs.first { URL(string: $0)?.host == ip } ?? xaddrs[0]
        var d = DiscoveredDevice(host: ip, onvifURL: x)
        for s in root.value("Scopes").split(separator: " ").map(String.init) {
            if let r = s.range(of: "/name/") {
                d.name = (String(s[r.upperBound...]).removingPercentEncoding ?? "").replacingOccurrences(of: "_", with: " ")
            } else if let r = s.range(of: "/hardware/") {
                d.model = String(s[r.upperBound...]).removingPercentEncoding ?? ""
            }
        }
        return d
    }
}
