import Foundation
import CoreLocation
import OSLog

private let geofenceLogger = Logger(subsystem: "com.mosaab.NearNote", category: "Geofence")

@MainActor
public final class GeofenceManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    public static let shared = GeofenceManager()
    private let manager = CLLocationManager()
    private let placeSearch = PlaceSearchService()
    @Published public private(set) var monitoredReminderIds: Set<UUID> = []

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
        let existing = Set(manager.monitoredRegions.map(\.identifier))
        for target in targets where !existing.contains(target.region.identifier) { manager.startMonitoring(for: target.region) }
        monitoredReminderIds = Set(targets.map(\.reminderID))
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
    }

    private func handle(region: CLRegion) async {
        let parsed = parse(region.identifier)
        guard let reminder = ReminderStore.shared.fetchReminder(withId: parsed.id), reminder.isEnabled, !reminder.isCompleted, !reminder.isArchived else { return }
        let settings = SettingsStore.shared
        if let snoozedUntil = reminder.snoozedUntil, snoozedUntil > Date() { return }
        if let last = reminder.lastTriggeredAt, Date().timeIntervalSince(last) < Double(settings.cooldownMinutes * 60) { return }
        
        // Enforce time constraints
        if let start = reminder.startTime, let end = reminder.endTime {
            let calendar = Calendar.current
            let now = Date()
            
            // Extract only the hour and minute from start/end times
            let startComponents = calendar.dateComponents([.hour, .minute], from: start)
            let endComponents = calendar.dateComponents([.hour, .minute], from: end)
            
            let nowComponents = calendar.dateComponents([.hour, .minute], from: now)
            let startMinute = (startComponents.hour ?? 0) * 60 + (startComponents.minute ?? 0)
            let endMinute = (endComponents.hour ?? 0) * 60 + (endComponents.minute ?? 0)
            let nowMinute = (nowComponents.hour ?? 0) * 60 + (nowComponents.minute ?? 0)
            let inWindow = startMinute <= endMinute
                ? (startMinute...endMinute).contains(nowMinute)
                : nowMinute >= startMinute || nowMinute <= endMinute

            if !inWindow {
                geofenceLogger.info("Reminder triggered outside of allowed time window. Suppressing.")
                return
            }
        }
        
        // 到站复核：围栏事件可能带着过期或很粗的定位到达，
        // 直接响就会变成"人在高架上、隔一条街就被提醒"。
        // 这里主动要一次新定位，用「实际距离 + 定位精度半径」判断是否真进圈。
        guard await confirmArrival(of: reminder) else {
            geofenceLogger.info("Arrival suppressed: accuracy check failed.")
            return
        }

        reminder.lastTriggeredAt = Date()
        ReminderStore.shared.save()
        NotificationService.shared.triggerNotification(for: reminder, alternativePlaceName: parsed.placeName,
                                                       alternativeCoordinate: parsed.coordinate)

        // 多站接力：这一站若是行程队列里的当前站，就自动切下一站
        // （终点则整程收尾：关灵动岛、停保活、恢复普通围栏）
        await TripRelayService.shared.relayIfNeeded(arrived: reminder.id)
    }

    /// 只在证据明确不足时否掉到站：宁可多响一次，也不漏站。
    /// 判定式把定位精度本身算进容差，弱信号下自然更宽松。
    private func confirmArrival(of reminder: Reminder) async -> Bool {
        let target = CLLocation(latitude: reminder.latitude, longitude: reminder.longitude)
        guard let fix = await LocationService.shared.arrivalFix() else { return true }
        let age = Date().timeIntervalSince(fix.timestamp)
        if age > 60 { return true }
        if fix.horizontalAccuracy < 0 || fix.horizontalAccuracy > 250 { return true }
        let slack = max(80, reminder.radius * 0.3) + fix.horizontalAccuracy
        let distance = fix.distance(from: target)
        if distance > reminder.radius + slack {
            geofenceLogger.info("Arrival rejected: \(Int(distance))m from station, accuracy \pm\(Int(fix.horizontalAccuracy))m, radius \(Int(reminder.radius))m")
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
