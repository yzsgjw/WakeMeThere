import ActivityKit
import AppIntents
import Foundation

// 这个文件被 **两个 target** 编译：主 App 和 Widget 扩展。
// 为什么必须共享：锁屏卡片上的按钮只能写 `Button(intent:)`，
// 而 intent 类型要在 Widget 侧可见；同时它又要能结束真实的活动，
// 所以用 `LiveActivityIntent`——系统会把 perform() 路由回 App 自己的进程执行。
// 因此这里只许用 ActivityKit / AppIntents / Foundation，禁止出现 SwiftData 类型。

// MARK: - 铃声

/// 内置到 bundle 的三首铃声。文件名就是通知里 `UNNotificationSound` 用的名字。
public enum AlarmChime: String, CaseIterable, Sendable {
    case marimba
    case sonar
    case ouverture
    case radar
    case classic
    case soft
    case bell

    public var label: String {
        switch self {
        case .marimba: return "木琴"
        case .sonar: return "声呐"
        case .ouverture: return "序曲"
        case .radar: return "雷达"
        case .classic: return "标准"
        case .soft: return "轻铃"
        case .bell: return "钟声"
        }
    }

    public var fileName: String {
        switch self {
        case .marimba: return "ChimeMarimba.wav"
        case .sonar: return "ChimeSonar.wav"
        case .ouverture: return "ChimeOuverture.wav"
        case .radar: return "ChimeAlarm.wav"
        case .classic: return "AlarmChime.wav"
        case .soft: return "ChimeSoft.wav"
        case .bell: return "ChimeBell.wav"
        }
    }

    /// 不带扩展名的资源名，`Bundle.url(forResource:withExtension:)` 用
    public var resourceName: String {
        (fileName as NSString).deletingPathExtension
    }

    public var next: AlarmChime {
        let all = AlarmChime.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    /// 当前选中的铃声。键 `alarm.chime` 与 App 侧共用。
    public static var current: AlarmChime {
        let raw = UserDefaults.standard.string(forKey: TripKeys.chime) ?? ""
        return AlarmChime(rawValue: raw) ?? .marimba
    }
}

// MARK: - 共享键与通知

public enum TripKeys {
    public static let isTracking = "trip.isTracking"
    public static let currentIndex = "trip.currentIndex"
    public static let stationIDs = "trip.stationIDs"
    public static let travelMode = "trip.travelMode"
    public static let chime = "alarm.chime"
}

extension Notification.Name {
    /// 锁屏上点了「结束」——App 在前台/后台时据此收拾定位、保活音频、路线缓存
    public static let arrivalTripEnded = Notification.Name("arrival.tripEnded")
}

// MARK: - 锁屏按钮背后的动作

enum TripCommands {

    /// 结束追踪：立刻关掉所有活动卡片，并把持久化的游标复位。
    /// 走 ActivityKit 直接操作，不再绕回单例 —— 这样 Widget 进程里也能跑通。
    static func finish() async {
        for activity in Activity<ReminderActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: TripKeys.isTracking)
        defaults.set(0, forKey: TripKeys.currentIndex)
        NotificationCenter.default.post(name: .arrivalTripEnded, object: nil)
    }

    /// 换铃声：改持久化 + 就地更新正在显示的活动卡片，卡片上的名字立刻变。
    static func cycleChime() async {
        let next = AlarmChime.current.next
        UserDefaults.standard.set(next.rawValue, forKey: TripKeys.chime)

        for activity in Activity<ReminderActivityAttributes>.activities {
            var state = activity.content.state
            state.ringtoneName = next.label
            await activity.update(
                ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60))
            )
        }
        NotificationCenter.default.post(name: .arrivalChimeChanged, object: nil)
    }
}

extension Notification.Name {
    /// 铃声被锁屏按钮换掉了，App 侧据此刷新设置页显示
    public static let arrivalChimeChanged = Notification.Name("arrival.chimeChanged")
    /// 到站了，App 应该把全屏页盖上来。object 为 reminder 的 UUID。
    public static let arrivalOpened = Notification.Name("arrival.opened")
}

// MARK: - Intents

/// 锁屏卡片【结束】。`LiveActivityIntent` = 在 App 进程里执行，
/// 所以它能真的停掉追踪，而不是只改一只卡片。
@available(iOS 17.0, *)
struct EndTripIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "结束追踪"
    static var description: IntentDescription = IntentDescription("结束本次通勤追踪")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await TripCommands.finish()
        return .result()
    }
}

/// 锁屏卡片【铃声】。Live Activity 不支持下拉菜单，只能点一下换下一首。
@available(iOS 17.0, *)
struct CycleChimeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "切换铃声"
    static var description: IntentDescription = IntentDescription("换下一首到站铃声")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await TripCommands.cycleChime()
        return .result()
    }
}
