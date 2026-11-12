import Foundation
import CoreLocation
import OSLog

private let relayLog = Logger(subsystem: "com.wayzs999.arrival", category: "TripRelay")

/// 多站自动接力。
///
/// 围栏是 iOS 在后台唤醒 App 的入口，它只知道"某个 reminder 的圆被进了"，
/// 不知道"你在坐车，这是队列里第几站"。这个类补上这层：读行程队列 →
/// 判断到的是不是当前站 → 把游标推到下一站 → 重排围栏 → 更新灵动岛。
///
/// 状态存在 UserDefaults，和 `AlightingTripView` 的 `@AppStorage` 共用同一批键，
/// 所以后台改完、用户再打开 App 时界面已经是新的一站（不需要额外同步）。
@MainActor
final class TripRelayService {
    static let shared = TripRelayService()
    private let defaults = UserDefaults.standard

    enum Key {
        static let isTracking = "trip.isTracking"
        static let stationIDs = "trip.stationIDs"
        static let currentIndex = "trip.currentIndex"
    }

    private init() {}

    // MARK: - 状态读取（与行程页共享）

    var isTracking: Bool { defaults.bool(forKey: Key.isTracking) }

    var currentIndex: Int { max(0, defaults.integer(forKey: Key.currentIndex)) }

    var stationIDs: [UUID] {
        (defaults.string(forKey: Key.stationIDs) ?? "")
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
    }

    /// 已经过站的站点。这些不该再占围栏名额——iOS 只给 20 个，
    /// 坐过的站留在里面就是浪费（而且回程经过还会再响一次）。
    var passedIDs: Set<UUID> {
        guard isTracking else { return [] }
        let ids = stationIDs
        let index = currentIndex
        guard index > 0, !ids.isEmpty else { return [] }
        return Set(ids.prefix(min(index, ids.count)))
    }

    func isPassed(_ id: UUID) -> Bool {
        passedIDs.contains(id)
    }

    // MARK: - 接力

    /// 到站事件进来时调用。
    /// - Returns: 是否真的接力了（不是当前站、没在追踪、或数据缺失都返回 false）
    @discardableResult
    func relayIfNeeded(arrived reminderID: UUID) async -> Bool {
        guard isTracking else { return false }
        let ids = stationIDs
        guard let index = ids.firstIndex(of: reminderID) else { return false }
        // 只有"当前站"才推进队列；已经过去的站或还没轮到的站一律忽略
        guard index == min(currentIndex, ids.count - 1) else { return false }

        let nextIndex = index + 1
        if nextIndex >= ids.count {
            await finish()
            return true
        }

        // 先把游标落盘：哪怕后面灵动岛更新失败，下一站也已经生效
        defaults.set(nextIndex, forKey: Key.currentIndex)

        if let next = ReminderStore.shared.fetchReminder(withId: ids[nextIndex]) {
            relayLog.info("接力到第 \(nextIndex + 1) 站：\(next.title, privacy: .public)")
            // 灵动岛只 update state、不重建卡片，所以站名是平滑替换的
            await LiveActivityService.shared.advance(to: nextIndex, station: next)
        } else {
            relayLog.error("第 \(nextIndex + 1) 站已从库里消失，跳过")
        }

        // 重排围栏：过站的关掉，下一站注册上
        await refreshFences()
        return true
    }

    /// 终点到了。整程收尾：停灵动岛、停保活、恢复普通围栏。
    func finish() async {
        relayLog.info("行程完成，收尾")
        defaults.set(false, forKey: Key.isTracking)
        defaults.set(0, forKey: Key.currentIndex)
        await LiveActivityService.shared.end()
        AudioKeepAliveService.shared.stop()
        await refreshFences()
    }

    private func refreshFences() async {
        await GeofenceManager.shared.refresh(near: LocationService.shared.currentLocation)
    }
}
