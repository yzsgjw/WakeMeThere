import Foundation

/// 通勤项目的「生效时段」判定。
///
/// 纯函数、无状态 —— 为什么单独抽出来：围栏在后台被唤醒时只有几秒预算，
/// 判定逻辑必须能在毫秒级跑完，而且必须能单元测试（本机没有 Xcode，
/// 只能靠 CI 跑 `xcodebuild test` 验证）。
public enum PlanSchedule {

    /// 星期位：bit0 = 周日 … bit6 = 周六（与 Foundation 的 `weekday` 1…7 对齐）
    public static let weekdayBits: [Int] = (0..<7).map { 1 << $0 }

    /// 周一至周五
    public static let weekdaysMask = 0b0111110
    /// 周六 + 周日
    public static let weekendMask = 0b1000001
    /// 每天
    public static let everyDayMask = 0b1111111

    /// 某一天对应的位（`Calendar.component(.weekday)`：1=周日 … 7=周六）
    public static func bit(for date: Date, calendar: Calendar = .current) -> Int {
        let weekday = calendar.component(.weekday, from: date) // 1...7
        return 1 << (weekday - 1)
    }

    /// 现在是否处于这个项目的生效时段。
    ///
    /// - `weekdayMask == 0` 视为每天（用户一个都不选时，宁可提醒也别静默失效）。
    /// - `start` / `end` 任一为 nil 视为全天。
    /// - `start > end` 视为跨零点（23:00–01:00）。
    /// - 时间窗两端都算命中（闭区间），避免 07:30:00 卡在边界外。
    public static func isActive(
        weekdayMask: Int,
        start: Date?,
        end: Date?,
        at now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let mask = weekdayMask == 0 ? everyDayMask : weekdayMask

        guard let start, let end else {
            return mask & bit(for: now, calendar: calendar) != 0
        }

        let nowMinute = minuteOfDay(now, calendar)
        let startMinute = minuteOfDay(start, calendar)
        let endMinute = minuteOfDay(end, calendar)

        // 起止相同 = 全天
        if startMinute == endMinute {
            return mask & bit(for: now, calendar: calendar) != 0
        }

        if startMinute < endMinute {
            // 普通窗口，例如 07:30–09:00
            guard mask & bit(for: now, calendar: calendar) != 0 else { return false }
            return nowMinute >= startMinute && nowMinute <= endMinute
        }

        // 跨零点窗口，例如 23:00–01:00
        if nowMinute >= startMinute {
            // 窗口的前半段，属于「今天」
            return mask & bit(for: now, calendar: calendar) != 0
        }
        if nowMinute <= endMinute {
            // 窗口的后半段（凌晨），属于「昨天」那一天的项目
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
            return mask & bit(for: yesterday, calendar: calendar) != 0
        }
        return false
    }

    /// 便于 UI 展示的一句话摘要：「工作日 07:30–09:00」
    public static func summary(
        weekdayMask: Int,
        start: Date?,
        end: Date?,
        calendar: Calendar = .current
    ) -> String {
        let days = maskText(weekdayMask)
        guard let start, let end else { return days }

        let startMinute = minuteOfDay(start, calendar)
        let endMinute = minuteOfDay(end, calendar)
        if startMinute == endMinute { return days }

        return "\(days) \(clockText(startMinute))–\(clockText(endMinute))"
    }

    /// 位掩码 → 中文；未命中预设组合时逐日列举
    public static func maskText(_ mask: Int) -> String {
        let m = mask == 0 ? everyDayMask : mask
        switch m {
        case everyDayMask: return "每天"
        case weekdaysMask: return "工作日"
        case weekendMask: return "周末"
        default: break
        }
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let picked = (0..<7).compactMap { m & (1 << $0) != 0 ? names[$0] : nil }
        return picked.joined(separator: "、")
    }

    /// 分钟数 → "07:30"
    public static func clockText(_ minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    static func minuteOfDay(_ date: Date, _ calendar: Calendar) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }
}
