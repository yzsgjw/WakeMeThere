import ActivityKit
import Foundation

// 这个文件被 **两个 target** 编译：主 App 和 Widget 扩展。
// 因此这里只允许依赖 ActivityKit / Foundation —— 绝不能出现 SwiftData 的
// `Reminder` 或 `Place`，否则 Widget 编译不过（Widget 不加载数据模型）。
//
// 设计要点：**站点信息放在 ContentState 而不是 attributes**。
// 多站接力时（阶段 3），下一站会变，但 Live Activity 实例不重建 ——
// 只更新 state，灵动岛/锁屏上的站名、序号、距离、ETA 就跟着变。

public struct ReminderActivityAttributes: ActivityAttributes {

    /// 行程阶段。灵动岛配色和文案都按这个分档，不再另设布尔开关。
    public enum Phase: String, Codable, Hashable, Sendable {
        /// 正常行进
        case tracking
        /// 已进入提醒半径，正在逼近
        case close
        /// 已到站
        case arrived

        public var label: String {
            switch self {
            case .tracking: return "前往中"
            case .close: return "即将到站"
            case .arrived: return "已到站"
            }
        }
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var stationName: String
        /// 从 1 开始
        public var stationIndex: Int
        public var stationTotal: Int

        public var stationLatitude: Double
        public var stationLongitude: Double
        /// 该站的提醒半径（米）
        public var radiusMeters: Double

        /// 当前到该站的直线距离（米）
        public var distanceMeters: Double
        /// 开始追踪 / 切换到该站时的距离，用来画进度
        public var startDistanceMeters: Double

        public var etaMinutes: Int?
        public var phase: Phase

        public init(
            stationName: String,
            stationIndex: Int,
            stationTotal: Int,
            stationLatitude: Double,
            stationLongitude: Double,
            radiusMeters: Double,
            distanceMeters: Double,
            startDistanceMeters: Double,
            etaMinutes: Int?,
            phase: Phase
        ) {
            self.stationName = stationName
            self.stationIndex = stationIndex
            self.stationTotal = stationTotal
            self.stationLatitude = stationLatitude
            self.stationLongitude = stationLongitude
            self.radiusMeters = radiusMeters
            self.distanceMeters = distanceMeters
            self.startDistanceMeters = startDistanceMeters
            self.etaMinutes = etaMinutes
            self.phase = phase
        }

        // MARK: 展示用（计算属性，不参与 Codable）

        /// 数值与单位分开，方便灵动岛里排两档字号
        public var distanceParts: (value: String, unit: String) {
            guard distanceMeters.isFinite, distanceMeters >= 0 else { return ("--", "") }
            if distanceMeters < 1_000 {
                return ("\(Int(distanceMeters.rounded()))", "m")
            }
            return (String(format: "%.1f", distanceMeters / 1_000), "km")
        }

        public var distanceText: String {
            let parts = distanceParts
            return parts.unit.isEmpty ? parts.value : "\(parts.value) \(parts.unit)"
        }

        /// 紧凑区用，去掉空格省宽度
        public var distanceCompact: String {
            let parts = distanceParts
            return parts.unit.isEmpty ? parts.value : "\(parts.value)\(parts.unit)"
        }

        public var etaText: String {
            guard let etaMinutes else { return "—" }
            return "\(etaMinutes) 分钟"
        }

        public var stationProgressText: String {
            "第 \(stationIndex)/\(stationTotal) 站"
        }

        /// 0…1。距离变大（走反方向）时不会画出负进度。
        public var progress: Double {
            guard startDistanceMeters > 1, distanceMeters.isFinite else { return 0 }
            let raw = 1 - distanceMeters / startDistanceMeters
            return min(1, max(0, raw))
        }
    }

    public var tripID: UUID
    /// 终点名，展开态和锁屏卡片上作为上下文
    public var destinationName: String
    /// 本次行程的站点顺序。放进 attributes 是为了 App 被系统回收后重启时，
    /// 仍能靠 ContentState.stationIndex 找回"当前是哪一站"。
    public var stationIDs: [UUID]

    public init(tripID: UUID = UUID(), destinationName: String, stationIDs: [UUID] = []) {
        self.tripID = tripID
        self.destinationName = destinationName
        self.stationIDs = stationIDs
    }
}
