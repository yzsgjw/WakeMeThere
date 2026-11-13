import Foundation
import CoreLocation
import UIKit
import OSLog

private let geofenceLogger = Logger(subsystem: "com.mosaab.NearNote", category: "Geofence")

@MainActor
public final class GeofenceManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    public static let shared = GeofenceManager()
    private let manager = CLLocationManager()
    private let placeSearch = PlaceSearchService()
    private var lastInsideCheck: Date?
    private var lastAcceptedFix: CLLocation?
    /// 下一次圈内自检最早什么时候可以跑（自适应：越近越勤，10 秒起步）
    private var nextCheckInterval: TimeInterval = 10
    /// 冷却/已到过这类"被挡下"的提示，60 秒内只记一条，免得 10 秒一次把日志刷满
    private var lastBlockedNoteAt: Date?
    /// 到站时 App 不在前台 → 记下来，等用户解锁/回到前台再补弹全屏页
    @Published public private(set) var pendingArrivalID: UUID?
    @Published public private(set) var monitoredReminderIds: Set<UUID> = []
    /// 系统实际接受的围栏数量（不是我们想注册的数量）。
    /// 界面拿它告诉用户「现在到底有没有在盯着」——注册失败时这里会是 0。
    @Published public private(set) var registeredCount: Int = 0
    /// 最近一次注册失败的原因，直接显示给用户，省得靠猜。
    @Published public private(set) var lastFailure: String?
    /// 最近几次围栏事件的处理结果（注册 / 被时段挡下 / 被精度挡下 / 已响铃）。
    /// 真机上没有控制台，这几行字就是唯一的现场证据。
    @Published public private(set) var recentEvents: [String] = []

    private func note(_ text: String) {
        let stamp = Self.clock.string(from: Date())
        recentEvents.insert("\(stamp) \(text)", at: 0)
        if recentEvents.count > 6 { recentEvents.removeLast(recentEvents.count - 6) }
        DiagnosticsLog.shared.record(text, tag: "围栏")
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .other
    }

    public func refresh(near location: CLLocation?) async {
        // 行程里已经过站的站点不再占用围栏名额：iOS 总共只给 20 个，
        // 坐过的站留在里面既浪费名额，回程再经过还会重复响。
        let active = ReminderStore.shared.fetchActive()
            .filter { !TripRelayService.shared.isPassed($0.id) }
        let sorted = active.sorted { lhs, rhs in
            guard let location else { return lhs.createdAt > rhs.createdAt }
            return location.distance(from: CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)) <
                   location.distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
        }
        var regions: [(region: CLCircularRegion, reminderID: UUID)] = sorted.prefix(20).map { ($0.clRegion, $0.id) }

        if let location {
            for reminder in sorted where reminder.triggerMode == .similarCategory && !reminder.alternativesDisabled {
                guard regions.count < 20, let category = reminder.category else { break }
                let alternatives = await placeSearch.nearby(category: category, near: location.coordinate)
                for place in alternatives.prefix(3) where regions.count < 20 {
                    let original = CLLocation(latitude: reminder.latitude, longitude: reminder.longitude)
                    let candidate = CLLocation(latitude: place.latitude, longitude: place.longitude)
                    guard original.distance(from: candidate) > max(reminder.radius * 1.5, 200) else { continue }
                    let identifier = alternativeIdentifier(reminderID: reminder.id, place: place)
                    let region = CLCircularRegion(center: place.coordinate, radius: reminder.radius, identifier: identifier)
                    region.notifyOnEntry = reminder.triggerOnArrival
                    region.notifyOnExit = !reminder.triggerOnArrival
                    regions.append((region, reminder.id))
                }
            }
        }
        apply(regions)
    }

    public func stop(reminder: Reminder) {
        for region in manager.monitoredRegions where region.identifier == reminder.regionIdentifier || region.identifier.hasPrefix("alt|\(reminder.id.uuidString)|") {
            manager.stopMonitoring(for: region)
        }
        monitoredReminderIds.remove(reminder.id)
    }

    private func apply(_ targets: [(region: CLCircularRegion, reminderID: UUID)]) {
        let identifiers = Set(targets.map(\.region.identifier))
        for region in manager.monitoredRegions where !identifiers.contains(region.identifier) { manager.stopMonitoring(for: region) }

        // 光看 identifier 存在与否是不够的：改了位置或半径之后 identifier 不变，
        // 系统会一直守着**旧的中心点和旧半径**——界面显示新半径，实际却按老圈触发。
        // 所以这里逐项比对中心点 / 半径 / 进出方向，不一致就重新注册。
        var existing: [String: CLCircularRegion] = [:]
        for case let region as CLCircularRegion in manager.monitoredRegions { existing[region.identifier] = region }

        for target in targets {
            let wanted = target.region
            if let current = existing[wanted.identifier], isSameRegion(current, wanted) { continue }
            if existing[wanted.identifier] != nil { manager.stopMonitoring(for: wanted) }
            manager.startMonitoring(for: wanted)
        }
        monitoredReminderIds = Set(targets.map(\.reminderID))
        registeredCount = manager.monitoredRegions.count
        updateAuthorizationHint()
        note("注册完成：系统接受 \(registeredCount) 个围栏")
    }

    private func isSameRegion(_ lhs: CLCircularRegion, _ rhs: CLCircularRegion) -> Bool {
        abs(lhs.radius - rhs.radius) < 1 &&
        abs(lhs.center.latitude - rhs.center.latitude) < 0.00001 &&
        abs(lhs.center.longitude - rhs.center.longitude) < 0.00001 &&
        lhs.notifyOnEntry == rhs.notifyOnEntry &&
        lhs.notifyOnExit == rhs.notifyOnExit
    }

    /// 围栏注册是"静默失败"的：没权限、或只有"使用期间"权限，系统一律不报错也不触发。
    /// 把这件事翻译成一句人话放到界面上，是这个 App 最容易被当成"坏了"的地方。
    private func updateAuthorizationHint() {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            lastFailure = nil
        case .authorizedWhenInUse:
            lastFailure = "定位权限是「使用 App 期间」，App 退到后台后围栏不会唤醒它。需要改成「始终」。"
        case .denied, .restricted:
            lastFailure = "定位权限被拒绝，系统不会注册任何围栏。"
        case .notDetermined:
            lastFailure = "还没给定位权限，系统不会注册任何围栏。"
        @unknown default:
            lastFailure = nil
        }
    }

    private func alternativeIdentifier(reminderID: UUID, place: Place) -> String {
        let safeName = String(place.name.replacingOccurrences(of: "|", with: " ").prefix(40))
        return "alt|\(reminderID.uuidString)|\(place.latitude)|\(place.longitude)|\(safeName)"
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in await GeofenceManager.shared.handle(region: region) }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in await GeofenceManager.shared.handle(region: region) }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        geofenceLogger.error("Region monitoring failed: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in
            // 先同步数量（会用权限状态覆盖 lastFailure），再写下这次的具体失败原因
            GeofenceManager.shared.refreshRegisteredCount()
            GeofenceManager.shared.lastFailure = "围栏注册被系统拒绝：\(error.localizedDescription)"
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        Task { @MainActor in GeofenceManager.shared.refreshRegisteredCount() }
    }

    public func refreshRegisteredCount() {
        registeredCount = manager.monitoredRegions.count
        updateAuthorizationHint()
    }

    private func handle(region: CLRegion) async {
        let parsed = parse(region.identifier)
        guard let reminder = ReminderStore.shared.fetchReminder(withId: parsed.id) else { return }
        guard isEligible(reminder) else { return }

        // 到站复核：围栏事件可能带着过期或很粗的定位到达，
        // 直接响就会变成"人在高架上、隔一条街就被提醒"。
        // 这里主动要一次新定位，用「实际距离 + 定位精度半径」判断是否真进圈。
        guard await confirmArrival(of: reminder) else {
            geofenceLogger.info("Arrival suppressed: accuracy check failed.")
            note("\(reminder.displayTitle) 进了范围，但复核判定还没到，没响")
            return
        }

        await fire(reminder, alternativePlaceName: parsed.placeName, alternativeCoordinate: parsed.coordinate)
    }

    /// 项目本身是否处于「可以响」的状态：开着、没完成、没归档、没被推迟、没在冷却里、在当前生效时段内。
    private func isEligible(_ reminder: Reminder) -> Bool {
        guard reminder.isEnabled, !reminder.isCompleted, !reminder.isArchived else { return false }
        let settings = SettingsStore.shared
        // 冷却与推迟**每个项目各算各的**：A 站响过不该影响 B 站。
        // 但被挡掉时必须留痕，否则就是"点了半天没反应，看不出为什么"。
        if let snoozedUntil = reminder.snoozedUntil, snoozedUntil > Date() {
            let minutes = max(1, Int(snoozedUntil.timeIntervalSinceNow / 60))
            noteBlocked("\(reminder.displayTitle) 已推迟，还要等 \(minutes) 分钟")
            return false
        }
        if reminder.arrivedToday {
            noteBlocked("\(reminder.displayTitle) 今天已经到过，今天不再重复提醒（要再测一次点「重置冷却」）")
            return false
        }
        if let last = reminder.lastTriggeredAt {
            let elapsed = Date().timeIntervalSince(last)
            let window = Double(settings.cooldownMinutes * 60)
            if elapsed < window {
                let left = max(1, Int((window - elapsed) / 60))
                noteBlocked("\(reminder.displayTitle) 还在冷却，剩 \(left) 分钟（可在体检卡里一键清除）")
                return false
            }
        }
        // 生效时段：星期 + 时间窗，纯函数见 PlanSchedule
        // （围栏按设计常挂，所以「现在是不是该响」必须在这里判，而不是靠注册时机）
        guard reminder.isScheduled(at: Date()) else {
            geofenceLogger.info("Reminder outside its schedule (weekday/time window). Suppressing.")
            note("\(reminder.displayTitle) 不在生效时段，跳过")
            return false
        }
        return true
    }

    private func fire(_ reminder: Reminder,
                      alternativePlaceName: String?,
                      alternativeCoordinate: CLLocationCoordinate2D?) async {
        reminder.lastTriggeredAt = Date()
        ReminderStore.shared.save()
        note("\(reminder.displayTitle) 到站，已响铃")
        NotificationService.shared.triggerNotification(for: reminder, alternativePlaceName: alternativePlaceName,
                                                       alternativeCoordinate: alternativeCoordinate)

        // App 正开着 → 立刻盖全屏页；锁屏/后台 → 先记下，
        // 用户解锁（回到前台）那一刻补弹，不然他只听到铃声、找不到界面。
        if reminder.fullScreenOnArrival {
            if UIApplication.shared.applicationState == .active {
                NotificationCenter.default.post(name: .arrivalOpened, object: reminder.id)
            } else {
                pendingArrivalID = reminder.id
                note("到站时 App 不在前台，已记下待办：解锁后补弹全屏页")
            }
        }

        // 多站接力：这一站若是行程队列里的当前站，就自动切下一站
        // （终点则整程收尾：关灵动岛、停保活、恢复普通围栏）
        await TripRelayService.shared.relayIfNeeded(arrived: reminder.id)
    }

    // MARK: - 圈内自检
    //
    // `CLCircularRegion` **只在跨越边界时**回调，它从不检查"你现在是不是已经在圈里"。
    // 于是有两种情况会永远等不到提醒：
    // ① 注册围栏的那一刻你已经站在圈内（刚下车前打开 App、刚创建项目）；
    // ② 系统在低功耗下漏报/迟报了这次穿越。
    // 所以每次刷新围栏、拿到新定位、App 回到前台，都主动算一遍当前距离。
    public func checkInsideFences(force: Bool = false) async {
        let now = Date()
        if !force, let last = lastInsideCheck, now.timeIntervalSince(last) < nextCheckInterval { return }
        lastInsideCheck = now
        guard let fix = await LocationService.shared.arrivalFix(timeout: 3, maxAge: 120) else { return }
        guard fix.horizontalAccuracy >= 0 else { return }
        guard isPlausible(fix) else { return }

        let candidates = ReminderStore.shared.fetchActive().filter { $0.triggerOnArrival }

        // 先只算距离（不做资格判定，避免"冷却中"的提示每 10 秒刷一次日志），
        // 用最近的那个决定下一次多久之后再查。
        var nearestRemaining = Double.greatestFiniteMagnitude
        for reminder in candidates {
            let target = CLLocation(latitude: reminder.latitude, longitude: reminder.longitude)
            let remaining = fix.distance(from: target) - max(100, reminder.radius)
            nearestRemaining = min(nearestRemaining, max(0, remaining))
        }
        let speed = max(0, fix.speed)
        nextCheckInterval = adaptiveInterval(remainingToNearest: nearestRemaining, speed: speed)

        for reminder in candidates where isEligible(reminder) {
            let target = CLLocation(latitude: reminder.latitude, longitude: reminder.longitude)
            let distance = fix.distance(from: target)
            let effectiveRadius = max(100, reminder.radius)
            let slack = max(50, effectiveRadius * 0.25) + fix.horizontalAccuracy
            guard distance <= effectiveRadius + slack else { continue }

            // 精度降级：±500m 以内的"在圈里"根本不足以下结论。
            // 这时候只发一条静默通知（不响铃、不循环），既不误报也不漏光。
            if fix.horizontalAccuracy > 500 {
                note("定位太差（±\(Int(fix.horizontalAccuracy))m），只发静默通知：\(reminder.displayTitle)")
                NotificationService.shared.postSilent(for: reminder)
                break
            }
            if fix.horizontalAccuracy > 250 {
                note("定位偏弱（±\(Int(fix.horizontalAccuracy))m），复核放宽后仍按到站处理")
            }
            note("\(reminder.displayTitle) 当前已在圈内（距 \(Int(distance))m），直接提醒")
            await fire(reminder, alternativePlaceName: nil, alternativeCoordinate: nil)
            break   // 一趟只响最近的那个，避免几个项目连环炸
        }
    }

    /// 自适应巡检节奏。
    ///
    /// 固定 60 秒的问题：在离站还有 4 公里时问一次是好主意，可在离站 80 米时问一次就是在赌运气——
    /// 地铁 80 米只要十几秒。所以这里按「还有多久到」倒推：
    /// 剩余时间越长，间隔增长得越平缓（平方根曲线，不是线性），10 秒起步、60 秒封顶；
    /// 站着不动（候车、堵着）不浪费电，直接退到 60 秒。
    private func adaptiveInterval(remainingToNearest: Double, speed: Double) -> TimeInterval {
        guard speed >= 0.7 else { return 60 }
        let secondsToArrival = remainingToNearest / max(speed, 0.7)
        // 取「还要多久到」的四分之一当巡检间隔：5 秒起步、60 秒封顶。
        // 这条曲线本身就是非线性的——间隔正比于 ETA，而 ETA 随距离的变化在终点前会陡降，
        // 于是等效于「越接近越密集」：地铁 80m 约 5s 一次，剩 1km 约 25s 一次，4km 外 60s 一次。
        return min(60, max(5, (secondsToArrival / 4).rounded()))
    }

    /// 冷却/已到过这类"被挡下"的原因，60 秒内只记一条，否则 10 秒一次的巡检会把日志刷爆。
    private func noteBlocked(_ text: String) {
        let now = Date()
        if let last = lastBlockedNoteAt, now.timeIntervalSince(last) < 60 { return }
        lastBlockedNoteAt = now
        note(text)
    }

    /// 坐标漂移过滤：地铁里 GPS 掉到 Wi-Fi 定位时，坐标会整条街地瞬移。
    /// 两次定位之间换算出的速度超过 60 m/s（216 km/h）就判定为脏点，直接丢弃。
    private func isPlausible(_ fix: CLLocation) -> Bool {
        defer { lastAcceptedFix = fix }
        guard let last = lastAcceptedFix else { return true }
        let dt = fix.timestamp.timeIntervalSince(last.timestamp)
        guard dt > 0.5 else { return true }        // 同一批回调，不做速度判断
        let meters = fix.distance(from: last)
        let implied = meters / dt
        guard implied > 60 else { return true }
        note("丢弃漂移点：\(Int(meters))m / \(String(format: "%.1f", dt))s（≈\(Int(implied * 3.6))km/h）")
        return false
    }

    /// 一键清除冷却与推迟。体检卡上的「重置冷却」用，专门为了"我现在就要测一次"。
    /// 取出「到站时没来得及弹」的全屏页任务（取一次就清空）。
    public func consumePendingArrival() -> UUID? {
        defer { pendingArrivalID = nil }
        return pendingArrivalID
    }

    public func clearCooldowns() {
        for reminder in ReminderStore.shared.fetchAll() {
            reminder.lastTriggeredAt = nil
            reminder.snoozedUntil = nil
        }
        ReminderStore.shared.save()
        note("已清除全部冷却与推迟（测试用）")
        note("现在走进圈内或回到 App 前台就会立刻提醒")
    }

    /// 只在证据明确不足时否掉到站：宁可多响一次，也不漏站。
    /// 判定式把定位精度本身算进容差，弱信号下自然更宽松。
    private func confirmArrival(of reminder: Reminder) async -> Bool {
        let target = CLLocation(latitude: reminder.latitude, longitude: reminder.longitude)
        guard let fix = await LocationService.shared.arrivalFix() else { return true }
        guard isPlausible(fix) else {
            note("复核用的是漂移点，先按未到站处理")
            return false
        }
        let age = Date().timeIntervalSince(fix.timestamp)
        if age > 60 { return true }
        if fix.horizontalAccuracy < 0 || fix.horizontalAccuracy > 250 { return true }
        let slack = max(80, reminder.radius * 0.3) + fix.horizontalAccuracy
        let distance = fix.distance(from: target)
        if distance > reminder.radius + slack {
            geofenceLogger.info("Arrival rejected: \(Int(distance))m from station, accuracy ±\(Int(fix.horizontalAccuracy))m, radius \(Int(reminder.radius))m")
            note("复核否掉：距 \(Int(distance))m，精度 ±\(Int(fix.horizontalAccuracy))m，半径 \(Int(reminder.radius))m")
            return false
        }
        return true
    }

    private func parse(_ identifier: String) -> (id: UUID, placeName: String?, coordinate: CLLocationCoordinate2D?) {
        let parts = identifier.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 5, parts[0] == "alt", let id = UUID(uuidString: parts[1]),
           let lat = Double(parts[2]), let lon = Double(parts[3]) {
            return (id, parts[4], CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        return (UUID(uuidString: identifier) ?? UUID(), nil, nil)
    }
}
