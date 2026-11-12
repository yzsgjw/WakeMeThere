import Foundation
import CoreLocation
import OSLog

private let locationLogger = Logger(subsystem: "com.mosaab.NearNote", category: "Location")

@MainActor
public final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    public static let shared = LocationService()
    private let manager = CLLocationManager()
    private var isActive = false
    private var lastGeofenceRefresh: Date?

    @Published public private(set) var authorizationStatus: CLAuthorizationStatus
    @Published public private(set) var currentLocation: CLLocation?

    public var monitoredReminderIds: Set<UUID> { GeofenceManager.shared.monitoredReminderIds }

    private override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.activityType = .other
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    public func requestWhenInUsePermission() { manager.requestWhenInUseAuthorization() }
    public func requestAlwaysPermission() { manager.requestAlwaysAuthorization() }

    public func startInUseTracking() {
        guard !isActive else { return }
        isActive = true
        manager.startUpdatingLocation()
    }

    public func stopInUseTracking() {
        guard isActive else { return }
        isActive = false
        manager.stopUpdatingLocation()
    }

    public func requestCurrentLocation() {
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else { return }
        manager.requestLocation()
    }

    /// 到站复核专用：尽量拿到一个"刚刚测到"的定位。
    /// 围栏事件常常带着上一次缓存的位置到达（可能已经过去几分钟），
    /// 直接据此判定"已到站"就是误报的主要来源。
    public func arrivalFix(timeout: TimeInterval = 5, maxAge: TimeInterval = 6) async -> CLLocation? {
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            return currentLocation
        }
        if let location = currentLocation, Date().timeIntervalSince(location.timestamp) <= maxAge {
            return location
        }
        manager.requestLocation()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let location = currentLocation, Date().timeIntervalSince(location.timestamp) <= maxAge {
                return location
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return currentLocation
    }

    /// 定位质量分档：给界面提示，也给到站复核决定"要不要放宽"
    public enum AccuracyQuality: Equatable {
        case strong, fair, weak, unavailable

        public var label: String {
            switch self {
            case .strong: return "定位好"
            case .fair: return "定位一般"
            case .weak: return "信号弱"
            case .unavailable: return "定位中"
            }
        }

        public var symbol: String {
            switch self {
            case .strong: return "location.fill"
            case .fair: return "location"
            case .weak: return "location.slash"
            case .unavailable: return "location.circle"
            }
        }
    }

    public var accuracyQuality: AccuracyQuality {
        guard let location = currentLocation, location.horizontalAccuracy >= 0 else { return .unavailable }
        switch location.horizontalAccuracy {
        case ..<40: return .strong
        case ..<90: return .fair
        default: return .weak
        }
    }

    public var accuracyText: String {
        guard let location = currentLocation, location.horizontalAccuracy >= 0 else { return "定位中" }
        return "±\(Int(location.horizontalAccuracy.rounded())) m"
    }

    public func updateMonitoredRegions() async {
        await GeofenceManager.shared.refresh(near: currentLocation ?? manager.location)
        objectWillChange.send()
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            LocationService.shared.authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
                manager.requestLocation()
            }
            await LocationService.shared.updateMonitoredRegions()
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            let service = LocationService.shared
            service.currentLocation = location
            await LiveActivityService.shared.update(for: location)
            if service.lastGeofenceRefresh == nil || Date().timeIntervalSince(service.lastGeofenceRefresh!) > 300 {
                service.lastGeofenceRefresh = Date()
                await service.updateMonitoredRegions()
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard (error as? CLError)?.code != .locationUnknown else { return }
        locationLogger.error("Location update failed: \(error.localizedDescription, privacy: .public)")
    }
}
