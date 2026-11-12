import ActivityKit
import CoreLocation
import Foundation

/// 灵动岛 / 锁屏"到站追踪"卡片。
///
/// 一个行程只开**一个** Live Activity：换站时只 `update` state，不重建实例
/// （重建会闪一下，且 iOS 有频率限制）。这样第 1 站到站后自动切第 2 站，
/// 灵动岛上就是"站名和距离变了"，视觉是连续的。
@MainActor
final class LiveActivityService: ObservableObject {
    static let shared = LiveActivityService()

    /// 当前正在追踪的站点对应的 reminder id；不在追踪时为 nil
    @Published private(set) var activeReminderID: UUID?
    @Published private(set) var isRunning: Bool = false

    private var activity: Activity<ReminderActivityAttributes>?
    private var currentState: ReminderActivityAttributes.ContentState?
    private var stationIDs: [UUID] = []

    private init() {
        // App 被系统回收后重开：Live Activity 可能还活着，接着用
        if let existing = Activity<ReminderActivityAttributes>.activities.first {
            activity = existing
            stationIDs = existing.attributes.stationIDs
            isRunning = true
            activeReminderID = Self.stationID(in: existing)
        }
    }

    var activitiesAreEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// 灵动岛是否被用户在系统设置里允许（用来在 UI 上给一句解释，而不是静默失败）
    var supportsLiveActivity: Bool { activitiesAreEnabled }

    // MARK: - 行程控制

    func start(stations: [Reminder], destinationName: String) async throws {
        guard let first = stations.first else { return }
        guard activitiesAreEnabled else { throw LiveActivityError.disabled }

        await end()

        stationIDs = stations.map(\.id)
        let attributes = ReminderActivityAttributes(
            destinationName: destinationName,
            stationIDs: stationIDs
        )
        let state = Self.state(for: first, index: 0, total: stations.count)

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60)),
                pushType: nil
            )
            currentState = state
            activeReminderID = first.id
            isRunning = true
        } catch {
            throw LiveActivityError.couldNotStart(error.localizedDescription)
        }
    }

    /// 切换到第 index 站（0 基）。多站接力时由到站事件调用。
    func advance(to index: Int, station: Reminder) async {
        guard let activity else { return }
        guard stationIDs.indices.contains(index) else { return }

        let state = Self.state(for: station, index: index, total: stationIDs.count)
        currentState = state
        activeReminderID = station.id
        await activity.update(
            ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60))
        )
    }

    /// 位置变化时刷新距离。由 LocationService 高频调用，内部做了节流。
    func update(for location: CLLocation) async {
        guard let activity, let state = currentState else { return }

        let next = state.refreshed(for: location)
        // 距离变化不到 3% 且阶段没变就不写，省 iOS 的更新预算
        let delta = abs(next.distanceMeters - state.distanceMeters)
        let phaseChanged = next.phase != state.phase
        let isMeaningful = phaseChanged || delta > max(state.distanceMeters * 0.03, 15)
        guard isMeaningful else { return }

        currentState = next
        await activity.update(
            ActivityContent(state: next, staleDate: Date().addingTimeInterval(30 * 60))
        )
    }

    /// ETA 更新。路径规划回来后调用，让灵动岛上的"分钟数"从估算值变成真实值。
    func setETA(minutes: Int?) async {
        guard let activity, var state = currentState else { return }
        guard state.etaMinutes != minutes else { return }
        state.etaMinutes = minutes
        currentState = state
        await activity.update(
            ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60))
        )
    }

    /// 沿路线进度更新。规划成功后每次定位都可以调，内部照样节流：
    /// 进度变化不到 0.3% 且分钟数没变就不写，省 iOS 的更新预算。
    func updateRoute(
        progress: Double,
        remainingMeters: Double,
        remainingMinutes: Int?,
        mode: TravelMode
    ) async {
        guard let activity, var state = currentState else { return }

        let clamped = min(1, max(0, progress))
        let progressChanged = abs(clamped - (state.routeProgress ?? -1)) >= 0.003
        let minutesChanged = remainingMinutes != nil && state.etaMinutes != remainingMinutes
        let modeChanged = state.travelMode != mode
        guard progressChanged || minutesChanged || modeChanged else { return }

        state.routeProgress = clamped
        state.routeRemainingMeters = max(0, remainingMeters)
        state.travelMode = mode
        if let remainingMinutes { state.etaMinutes = remainingMinutes }
        currentState = state
        await activity.update(
            ActivityContent(state: state, staleDate: Date().addingTimeInterval(10 * 60))
        )
    }

    /// 路线规划失败/清空时调用：灵动岛退回直线距离进度，不留一个卡住的百分比。
    func clearRoute() async {
        guard let activity, var state = currentState else { return }
        guard state.routeProgress != nil || state.routeRemainingMeters != nil else { return }
        state.routeProgress = nil
        state.routeRemainingMeters = nil
        currentState = state
        await activity.update(
            ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60))
        )
    }

    func end() async {
        for running in Activity<ReminderActivityAttributes>.activities {
            await running.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        currentState = nil
        stationIDs = []
        activeReminderID = nil
        isRunning = false
    }

    // MARK: - 兼容单站调用点（HomeView / 卡片按钮）

    /// 单站开关。首页卡片上的"锁屏追踪"按钮仍走这里。
    func toggle(reminder: Reminder, distance: Double) async throws {
        if isRunning, activeReminderID == reminder.id {
            await end()
            return
        }
        try await start(stations: [reminder], destinationName: reminder.title)
    }

    func end(reminderID: UUID) async {
        guard activeReminderID == reminderID else { return }
        await end()
    }

    // MARK: - 私有

    private static func state(
        for reminder: Reminder,
        index: Int,
        total: Int
    ) -> ReminderActivityAttributes.ContentState {
        let distance: Double
        if let location = LocationService.shared.currentLocation {
            distance = location.distance(
                from: CLLocation(latitude: reminder.latitude, longitude: reminder.longitude)
            )
        } else {
            distance = .nan
        }
        let safeDistance = distance.isFinite ? distance : 0
        let eta = Self.heuristicMinutes(meters: safeDistance)

        return ReminderActivityAttributes.ContentState(
            stationName: reminder.title,
            stationIndex: index + 1,
            stationTotal: total,
            stationLatitude: reminder.latitude,
            stationLongitude: reminder.longitude,
            radiusMeters: max(1, reminder.radius),
            distanceMeters: safeDistance,
            startDistanceMeters: max(safeDistance, 1),
            etaMinutes: eta,
            phase: Self.phase(for: safeDistance, radius: reminder.radius),
            travelMode: Self.savedTravelMode()
        )
    }

    /// 行程页把出行方式存在 UserDefaults，这里读一次，灵动岛的图标才跟界面对得上。
    private static func savedTravelMode() -> TravelMode {
        let raw = UserDefaults.standard.string(forKey: "trip.travelMode") ?? ""
        return TravelMode(rawValue: raw) ?? .automobile
    }

    private static func phase(
        for distance: Double,
        radius: Double
    ) -> ReminderActivityAttributes.Phase {
        if distance <= max(radius * 0.35, 60) { return .arrived }
        if distance <= radius { return .close }
        return .tracking
    }

    /// 市区驾车约 28 km/h，直线距离乘 1.35 近似路网绕行。真实 ETA 由
    /// RouteETAService 在 App 前台时覆盖。
    private static func heuristicMinutes(meters: Double) -> Int? {
        guard meters.isFinite, meters > 0 else { return nil }
        let seconds = meters * 1.35 / (28_000 / 3_600)
        return max(1, Int((seconds / 60).rounded()))
    }

    private static func stationID(in activity: Activity<ReminderActivityAttributes>) -> UUID? {
        let index = activity.content.state.stationIndex - 1
        guard activity.attributes.stationIDs.indices.contains(index) else { return nil }
        return activity.attributes.stationIDs[index]
    }
}

enum LiveActivityError: LocalizedError {
    case disabled
    case couldNotStart(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            "灵动岛实时活动被关掉了。去 设置 → 到站提醒 → 实时活动 打开它。"
        case .couldNotStart(let message):
            "锁屏卡片没能启动。\(message)"
        }
    }
}
