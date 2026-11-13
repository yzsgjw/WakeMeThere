import SwiftUI

// MARK: - Design tokens
//
// 目标平台是 iOS，视觉基准是 Apple HIG（design-taste 类 web skill 的 §13 明确把
// native mobile 划出范围），这里只借用其中可迁移的判断：
//   1. 单一强调色，靠明度分层次，不堆彩虹色
//   2. 数字用等宽/圆体，方便扫读
//   3. 形状系统统一：卡片 22 / 控件 14 / 按钮 18
//   4. 状态要齐：空、加载、权限缺失、错误
//   5. 所有动效都要有一句理由（反馈 / 层级 / 状态迁移）

enum NearNoteStyle {

    // MARK: 颜色（深色为唯一主题，蓝调中性灰，不混暖灰）

    /// 强调色。饱和度压到 77%，避免刺眼电子蓝。
    static let accent = Color(red: 0x3B / 255, green: 0x7D / 255, blue: 0xFF / 255, opacity: 1)

    /// 强调色的深一档，仅用于按钮填充，保证白字对比度
    static let accentDeep = Color(red: 0x2C / 255, green: 0x64 / 255, blue: 0xE8 / 255, opacity: 1)

    static let canvas = Color(red: 0x0A / 255, green: 0x10 / 255, blue: 0x17 / 255, opacity: 1)
    static let surface = Color(red: 0x13 / 255, green: 0x1A / 255, blue: 0x24 / 255, opacity: 1)
    static let raisedSurface = Color(red: 0x1B / 255, green: 0x23 / 255, blue: 0x30 / 255, opacity: 1)
    static let secondarySurface = Color(red: 0x22 / 255, green: 0x2C / 255, blue: 0x3A / 255, opacity: 1)

    static let hairline = Color.white.opacity(0.075)
    static let hairlineStrong = Color.white.opacity(0.14)

    static let textPrimary = Color(red: 0xF4 / 255, green: 0xF7 / 255, blue: 0xFB / 255, opacity: 1)
    static let textSecondary = Color(red: 0x93 / 255, green: 0xA1 / 255, blue: 0xB4 / 255, opacity: 1)
    static let textTertiary = Color(red: 0x64 / 255, green: 0x74 / 255, blue: 0x8B / 255, opacity: 1)

    /// 唯一的"破坏性"色。只用在删除按钮上，不当装饰色用。
    static let danger = Color(red: 0xE8 / 255, green: 0x4C / 255, blue: 0x4C / 255, opacity: 1)

    /// 兼容旧调用点
    static var secondaryText: Color { textSecondary }

    // MARK: 形状（一套半径，写死规则：卡片 22 / 控件 14 / 按钮 18）
    static let cardRadius: CGFloat = 22
    static let controlRadius: CGFloat = 14
    static let buttonRadius: CGFloat = 18

    // MARK: 间距（4 的倍数，纵向节奏靠这里统一）
    static let gutter: CGFloat = 20
    static let sectionGap: CGFloat = 26

    // MARK: 字体
    enum Typeface {
        static func display(_ size: CGFloat) -> Font {
            .system(size: size, weight: .bold, design: .rounded)
        }
        /// 主指标数字（距离 / 时间）
        static let hero = Font.system(size: 62, weight: .bold, design: .rounded)
        static let heroUnit = Font.system(size: 26, weight: .semibold, design: .rounded)
        static let metric = Font.system(size: 21, weight: .semibold, design: .rounded)
        static let metricUnit = Font.system(size: 13, weight: .medium, design: .rounded)
        static let title = Font.system(size: 19, weight: .semibold, design: .rounded)
        static let rowTitle = Font.system(size: 16, weight: .semibold, design: .rounded)
        static let body = Font.system(size: 15, weight: .regular)
        static let label = Font.system(size: 13, weight: .medium)
        static let micro = Font.system(size: 11.5, weight: .semibold, design: .rounded)
        static let cta = Font.system(size: 17, weight: .semibold, design: .rounded)
    }

    // MARK: 分类色
    //
    // 只保留一个色相，靠 SF Symbol 区分类型。原版每个分类一套彩虹色，是
    // 「多强调色」的典型问题，会让整个界面失去重心。
    static func categoryColor(_ category: PlaceCategory?) -> Color {
        accent
    }

    /// 用于站点序号的浅底
    static let accentSoft = accent.opacity(0.16)
    static let accentGhost = accent.opacity(0.09)
}

// MARK: - 背景

struct NearNoteBackground: View {
    var body: some View {
        ZStack {
            NearNoteStyle.canvas
            // 顶部一层极淡的冷光，给深色界面一点体积，不是均匀渐变
            RadialGradient(
                colors: [NearNoteStyle.accent.opacity(0.10), .clear],
                center: UnitPoint(x: 0.82, y: 0.02),
                startRadius: 8,
                endRadius: 420
            )
            // 底部压暗，让固定 CTA 压得住
            LinearGradient(
                colors: [.clear, NearNoteStyle.canvas.opacity(0.9)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - 基础组件

struct PlaceIcon: View {
    let category: PlaceCategory?
    var size: CGFloat = 44

    var body: some View {
        let color = NearNoteStyle.categoryColor(category)
        Image(systemName: category?.symbol ?? "mappin.and.ellipse")
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.opacity(0.92), in: Circle())
            .overlay { Circle().stroke(.white.opacity(0.10), lineWidth: 0.5) }
    }
}

struct SectionHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(NearNoteStyle.Typeface.title)
            .foregroundStyle(NearNoteStyle.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NearNoteCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .background(NearNoteStyle.surface, in: RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous)
                    .stroke(NearNoteStyle.hairline, lineWidth: 0.5)
            }
    }
}

/// 小标签 / 胶囊。刻意不用 pill 满圆，与卡片的 22 拉出层次。
struct MetaTag: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = NearNoteStyle.textSecondary

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            }
            Text(text).font(NearNoteStyle.Typeface.micro)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 按下缩放。所有可点元素都过一遍，避免「点了没反应」。
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

/// 主按钮。高度 56，保证拇指落点；白字在 accentDeep 上对比度达标。
struct PrimaryActionButton: View {
    let title: String
    var symbol: String? = nil
    var role: Role = .primary
    let action: () -> Void

    enum Role { case primary, secondary, destructive }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                }
                Text(title).font(NearNoteStyle.Typeface.cta)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: NearNoteStyle.buttonRadius, style: .continuous))
            .overlay {
                if role != .primary {
                    RoundedRectangle(cornerRadius: NearNoteStyle.buttonRadius, style: .continuous)
                        .stroke(NearNoteStyle.hairlineStrong, lineWidth: 1)
                }
            }
        }
        .buttonStyle(PressableStyle(scale: 0.985))
    }

    private var foreground: Color {
        switch role {
        case .primary: return .white
        case .secondary: return NearNoteStyle.textPrimary
        case .destructive: return NearNoteStyle.textPrimary
        }
    }

    private var background: Color {
        switch role {
        case .primary: return NearNoteStyle.accentDeep
        case .secondary: return NearNoteStyle.raisedSurface
        case .destructive: return NearNoteStyle.raisedSurface
        }
    }
}

/// 指标条：两个数之间用 1px 竖线分隔，不用卡片，避免层层套盒子。
struct MetricStrip: View {
    struct Item {
        let value: String
        let unit: String?
        let caption: String
    }

    let items: [Item]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(NearNoteStyle.hairline)
                        .frame(width: 1, height: 26)
                        .padding(.horizontal, 16)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(item.value)
                            .font(NearNoteStyle.Typeface.metric)
                            .foregroundStyle(NearNoteStyle.textPrimary)
                            .monospacedDigit()
                        if let unit = item.unit {
                            Text(unit)
                                .font(NearNoteStyle.Typeface.metricUnit)
                                .foregroundStyle(NearNoteStyle.textSecondary)
                        }
                    }
                    Text(item.caption)
                        .font(NearNoteStyle.Typeface.label)
                        .foregroundStyle(NearNoteStyle.textTertiary)
                }
                if index < items.count - 1 { Spacer(minLength: 0) }
            }
        }
    }
}

// MARK: - 距离格式化

extension Double {
    var distanceText: String {
        if self < 1_000 { return "\(Int(self.rounded())) m" }
        return String(format: "%.1f km", self / 1_000)
    }

    /// 主指标用的拆分：数值与单位分开排版
    var distanceParts: (value: String, unit: String) {
        if self < 1_000 {
            return ("\(Int(self.rounded()))", "m")
        }
        return (String(format: "%.1f", self / 1_000), "km")
    }
}
