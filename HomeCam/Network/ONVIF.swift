import CryptoKit
import Foundation

struct ONVIFError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    var isAuth: Bool { message.contains("帳號或密碼") }
}

/// 極簡 XML 樹（只取 local name，忽略命名空間前綴）
final class XNode {
    let name: String
    var attrs: [String: String]
    var text = ""
    var children: [XNode] = []
    init(name: String, attrs: [String: String]) { self.name = name; self.attrs = attrs }

    func all(_ n: String) -> [XNode] {
        var out: [XNode] = []
        for c in children {
            if c.name == n { out.append(c) }
            out.append(contentsOf: c.all(n))
        }
        return out
    }
    func first(_ n: String) -> XNode? {
        for c in children {
            if c.name == n { return c }
            if let f = c.first(n) { return f }
        }
        return nil
    }
    func value(_ n: String) -> String { first(n)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    static func parse(_ data: Data) -> XNode? {
        let d = TreeBuilder()
        let p = XMLParser(data: data)
        p.delegate = d
        return p.parse() ? d.root : nil
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: XNode?
        var stack: [XNode] = []
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let n = XNode(name: local, attrs: attributeDict)
            if let top = stack.last { top.children.append(n) } else { root = n }
            stack.append(n)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }
    }
}

/// 輕量 ONVIF 用戶端：取得串流網址、雲台、預置點
final class ONVIFClient {
    static let nsDevice = "http://www.onvif.org/ver10/device/wsdl"
    static let nsMedia = "http://www.onvif.org/ver10/media/wsdl"
    static let nsPTZ = "http://www.onvif.org/ver20/ptz/wsdl"
    static let nsSchema = "http://www.onvif.org/ver10/schema"
    static let commonPorts = [80, 2020, 8000, 8080, 8899, 5000, 10080, 888]

    let deviceURL: URL
    let username: String
    let password: String
    var mediaURL: URL?
    var ptzURL: URL?
    private var timeOffset: TimeInterval = 0
    private let session: URLSession

    init(deviceURL: URL, username: String, password: String, timeout: TimeInterval = 5) {
        self.deviceURL = deviceURL
        self.username = username
        self.password = password
        let cfg = URLSessionConfiguration.ephemeral          // 不留 cookie / 快取
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        cfg.urlCache = nil
        session = URLSession(configuration: cfg)
    }

    var host: String { deviceURL.host ?? "" }

    // MARK: SOAP

    private func securityHeader() -> String {
        guard !username.isEmpty else { return "" }
        var nonce = Data(count: 16)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let created = f.string(from: Date().addingTimeInterval(timeOffset))
        var material = nonce
        material.append(Data(created.utf8))
        material.append(Data(password.utf8))
        let digest = Data(Insecure.SHA1.hash(data: material)).base64EncodedString()
        return """
        <Security s:mustUnderstand="1" xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">\
        <UsernameToken><Username>\(Self.esc(username))</Username>\
        <Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(digest)</Password>\
        <Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(nonce.base64EncodedString())</Nonce>\
        <Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">\(created)</Created>\
        </UsernameToken></Security>
        """
    }

    @discardableResult
    func call(_ url: URL, _ body: String, auth: Bool = true) async throws -> XNode {
        let env = """
        <?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">\
        <s:Header>\(auth ? securityHeader() : "")</s:Header><s:Body>\(body)</s:Body></s:Envelope>
        """
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(env.utf8)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw ONVIFError(message: "連線失敗") }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let root = XNode.parse(data) else {
            if status == 401 { throw ONVIFError(message: "ONVIF 帳號或密碼錯誤") }
            throw ONVIFError(message: "不是 ONVIF 回應（HTTP \(status)）")
        }
        if let fault = root.first("Fault") {
            let reason = Self.allText(fault)
            if reason.contains("NotAuthorized") || reason.lowercased().contains("not authorized") || status == 401 {
                throw ONVIFError(message: "ONVIF 帳號或密碼錯誤（部分品牌需在 App 另設「攝影機帳號」）")
            }
            throw ONVIFError(message: String(reason.prefix(160)))
        }
        if status == 401 { throw ONVIFError(message: "ONVIF 帳號或密碼錯誤") }
        return root
    }

    private static func allText(_ n: XNode) -> String {
        ([n.text] + n.children.map(allText)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Device

    func syncTime() async {
        guard let root = try? await call(deviceURL, "<GetSystemDateAndTime xmlns=\"\(Self.nsDevice)\"/>", auth: false),
              let utc = root.first("UTCDateTime"), let d = utc.first("Date"), let t = utc.first("Time") else { return }
        var c = DateComponents()
        c.year = Int(d.value("Year")); c.month = Int(d.value("Month")); c.day = Int(d.value("Day"))
        c.hour = Int(t.value("Hour")); c.minute = Int(t.value("Minute")); c.second = Int(t.value("Second"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        if let cam = cal.date(from: c) { timeOffset = cam.timeIntervalSinceNow }
    }

    func connect() async throws {
        await syncTime()
        let root = try await call(deviceURL, "<GetCapabilities xmlns=\"\(Self.nsDevice)\"><Category>All</Category></GetCapabilities>")
        if let m = root.first("Media"), let u = URL(string: m.value("XAddr")) { mediaURL = fixHost(u) }
        if let p = root.first("PTZ"), let u = URL(string: p.value("XAddr")) { ptzURL = fixHost(u) }
        if mediaURL == nil { mediaURL = deviceURL }
    }

    /// 有些攝影機回傳內部 IP，改用實際連線的 IP
    private func fixHost(_ u: URL) -> URL {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u }
        c.host = deviceURL.host
        if c.port == nil { c.port = deviceURL.port }
        return c.url ?? u
    }

    func deviceInfo() async -> (manufacturer: String, model: String) {
        guard let r = try? await call(deviceURL, "<GetDeviceInformation xmlns=\"\(Self.nsDevice)\"/>") else { return ("", "") }
        return (r.value("Manufacturer"), r.value("Model"))
    }

    // MARK: Media

    struct Profile { var token: String; var name: String; var width: Int; var height: Int; var ptz: Bool }

    func profiles() async throws -> [Profile] {
        let root = try await call(mediaURL ?? deviceURL, "<GetProfiles xmlns=\"\(Self.nsMedia)\"/>")
        return root.all("Profiles").map { p in
            let res = p.first("VideoEncoderConfiguration")?.first("Resolution")
            return Profile(token: p.attrs["token"] ?? "", name: p.value("Name"),
                           width: Int(res?.value("Width") ?? "") ?? 0, height: Int(res?.value("Height") ?? "") ?? 0,
                           ptz: p.first("PTZConfiguration") != nil)
        }
    }

    /// 回傳不含帳密的 RTSP 網址
    func streamURI(token: String) async throws -> String {
        let body = """
        <GetStreamUri xmlns="\(Self.nsMedia)"><StreamSetup><Stream xmlns="\(Self.nsSchema)">RTP-Unicast</Stream>\
        <Transport xmlns="\(Self.nsSchema)"><Protocol>RTSP</Protocol></Transport></StreamSetup>\
        <ProfileToken>\(Self.esc(token))</ProfileToken></GetStreamUri>
        """
        let root = try await call(mediaURL ?? deviceURL, body)
        let uri = root.value("Uri")
        guard !uri.isEmpty, var c = URLComponents(string: uri) else { throw ONVIFError(message: "攝影機沒有回傳串流網址") }
        c.host = host
        if c.port == nil { c.port = 554 }
        c.user = nil
        c.password = nil
        return c.string ?? uri
    }

    // MARK: PTZ

    private func ptz() throws -> URL {
        guard let u = ptzURL else { throw ONVIFError(message: "此攝影機不支援雲台") }
        return u
    }

    func move(token: String, x: Double, y: Double, zoom: Double) async throws {
        var vel = ""
        if x != 0 || y != 0 || zoom == 0 {
            vel += "<PanTilt x=\"\(String(format: "%.2f", x))\" y=\"\(String(format: "%.2f", y))\" xmlns=\"\(Self.nsSchema)\"/>"
        }
        if zoom != 0 { vel += "<Zoom x=\"\(String(format: "%.2f", zoom))\" xmlns=\"\(Self.nsSchema)\"/>" }
        try await call(try ptz(), "<ContinuousMove xmlns=\"\(Self.nsPTZ)\"><ProfileToken>\(Self.esc(token))</ProfileToken><Velocity>\(vel)</Velocity></ContinuousMove>")
    }

    func stop(token: String) async throws {
        try await call(try ptz(), "<Stop xmlns=\"\(Self.nsPTZ)\"><ProfileToken>\(Self.esc(token))</ProfileToken><PanTilt>true</PanTilt><Zoom>true</Zoom></Stop>")
    }

    func presets(token: String) async throws -> [(token: String, name: String)] {
        let r = try await call(try ptz(), "<GetPresets xmlns=\"\(Self.nsPTZ)\"><ProfileToken>\(Self.esc(token))</ProfileToken></GetPresets>")
        return r.all("Preset").map { p -> (token: String, name: String) in
            let t = p.attrs["token"] ?? ""
            let n = p.value("Name")
            return (t, n.isEmpty ? t : n)
        }
    }

    func gotoPreset(token: String, preset: String) async throws {
        try await call(try ptz(), "<GotoPreset xmlns=\"\(Self.nsPTZ)\"><ProfileToken>\(Self.esc(token))</ProfileToken><PresetToken>\(Self.esc(preset))</PresetToken></GotoPreset>")
    }

    func setPreset(token: String, name: String) async throws {
        try await call(try ptz(), "<SetPreset xmlns=\"\(Self.nsPTZ)\"><ProfileToken>\(Self.esc(token))</ProfileToken><PresetName>\(Self.esc(name))</PresetName></SetPreset>")
    }

    func gotoHome(token: String) async throws {
        try await call(try ptz(), "<GotoHomePosition xmlns=\"\(Self.nsPTZ)\"><ProfileToken>\(Self.esc(token))</ProfileToken></GotoHomePosition>")
    }
}

// MARK: - 新增攝影機時的自動設定

struct CameraSetupResult {
    var mainURL: String
    var subURL: String
    var onvifURL: String
    var profileToken: String
    var ptz: Bool
    var brand: String
    var sdPlayback: CameraConfig.SDPlayback
}

enum CameraSetup {
    static func viaONVIF(host: String, user: String, password: String, deviceURL: String?) async throws -> CameraSetupResult {
        let candidates: [String] = deviceURL.map { [$0] } ?? ONVIFClient.commonPorts.map { "http://\(host):\($0)/onvif/device_service" }
        var last: Error = ONVIFError(message: "找不到 ONVIF 服務")
        for s in candidates {
            guard let u = URL(string: s) else { continue }
            let c = ONVIFClient(deviceURL: u, username: user, password: password, timeout: 4)
            do {
                try await c.connect()
                var profiles = try await c.profiles()
                guard !profiles.isEmpty else { throw ONVIFError(message: "沒有可用的影像設定檔") }
                profiles.sort { $0.width * $0.height > $1.width * $1.height }
                let main = profiles[0]
                let sub = profiles.count > 1 ? profiles[profiles.count - 1] : nil
                let info = await c.deviceInfo()
                let brand = [info.manufacturer, info.model].filter { !$0.isEmpty }.joined(separator: " ")
                let mainURL = try await c.streamURI(token: main.token)
                var subURL = ""
                if let sub { subURL = (try? await c.streamURI(token: sub.token)) ?? "" }
                let hasPTZ = c.ptzURL != nil && profiles.contains { $0.ptz }
                return CameraSetupResult(mainURL: mainURL, subURL: subURL, onvifURL: s, profileToken: main.token,
                                         ptz: hasPTZ, brand: brand, sdPlayback: guessSD(brand))
            } catch let e as ONVIFError {
                if e.isAuth { throw e }
                last = e
            }
        }
        throw last
    }

    static func guessSD(_ brand: String) -> CameraConfig.SDPlayback {
        let b = brand.lowercased()
        if b.contains("hikvision") || b.contains("hikvsion") { return .hikvision }
        if b.contains("dahua") || b.contains("imou") || b.contains("amcrest") || b.contains("lorex") { return .dahua }
        return .none
    }

    static let rtspPaths: [(String, String, String)] = [
        ("TP-Link Tapo", "/stream1", "/stream2"),
        ("Hikvision", "/Streaming/Channels/101", "/Streaming/Channels/102"),
        ("Dahua / Imou", "/cam/realmonitor?channel=1&subtype=0", "/cam/realmonitor?channel=1&subtype=1"),
        ("Reolink", "/h264Preview_01_main", "/h264Preview_01_sub"),
        ("Reolink H.265", "/h265Preview_01_main", "/h265Preview_01_sub"),
        ("Uniview", "/unicast/c1/s0/live", "/unicast/c1/s1/live"),
        ("Foscam", "/videoMain", "/videoSub"),
        ("Generic", "/live/ch00_0", "/live/ch00_1"),
        ("Generic", "/11", "/12"),
        ("Generic", "/onvif1", "/onvif2"),
        ("Generic", "/live", ""),
        ("Generic", "/h264", ""),
        ("Generic", "/", ""),
    ]

    /// ONVIF 不可用時，逐一嘗試常見品牌的 RTSP 路徑
    static func guessRTSP(host: String, port: Int, user: String, password: String) async throws -> CameraSetupResult {
        var authFailed = false
        for (brand, main, sub) in rtspPaths {
            let mainURL = "rtsp://\(host):\(port)\(main)"
            let r = await Probe.run(URLCredential.inject(mainURL, user: user, password: password), timeoutMs: 5000)
            if r.code == HC_OK {
                var subURL = ""
                if !sub.isEmpty {
                    let s = "rtsp://\(host):\(port)\(sub)"
                    if await Probe.run(URLCredential.inject(s, user: user, password: password), timeoutMs: 5000).code == HC_OK { subURL = s }
                }
                return CameraSetupResult(mainURL: mainURL, subURL: subURL, onvifURL: "", profileToken: "", ptz: false,
                                         brand: brand, sdPlayback: guessSD(brand))
            }
            if r.code == HC_ERR_AUTH { authFailed = true }
            if r.code == HC_ERR_REFUSED { break }
        }
        throw ONVIFError(message: authFailed ? "RTSP 帳號或密碼錯誤" : "找不到可用的 RTSP 路徑，請手動輸入串流網址")
    }
}

/// 呼叫 C 核心測試串流（在背景執行緒）
enum Probe {
    struct Result { var code: Int32; var video: String; var audio: String; var width: Int; var height: Int }

    static func run(_ url: String, timeoutMs: Int32) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var info = HCInfo()
                let code = hc_probe(url, timeoutMs, &info)
                cont.resume(returning: Result(code: code, video: cString(info.video_codec), audio: cString(info.audio_codec),
                                              width: Int(info.width), height: Int(info.height)))
            }
        }
    }

    static func message(_ code: Int32) -> String {
        switch code {
        case HC_ERR_AUTH: return "帳號或密碼錯誤"
        case HC_ERR_NOT_FOUND: return "串流路徑不存在"
        case HC_ERR_TIMEOUT: return "連線逾時"
        case HC_ERR_REFUSED: return "連不到攝影機"
        case HC_ERR_NO_VIDEO: return "沒有影像"
        default: return "無法開啟串流"
        }
    }
}

/// C 字元陣列（Swift 匯入為 tuple）轉 String
func cString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[0..<end], as: UTF8.self)
    }
}
