import CoreLocation
import Foundation

// 只在主 App 里编译：把 SwiftData 的 `Reminder` 转成 Live Activity 需要的
// 纯值类型。Widget 扩展看不到这个文件（它不加载数据模型）。

extension ReminderActivityAttributes.ContentState {

    /// 由某个站点构造状态。`startDistanceMeters` 传当前距离，
    /// 即"这一站从多远开始计进度"。
    static func make(
        station: Reminder,
        index: Int,
        total: Int,
        distance: Double,
        etaMinutes: Int?
    ) -> ReminderActivityAttributes.ContentState {
        let safeDistance = distance.isFinite ? max(0, distance) : 0
        let radius = max(1, station.radius)
        let phase: ReminderActivityAttributes.Phase
        if safeDistance <= max(radius * 0.35, 60) {
            phase = .arrived
        } else if safeDistance <= radius {
            phase = .close
        } else {
            phase = .tracking
        }

        return .init(
            stationName: station.title,
            stationIndex: index,
            stationTotal: total,
            stationLatitude: station.latitude,
            stationLongitude: station.longitude,
            radiusMeters: radius,
            distanceMeters: safeDistance,
            startDistanceMeters: max(safeDistance, 1),
            etaMinutes: etaMinutes,
            phase: phase
        )
    }

    /// 只重算距离相关的字段，保留站名/序号/ETA。
    func refreshed(for location: CLLocation) -> ReminderActivityAttributes.ContentState {
        let target = CLLocation(latitude: stationLatitude, longitude: stationLongitude)
        let meters = max(0, location.distance(from: target))

        var copy = self
        copy.distanceMeters = meters
        if meters <= max(radiusMeters * 0.35, 60) {
            copy.phase = .arrived
        } else if meters <= radiusMeters {
            copy.phase = .close
        } else {
            copy.phase = .tracking
        }
        return copy
    }
}
