import SwiftUI

struct TranscriptsView: View {
    @Environment(AppModel.self) private var model
    @State private var cameraID = ""
    @State private var day = Fmt.day.string(from: Date())
    @State private var query = ""
    @State private var lines: [TranscriptLine] = []
    @State private var days: [String] = []
    @State private var exportURL: IdentifiedURL?

    var body: some View {
        List {
            if model.cameras.isEmpty {
                Text("還沒有攝影機").foregroundStyle(.secondary)
            } else if query.isEmpty {
                Section {
                    Picker("攝影機", selection: $cameraID) { ForEach(model.cameras) { Text($0.name).tag($0.id) } }
                    Picker("日期", selection: $day) { ForEach(days, id: \.self) { Text($0).tag($0) } }
                } footer: {
                    Text("辨識在 iPhone 上進行，聲音與文字都不會上傳。")
                }
                Section {
                    ForEach(shownLines) { l in TranscriptRow(line: l, query: "") }
                    if shownLines.isEmpty {
                        Text("這天沒有逐字稿。在攝影機畫面開啟「即時逐字稿」即可開始記錄。").foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("搜尋「\(query)」") {
                    ForEach(lines) { l in TranscriptRow(line: l, query: query, showDate: true) }
                    if lines.isEmpty { Text("找不到").foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("逐字稿")
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .searchable(text: $query, prompt: "搜尋所有逐字稿")
        .onSubmit(of: .search) { lines = TranscriptLog.search(query, cameraIDs: model.cameras.map(\.id)) }
        .toolbar {
            if !cameraID.isEmpty, TranscriptLog.hasDay(cameraID: cameraID, day: day) {
                Button {
                    // 逐字稿平常加密存放；你按分享時才暫時產生明文檔
                    if let url = TranscriptLog.exportText(cameraID: cameraID, day: day) {
                        SecurityCenter.shared.log(.export, .low, "分享 \(day) 的逐字稿", camera: model.cameras.first { $0.id == cameraID }?.name ?? "")
                        exportURL = IdentifiedURL(url: url)
                    }
                } label: { Image(systemName: "square.and.arrow.up") }
            }
        }
        .sheet(item: $exportURL) { ShareSheet(items: [$0.url]) }
        .onAppear {
            if cameraID.isEmpty || !model.cameras.contains(where: { $0.id == cameraID }) { cameraID = model.cameras.first?.id ?? "" }
            reload()
        }
        .onChange(of: cameraID) { _, _ in reload() }
        .onChange(of: day) { _, _ in reload() }
        .onChange(of: query) { _, q in if q.isEmpty { reload() } }
    }

    /// 今天的逐字稿會即時更新
    private var shownLines: [TranscriptLine] {
        if day == Fmt.day.string(from: Date()) {
            let live = model.liveTranscripts.filter { $0.cameraID == cameraID }
            let ids = Set(lines.map(\.id))
            return (lines + live.filter { !ids.contains($0.id) }).sorted { $0.date > $1.date }
        }
        return lines.sorted { $0.date > $1.date }
    }

    private func reload() {
        guard !cameraID.isEmpty else { return }
        let today = Fmt.day.string(from: Date())
        var d = TranscriptLog.days(cameraID: cameraID)
        if !d.contains(today) { d.insert(today, at: 0) }
        days = d
        if !days.contains(day) { day = today }
        lines = TranscriptLog.lines(cameraID: cameraID, day: day)
    }
}

struct TranscriptRow: View {
    let line: TranscriptLine
    let query: String
    var showDate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(showDate ? "\(Fmt.dateTime.string(from: line.date)) · \(line.cameraName)" : Fmt.time.string(from: line.date))
                .font(.footnote.monospacedDigit()).foregroundStyle(Theme.tertiary)
            Text(highlighted).font(.body).lineSpacing(4)
        }
        .padding(.vertical, 4)
    }

    private var highlighted: AttributedString {
        var a = AttributedString(line.text)
        if !query.isEmpty, let r = a.range(of: query, options: .caseInsensitive) {
            a[r].backgroundColor = Theme.motion.opacity(0.9)
            a[r].foregroundColor = .black
        }
        return a
    }
}

struct EventsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: CameraEvent.Kind?
    @State private var image: IdentifiedImage?

    var body: some View {
        List {
            ForEach(model.events.reversed().filter { filter == nil || $0.kind == filter }.prefix(300)) { e in
                HStack(alignment: .top, spacing: 14) {
                    if let snap = e.snapshot, let data = Storage.readSnapshot(snap), let img = UIImage(data: data) {
                        Image(uiImage: img).resizable().scaledToFill().frame(width: 112, height: 63).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline))
                            .onTapGesture { image = IdentifiedImage(image: img) }
                    } else {
                        Image(systemName: icon(e.kind))
                            .font(.body.weight(.semibold)).foregroundStyle(color(e.kind))
                            .frame(width: 40, height: 40)
                            .background(color(e.kind).opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(e.kindLabel).font(.footnote.weight(.semibold)).foregroundStyle(color(e.kind))
                            Text(e.cameraName).font(.footnote).foregroundStyle(Theme.secondary)
                        }
                        Text(e.message).font(.body).lineSpacing(3)
                        Text(Fmt.dateTime.string(from: e.date)).font(.footnote.monospacedDigit()).foregroundStyle(Theme.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }
            if model.events.isEmpty {
                ContentUnavailableView("目前沒有事件", systemImage: "bell.slash", description: Text("偵測到移動、聽到關鍵字或攝影機離線時會出現在這裡"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("事件")
        .toolbar {
            Menu {
                Button("全部") { filter = nil }
                Button("移動") { filter = .motion }
                Button("關鍵字") { filter = .keyword }
                Button("離線") { filter = .offline }
                Button("截圖") { filter = .snapshot }
                Button("錄影") { filter = .record }
            } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
        }
        .sheet(item: $image) { i in
            Image(uiImage: i.image).resizable().scaledToFit().captureShield().presentationDragIndicator(.visible)
        }
    }

    private func color(_ k: CameraEvent.Kind) -> Color {
        switch k {
        case .motion: return Theme.motion
        case .keyword: return Theme.rec
        case .offline: return Theme.secondary
        case .online: return Theme.live
        default: return Theme.accent
        }
    }

    private func icon(_ k: CameraEvent.Kind) -> String {
        switch k {
        case .motion: return "figure.walk.motion"
        case .keyword: return "exclamationmark.bubble.fill"
        case .offline: return "wifi.slash"
        case .online: return "wifi"
        case .snapshot: return "camera.fill"
        case .record: return "record.circle"
        case .system: return "gearshape.fill"
        }
    }
}

struct IdentifiedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct IdentifiedURL: Identifiable {
    let id = UUID()
    let url: URL
}

/// 系統分享面板（分享完自動刪除暫存的明文檔）
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in
            for case let u as URL in items { try? FileManager.default.removeItem(at: u) }
        }
        return vc
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
