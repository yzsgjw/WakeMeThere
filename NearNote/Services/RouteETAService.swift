import CoreLocation
import Foundation
import MapKit

/// 驾车 ETA。
///
/// 为什么要有这一层：`MKDirections` 需要网络，请求也慢（几百毫秒到几秒）。
/// 界面上的 ETA 不能空着等它，所以先用直线距离估算顶上，真实结果回来再覆盖。
/// 结果缓存 3 分钟，避免每次位置更新都打一次路径规划。
actor RouteETAService {
    static let shared = RouteETAService()

    struct Estimate {
        let minutes: Int
        /// 路线里程（不是直线距离）；退回估算时给的是直线距离
        let meters: Double
        var isRouted: Bool
    }

    private var cache: [String: (minutes: Int, meters: Double, at: Date)] = [:]
    private let cacheLifetime: TimeInterval = 180

    func estimate(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> Estimate {
        let key = cacheKey(origin, destination)
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < cacheLifetime {
            return Estimate(minutes: hit.minutes, meters: hit.meters, isRouted: true)
        }

        let straight = straightLineMeters(origin, destination)

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false

        do {
            let response = try await MKDirections(request: request).calculate()
            if let route = response.routes.first, route.expectedTravelTime > 0 {
                let minutes = max(1, Int((route.expectedTravelTime / 60).rounded()))
                cache[key] = (minutes, route.distance, Date())
                return Estimate(minutes: minutes, meters: route.distance, isRouted: true)
            }
        } catch {
            // 无网络 / 无可达路线：下面退回直线估算，不把错误抛给界面
        }

        return Estimate(minutes: heuristicMinutes(meters: straight), meters: straight, isRouted: false)
    }

    /// 市区驾车约 28 km/h，直线距离乘 1.35 近似路网绕行。
    nonisolated func heuristicMinutes(meters: Double) -> Int {
        guard meters.isFinite, meters > 0 else { return 1 }
        let seconds = meters * 1.35 / (28_000 / 3_600)
        return max(1, Int((seconds / 60).rounded()))
    }

    private func straightLineMeters(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private func cacheKey(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> String {
        String(format: "%.3f,%.3f>%.3f,%.3f", a.latitude, a.longitude, b.latitude, b.longitude)
    }
}
