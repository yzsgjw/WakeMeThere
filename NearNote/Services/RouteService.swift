import CoreLocation
import Foundation
import MapKit

/// 路线规划 + 沿路线进度计算。
///
/// 职责只有三件：
/// 1. 向 `MKDirections` 要一条路线（驾车/公交/步行），10 秒超时；
/// 2. 把路线折线摊平成"累计里程表"，方便后续 O(n) 投影；
/// 3. 把任意坐标投影到折线上，算出**沿道路**已走里程、剩余里程、偏离路线的距离。
///
/// 所有失败都抛出去，调用方（行程页）负责降级回直线距离——
/// 到站告警的最终开关永远是地理围栏，不是这条路。
actor RouteService {

    static let shared = RouteService()

    // MARK: - 数据类型

    /// `CLLocationCoordinate2D` 不是 Sendable，跨 actor 传参会报警告，
    /// 所以用两个 Double 自己包一层。
    struct RoutePoint: Sendable {
        let latitude: Double
        let longitude: Double

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    struct RoutePlan: Sendable {
        let mode: TravelMode
        let points: [RoutePoint]
        /// 每个点距起点的累计里程（米），与 `points` 等长，首元素为 0
        let cumulative: [Double]
        let totalMeters: Double
        /// 苹果给出的预计耗时（含公交候车时间）
        let expectedSeconds: Double
        let createdAt: Date

        var coordinates: [CLLocationCoordinate2D] { points.map(\.coordinate) }

        var totalText: String {
            totalMeters < 1_000
                ? "\(Int(totalMeters.rounded())) 米"
                : String(format: "%.1f 公里", totalMeters / 1_000)
        }
    }

    /// 一次投影的结果
    struct Projection: Sendable {
        /// 沿路线已走（米）
        let traveledMeters: Double
        /// 沿路线还要走（米）
        let remainingMeters: Double
        /// 当前位置到路线的垂直距离（米）——偏航判断看它
        let offRouteMeters: Double

        var progress: Double {
            let total = traveledMeters + remainingMeters
            guard total > 1 else { return 0 }
            return min(1, max(0, traveledMeters / total))
        }
    }

    enum RouteError: LocalizedError {
        case timeout
        case noRoute
        case unavailable

        var errorDescription: String? {
            switch self {
            case .timeout: return "路线请求超时"
            case .noRoute: return "这段路没有可用路线"
            case .unavailable: return "暂时无法规划路线"
            }
        }
    }

    // MARK: - 缓存

    private struct PlanKey: Hashable {
        let fromLat: Double
        let fromLon: Double
        let toLat: Double
        let toLon: Double
        let mode: TravelMode

        /// 起终点做 ~11m 取整：两次点击同一个位置不该触发第二次网络请求
        init(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, mode: TravelMode) {
            func r(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
            fromLat = r(from.latitude)
            fromLon = r(from.longitude)
            toLat = r(to.latitude)
            toLon = r(to.longitude)
            self.mode = mode
        }
    }

    private var cache: [PlanKey: RoutePlan] = [:]
    private let maxCacheEntries = 6

    /// 当前生效的路线。行程页重新打开时直接拿来画线，不必等网络。
    private(set) var currentPlan: RoutePlan?

    // MARK: - 请求路线

    func plan(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        mode: TravelMode,
        timeout: TimeInterval = 10,
        maxAge: TimeInterval = 180
    ) async throws -> RoutePlan {
        let key = PlanKey(from: from, to: to, mode: mode)

        if let hit = cache[key], Date().timeIntervalSince(hit.createdAt) < maxAge {
            currentPlan = hit
            return hit
        }

        let fresh = try await fetch(from: from, to: to, mode: mode, timeout: timeout)
        cache[key] = fresh
        currentPlan = fresh

        if cache.count > maxCacheEntries {
            let oldest = cache.min { $0.value.createdAt < $1.value.createdAt }?.key
            if let oldest { cache[oldest] = nil }
        }
        return fresh
    }

    func clear() {
        cache.removeAll()
        currentPlan = nil
    }

    private func fetch(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        mode: TravelMode,
        timeout: TimeInterval
    ) async throws -> RoutePlan {
        // 只把 Double 带进并发任务里：MKDirections.Request 不是 Sendable
        let fromLat = from.latitude, fromLon = from.longitude
        let toLat = to.latitude, toLon = to.longitude
        let transport = Self.transportType(for: mode)

        let route: MKRoute? = try await withThrowingTaskGroup(of: MKRoute?.self) { group in
            group.addTask {
                let request = MKDirections.Request()
                request.source = MKMapItem(
                    placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: fromLat, longitude: fromLon))
                )
                request.destination = MKMapItem(
                    placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: toLat, longitude: toLon))
                )
                request.transportType = transport
                request.requestsAlternateRoutes = false
                if transport == .transit {
                    request.departureDate = Date()
                }
                do {
                    let response = try await MKDirections(request: request).calculate()
                    return response.routes.first
                } catch {
                    throw RouteError.unavailable
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                throw RouteError.timeout
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let route else { throw RouteError.noRoute }

        let polyline = route.polyline
        let count = polyline.pointCount
        guard count >= 2 else { throw RouteError.noRoute }

        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))

        var points: [RoutePoint] = []
        points.reserveCapacity(count)
        var cumulative: [Double] = []
        cumulative.reserveCapacity(count)
        var running: Double = 0

        for coordinate in coords {
            let point = RoutePoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if let previous = points.last {
                running += Self.straightDistance(previous.coordinate, coordinate)
            }
            points.append(point)
            cumulative.append(running)
        }

        guard running > 0 else { throw RouteError.noRoute }

        return RoutePlan(
            mode: mode,
            points: points,
            cumulative: cumulative,
            totalMeters: running,
            expectedSeconds: route.expectedTravelTime,
            createdAt: Date()
        )
    }

    private static func transportType(for mode: TravelMode) -> MKDirectionsTransportType {
        switch mode {
        case .automobile: return .automobile
        case .transit: return .transit
        case .walking: return .walking
        }
    }

    // MARK: - 投影（纯计算，nonisolated，主线程直接调）

    /// 把当前位置投影到路线上。
    ///
    /// 做法：把每个线段换算成以当前位置为原点的局部平面米制坐标
    /// （纬度方向 111320 m/deg，经度方向乘 cos(纬度)），
    /// 再求原点到每条线段的垂足，取距离最小的那条。
    /// 城市尺度（几公里）内这个近似的误差远小于 GPS 本身的误差。
    nonisolated static func project(
        _ coordinate: CLLocationCoordinate2D,
        on plan: RoutePlan
    ) -> Projection? {
        guard plan.points.count >= 2, plan.cumulative.count == plan.points.count else { return nil }

        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = 111_320.0 * max(0.05, cos(coordinate.latitude * .pi / 180))

        func local(_ point: RoutePoint) -> (x: Double, y: Double) {
            (
                (point.longitude - coordinate.longitude) * metersPerDegreeLon,
                (point.latitude - coordinate.latitude) * metersPerDegreeLat
            )
        }

        var bestOffset = Double.infinity
        var bestSegment = 0
        var bestT = 0.0

        for index in 0..<(plan.points.count - 1) {
            let a = local(plan.points[index])
            let b = local(plan.points[index + 1])
            let abx = b.x - a.x
            let aby = b.y - a.y
            let lengthSquared = abx * abx + aby * aby

            var t = 0.0
            if lengthSquared > 0.0001 {
                // 原点到线段所在直线的垂足参数
                t = -(a.x * abx + a.y * aby) / lengthSquared
                t = min(1, max(0, t))
            }
            let footX = a.x + t * abx
            let footY = a.y + t * aby
            let offset = (footX * footX + footY * footY).squareRoot()

            if offset < bestOffset {
                bestOffset = offset
                bestSegment = index
                bestT = t
            }
        }

        guard bestOffset.isFinite else { return nil }

        let segmentStart = plan.cumulative[bestSegment]
        let segmentEnd = plan.cumulative[bestSegment + 1]
        let traveled = segmentStart + (segmentEnd - segmentStart) * bestT
        let remaining = max(0, plan.totalMeters - traveled)

        return Projection(
            traveledMeters: min(traveled, plan.totalMeters),
            remainingMeters: remaining,
            offRouteMeters: bestOffset
        )
    }

    /// 剩余时间：有速度就按速度算，没速度就按苹果给的全程耗时按比例摊。
    nonisolated static func remainingMinutes(
        plan: RoutePlan,
        projection: Projection,
        currentSpeed metersPerSecond: Double?
    ) -> Int? {
        guard projection.remainingMeters > 1 else { return 0 }

        if let speed = metersPerSecond, speed >= 1.2, speed.isFinite {
            let minutes = projection.remainingMeters / speed / 60
            // 地铁里速度会瞬间飙到很高，超出路线耗时的离谱值直接弃用
            if minutes >= 0.3, minutes <= plan.expectedSeconds / 60 * 3 + 30 {
                return max(1, Int(minutes.rounded()))
            }
        }

        guard plan.expectedSeconds > 0, plan.totalMeters > 1 else { return nil }
        let share = projection.remainingMeters / plan.totalMeters
        let minutes = plan.expectedSeconds * share / 60
        return max(minutes > 0 ? 1 : 0, Int(minutes.rounded()))
    }

    /// 两点直线距离（米）
    nonisolated static func straightDistance(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
