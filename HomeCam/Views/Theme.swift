import SwiftUI
import UIKit

/// 統一的視覺風格：深色、低彩度、圓角卡片；所有文字用系統字級（跟著 iPhone「文字大小」縮放）
enum Theme {
    static let bg = Color(red: 0.043, green: 0.047, blue: 0.063)          // #0B0C10
    static let card = Color(red: 0.086, green: 0.094, blue: 0.114)        // #16181D
    static let cardRaised = Color(red: 0.122, green: 0.133, blue: 0.161)  // #1F2229
    static let hairline = Color.white.opacity(0.07)
    static let accent = Color(red: 0.36, green: 0.55, blue: 1.0)           // #5B8CFF
    static let live = Color(red: 0.20, green: 0.84, blue: 0.48)
    static let rec = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let motion = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)

    static let radius: CGFloat = 20
    static let radiusSmall: CGFloat = 14
    static let pad: CGFloat = 16
    static let gap: CGFloat = 12

    static func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    /// 讓 UIKit 元件（導覽列、分頁列、清單）也跟著同一套顏色
    static func applyAppearance() {
        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        nav.backgroundColor = UIColor(bg).withAlphaComponent(0.85)
        nav.shadowColor = .clear
        nav.largeTitleTextAttributes = [.font: UIFont.preferredFont(forTextStyle: .largeTitle).bold(),
                                        .foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        tab.backgroundColor = UIColor(bg).withAlphaComponent(0.85)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}

private extension UIFont {
    func bold() -> UIFont {
        guard let d = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: d, size: 0)
    }
}

/// App 內文字大小（在系統設定之上再調整）
enum TextSizeOption: String, Codable, CaseIterable, Identifiable {
    case system, large, xLarge, xxLarge
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "跟隨 iPhone"
        case .large: return "大"
        case .xLarge: return "特大"
        case .xxLarge: return "超大"
        }
    }
    var size: DynamicTypeSize? {
        switch self {
        case .system: return nil
        case .large: return .xLarge
        case .xLarge: return .xxLarge
        case .xxLarge: return .xxxLarge
        }
    }
}

struct AppTextSize: ViewModifier {
    let option: TextSizeOption
    func body(content: Content) -> some View {
        if let s = option.size {
            content.dynamicTypeSize(s)
        } else {
            content.dynamicTypeSize(...DynamicTypeSize.accessibility2)   // 跟隨系統，最大到無障礙 2 級，避免版面爆掉
        }
    }
}

// MARK: - 共用元件

struct CardStyle: ViewModifier {
    var padding: CGFloat = Theme.pad
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = Theme.pad) -> some View { modifier(CardStyle(padding: padding)) }
}

struct CardTitle: View {
    let title: String
    var icon: String? = nil
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).foregroundStyle(Theme.accent).font(.subheadline.weight(.semibold)) }
            Text(title).font(.headline)
            Spacer()
            if let trailing { Text(trailing).font(.footnote).foregroundStyle(Theme.tertiary) }
        }
    }
}

/// 狀態膠囊（REC、移動、離線…）
struct Pill: View {
    let text: String
    var color: Color = .white
    var dot = false
    var filled = false
    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(filled ? Color.white : color).frame(width: 6, height: 6) }
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .foregroundStyle(filled ? Color.white : color)
        .background {
            if filled { Capsule().fill(color) }
            else { Capsule().fill(.ultraThinMaterial).overlay(Capsule().fill(Color.black.opacity(0.25))) }
        }
    }
}

/// 大圓形控制鈕＋下方文字（好按、看得懂）
struct CircleControl: View {
    let icon: String
    let title: String
    var active = false
    var activeColor: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button {
            Theme.haptic()
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .symbolEffect(.pulse, isActive: active && activeColor == Theme.rec)
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(active ? activeColor : Theme.cardRaised))
                    .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                    .foregroundStyle(.white)
                Text(title).font(.footnote).foregroundStyle(active ? .white : Theme.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// 設定列：圖示＋標題＋說明，說明文字用舒適的字級與行距
struct SettingRow<Trailing: View>: View {
    let icon: String
    var tint: Color = Theme.accent
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.footnote).foregroundStyle(Theme.secondary).lineSpacing(2) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 2)
    }
}

extension SettingRow where Trailing == EmptyView {
    init(icon: String, tint: Color = Theme.accent, title: String, detail: String? = nil) {
        self.init(icon: icon, tint: tint, title: title, detail: detail) { EmptyView() }
    }
}

/// 即時時鐘（攝影機畫面左下角）
struct LiveClock: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(Fmt.time.string(from: ctx.date)).font(.caption.monospacedDigit().weight(.medium))
        }
    }
}
