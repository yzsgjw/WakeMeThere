import Combine
import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import UIKit

/// 行程页：一屏看清"离下一站还有多远、多久到、什么时候响"。
///
/// 版式逻辑（为什么这么排）：
/// - 眼睛最先找的是**距离**，所以把它做成整屏最大的字，左上对齐，不做居中
/// - ETA / 剩余站数 / 提醒半径是三个同权重的参数，用一条数据带排开，
///   不做三个卡片套三层盒子
/// - 操作只留一个主按钮，固定在拇指区
struct AlightingTripView: View {
    var onAdd: () -> Void = {}

    @EnvironmentObject private var locationService: LocationService
    @Environment(\.modelContext) private var modelContext
    @Query private var reminders: [Reminder]
    @StateObject private var liveActivity = LiveActivityService.shared

    @AppStorage("trip.isTracking") private var isTracking = false
    @AppStorage("trip.stationIDs") private var stationIDsRaw = ""
    @AppStorage("trip.defaultRadius") private var defaultRadius: Double = 500

    @State private var routedETA: Int?
    /// 队列游标：当前是第几站（0 基）。用 AppStorage 而不是 @State ——
    /// 后台接力时 TripRelayService 会改这个键，回到前台界面立刻就是新的一站。
    @AppStorage("trip.currentIndex") private var currentIndex: Int = 0
    @State private var expandedList = false
    @State private var errorMessage: String?

    /// 出行方式：路线规划与灵动岛图标都用它
    @AppStorage("trip.travelMode") private var travelModeRaw = TravelMode.automobile.rawValue
    @State private var routePlan: RouteService.RoutePlan?
    @State private var routeProgress: Double?
    @State private var routeRemaining: Double?
    @State private var routeError: String?
    /// 上一个被采纳的定位，用来丢隧道里的脏点
    @State private var lastRouteFix: CLLocation?
    @State private var lastReplanAt = Date.distantPast

    /// 平滑后的移动速度（m/s）。GPS 瞬时速度抖得厉害，直接用会让 ETA 数字乱跳。
    @State private var smoothedSpeed: Double?
    /// 最近一次"真的挪动了"的时间和位置：静止 5 分钟就判候车
    @State private var lastMovementAt = Date()
    @State private var lastMovementFix: CLLocation?
    @State private var isStationary = false

    private let radiusOptions: [Double] = [200, 300, 500, 1_000, 2_000]

    // MARK: - Body

    var body: some View {
        ZStack {
            NearNoteBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: NearNoteStyle.sectionGap) {
                    topBar
                    hero
                    metrics
                    routeCard
                    radiusControl
                    stopsSection
                    if !hasAlwaysPermission { permissionCard }
                }
                .padding(.horizontal, NearNoteStyle.gutter)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { ctaBar }
        .task(id: nextStop?.id) { await etaLoop() }
        .task(id: routeTaskKey) { await planRoute() }
        .onReceive(locationService.$currentLocation) { location in
            handleLocation(location)
        }
        .onReceive(NotificationCenter.default.publisher(for: .arrivalTripEnded)) { _ in
            handleExternalEnd()
        }
        .alert("提示", isPresented: errorAlertBinding) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 顶部状态

    private var topBar: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("到站提醒")
                    .font(NearNoteStyle.Typeface.label)
                    .foregroundStyle(NearNoteStyle.textTertiary)
                Text(isTracking ? "正在追踪" : "准备出发")
                    .font(NearNoteStyle.Typeface.title)
                    .foregroundStyle(NearNoteStyle.textPrimary)
            }
            Spacer()
            if isTracking { signalPill }
            statusPill
        }
        .overlay(alignment: .bottomLeading) {
            if isTracking, locationService.accuracyQuality == .weak, let nextStop {
                Text("信号弱，\(nextStop.placeName) 的到站提醒可能会晚一点点。")
                    .font(NearNoteStyle.Typeface.micro)
                    .foregroundStyle(NearNoteStyle.textTertiary)
                    .offset(y: 20)
            }
        }
    }

    /// 定位质量：围栏判定靠的是定位精度，
    /// 用户至少能看见"现在这套判断值不值得信"。
    private var signalPill: some View {
        let quality = locationService.accuracyQuality
        return HStack(spacing: 5) {
            Image(systemName: quality.symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(quality == .weak ? "\(quality.label) \(locationService.accuracyText)" : locationService.accuracyText)
                .font(NearNoteStyle.Typeface.micro)
        }
        .foregroundStyle(quality == .weak ? NearNoteStyle.textTertiary : NearNoteStyle.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(NearNoteStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isTracking ? NearNoteStyle.accent : NearNoteStyle.textTertiary)
                .frame(width: 6, height: 6)
            Text(isTracking ? (isStationary ? "候车中" : "追踪中") : "未开始")
                .font(NearNoteStyle.Typeface.micro)
                .foregroundStyle(isTracking ? NearNoteStyle.accent : NearNoteStyle.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            (isTracking ? NearNoteStyle.accentSoft : NearNoteStyle.raisedSurface),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    // MARK: - 主指标

    private var hero: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(nextStop == nil ? "还没有站点" : "距离下一站")
                    .font(NearNoteStyle.Typeface.label)
                    .foregroundStyle(NearNoteStyle.textSecondary)
                Spacer(minLength: 6)
                if let stop = nextStop {
                    Text(stop.title)
                        .font(NearNoteStyle.Typeface.label)
                        .foregroundStyle(NearNoteStyle.accent)
                        .lineLimit(1)
                }
            }

            distanceHeadline
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: heroDistanceParts.value)

            Text(heroCaption)
                .font(NearNoteStyle.Typeface.label)
                .foregroundStyle(NearNoteStyle.textTertiary)
        }
    }

    private var distanceHeadline: some View {
        let parts = heroDistanceParts
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(parts.value)
                .font(NearNoteStyle.Typeface.hero)
                .monospacedDigit()
                .foregroundStyle(NearNoteStyle.textPrimary)
                .contentTransition(.numericText())
            if !parts.unit.isEmpty {
                Text(parts.unit)
                    .font(NearNoteStyle.Typeface.heroUnit)
                    .foregroundStyle(NearNoteStyle.textSecondary)
            }
        }
    }

    private var heroDistanceParts: (value: String, unit: String) {
        guard let stop = nextStop else { return ("--", "") }
        let meters = distance(to: stop)
        guard meters.isFinite, meters < 1_000_000 else { return ("--", "") }
        return meters.distanceParts
    }

    private var heroCaption: String {
        guard let stop = nextStop else {
            return "添加第一个站点后，到站时手机会提醒你。"
        }
        let progress = "第 \(queueIndex + 1) / \(orderedStations.count) 站"
        return "提醒半径 \(stop.radius.distanceText) · \(progress)"
    }

    // MARK: - 参数带

    private var metrics: some View {
        MetricStrip(items: [
            .init(value: etaValue, unit: etaValue == "—" ? nil : "分钟", caption: "预计"),
            .init(value: "\(remainingStopCount)", unit: "站", caption: "剩余"),
            .init(value: radiusShortLabel, unit: nil, caption: "提醒半径"),
        ])
    }

    private var etaValue: String {
        // 候车中冻结：数字不再变，靠 statusPill 的「候车中」说明原因
        if let routedETA { return "\(routedETA)" }
        guard let stop = nextStop else { return "—" }
        let meters = distance(to: stop)
        guard meters.isFinite, meters < 1_000_000 else { return "—" }
        return "\(RouteETAService.shared.heuristicMinutes(meters: meters))"
    }

    private var radiusShortLabel: String {
        let radius = nextStop?.radius ?? defaultRadius
        return radius.distanceText
    }

    // MARK: - 路线卡片（MapKit 原生路线 + 沿路进度）

    private var travelMode: TravelMode {
        TravelMode(rawValue: travelModeRaw) ?? .automobile
    }

    /// 下一站 / 出行方式 / 是否追踪 变了才重新规划，避免每次定位都打网络
    private var routeTaskKey: String {
        "\(nextStop?.id.uuidString ?? "-")|\(travelModeRaw)|\(isTracking)"
    }

    private var routeProgressClamped: Double {
        min(1, max(0, routeProgress ?? 0))
    }

    private var routeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("路线")
                    .font(NearNoteStyle.Typeface.title)
                    .foregroundStyle(NearNoteStyle.textPrimary)
                Spacer(minLength: 8)
                Menu {
                    ForEach(TravelMode.allCases, id: \.self) { mode in
                        Button {
                            travelModeRaw = mode.rawValue
                        } label: {
                            Label(mode.label, systemImage: mode.symbol)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: travelMode.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(travelMode.label)
                            .font(NearNoteStyle.Typeface.label)
                    }
                    .foregroundStyle(NearNoteStyle.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(NearNoteStyle.accentGhost))
                }
            }

            if let plan = routePlan {
                routeMap(plan)
                routeProgressRow(plan)
            } else {
                routePlaceholder
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous)
                .fill(NearNoteStyle.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous)
                .stroke(NearNoteStyle.hairline, lineWidth: 1)
        )
    }

    private func routeMap(_ plan: RouteService.RoutePlan) -> some View {
        Map(initialPosition: .region(region(for: plan)), interactionModes: []) {
            MapPolyline(coordinates: plan.coordinates)
                .stroke(
                    NearNoteStyle.accent,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                )

            if let first = plan.points.first {
                Annotation("", coordinate: first.coordinate, anchor: .center) {
                    Circle()
                        .fill(NearNoteStyle.surface)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(NearNoteStyle.accent, lineWidth: 2.5))
                }
            }

            if let last = plan.points.last {
                Annotation("", coordinate: last.coordinate, anchor: .bottom) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(NearNoteStyle.accent)
                        .background(Circle().fill(NearNoteStyle.canvas).frame(width: 14, height: 14))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .frame(height: 168)
        .clipShape(RoundedRectangle(cornerRadius: NearNoteStyle.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NearNoteStyle.controlRadius, style: .continuous)
                .stroke(NearNoteStyle.hairline, lineWidth: 1)
        )
    }

    private func routeProgressRow(_ plan: RouteService.RoutePlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(routeRemaining.map { $0.distanceText } ?? plan.totalText)
                    .font(NearNoteStyle.Typeface.label)
                    .foregroundStyle(NearNoteStyle.textSecondary)
                Spacer()
                Text("\(Int((routeProgressClamped * 100).rounded()))%")
                    .font(NearNoteStyle.Typeface.label.monospacedDigit())
                    .foregroundStyle(NearNoteStyle.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(NearNoteStyle.hairlineStrong)
                    Capsule()
                        .fill(NearNoteStyle.accent)
                        .frame(width: max(0, geo.size.width * routeProgressClamped))
                }
            }
            .frame(height: 4)
        }
    }

    private var routePlaceholder: some View {
        HStack(spacing: 10) {
            Image(systemName: routeError == nil
                  ? "point.topleft.down.curvedto.point.bottomright.up"
                  : "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(routeError == nil ? NearNoteStyle.textTertiary : NearNoteStyle.accent)
            Text(routeError ?? (isTracking ? "正在规划路线…" : "开始追踪后自动规划路线，进度按道路计算"))
                .font(NearNoteStyle.Typeface.label)
                .foregroundStyle(NearNoteStyle.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func region(for plan: RouteService.RoutePlan) -> MKCoordinateRegion {
        let lats = plan.points.map(\.latitude)
        let lons = plan.points.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.004, (maxLat - minLat) * 1.8),
            longitudeDelta: max(0.004, (maxLon - minLon) * 1.8)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    /// 每次拿到新定位：投影到路线 → 进度/剩余/ETA → 推给灵动岛；偏航就重规划。
    private func handleLocation(_ location: CLLocation?) {
        guard isTracking, let location, let plan = routePlan else { return }
        // 精度太差的点不参与进度计算
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy < 120 else { return }
        // 隧道里定位会瞬间跳到几百米外：单次突变 >150m 且间隔很短 → 视为脏点丢弃
        if let last = lastRouteFix,
           location.distance(from: last) > 150,
           location.timestamp.timeIntervalSince(last.timestamp) < 5 {
            return
        }
        lastRouteFix = location

        // ---- 速度平滑：指数滑动平均，只吃最近几个点的七成权重 ----
        if location.speed >= 0 {
            let raw = max(0, location.speed)
            smoothedSpeed = smoothedSpeed.map { $0 * 0.7 + raw * 0.3 } ?? raw
        }

        // ---- 静止判定：5 分钟内位移不到 20m 就当作在候车/停站 ----
        if let lastMovementFix {
            if location.distance(from: lastMovementFix) > 20 {
                self.lastMovementFix = location
                lastMovementAt = Date()
                isStationary = false
            }
        } else {
            lastMovementFix = location
            lastMovementAt = Date()
        }
        if Date().timeIntervalSince(lastMovementAt) > 300 { isStationary = true }

        guard let projection = RouteService.project(location.coordinate, on: plan) else { return }
        routeProgress = projection.progress
        routeRemaining = projection.remainingMeters

        // 候车时冻结剩余时间：动都不动还报"还剩 12 分钟"才是最假的
        let minutes: Int?
        if isStationary {
            minutes = routedETA
        } else {
            minutes = RouteService.remainingMinutes(
                plan: plan,
                projection: projection,
                currentSpeed: smoothedSpeed
            )
            if let minutes { routedETA = minutes }
        }

        Task {
            await liveActivity.updateRoute(
                progress: projection.progress,
                remainingMeters: projection.remainingMeters,
                remainingMinutes: minutes,
                mode: plan.mode,
                paused: isStationary
            )
        }

        // 偏航 80m 以上重规划，30 秒内不重复请求
        if projection.offRouteMeters > 80, Date().timeIntervalSince(lastReplanAt) > 30 {
            lastReplanAt = Date()
            Task { await planRoute() }
        }
    }

    private func planRoute() async {
        guard isTracking, let stop = nextStop, let here = locationService.currentLocation else {
            routePlan = nil
            routeProgress = nil
            routeRemaining = nil
            return
        }

        let destination = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
        do {
            let plan = try await RouteService.shared.plan(
                from: here.coordinate,
                to: destination,
                mode: travelMode
            )
            routePlan = plan
            routeError = nil
            lastReplanAt = Date()

            guard let projection = RouteService.project(here.coordinate, on: plan) else { return }
            routeProgress = projection.progress
            routeRemaining = projection.remainingMeters

            let minutes = RouteService.remainingMinutes(
                plan: plan,
                projection: projection,
                currentSpeed: smoothedSpeed ?? (here.speed >= 0 ? here.speed : nil)
            )
            if let minutes, !isStationary { routedETA = minutes }
            await liveActivity.updateRoute(
                progress: projection.progress,
                remainingMeters: projection.remainingMeters,
                remainingMinutes: routedETA,
                mode: plan.mode,
                paused: isStationary
            )
        } catch {
            // 规划失败不影响到站提醒：围栏照旧，界面退回直线距离
            routePlan = nil
            routeProgress = nil
            routeRemaining = nil
            routeError = error.localizedDescription
            await liveActivity.clearRoute()
        }
    }

    // MARK: - 提醒距离

    private var radiusControl: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("下一站提醒距离")
                .font(NearNoteStyle.Typeface.label)
                .foregroundStyle(NearNoteStyle.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(radiusOptions, id: \.self) { option in
                        radiusChip(option)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func radiusChip(_ meters: Double) -> some View {
        let selected = abs(currentRadius - meters) < 1
        return Button {
            applyRadius(meters)
        } label: {
            Text(meters.distanceText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? .white : NearNoteStyle.textSecondary)
                .padding(.horizontal, 15)
                .frame(height: 36)
                .background(
                    selected ? NearNoteStyle.accentDeep : NearNoteStyle.raisedSurface,
                    in: RoundedRectangle(cornerRadius: NearNoteStyle.controlRadius, style: .continuous)
                )
                .overlay {
                    if !selected {
                        RoundedRectangle(cornerRadius: NearNoteStyle.controlRadius, style: .continuous)
                            .stroke(NearNoteStyle.hairline, lineWidth: 0.5)
                    }
                }
        }
        .buttonStyle(PressableStyle())
    }

    private var currentRadius: Double {
        nextStop?.radius ?? defaultRadius
    }

    // MARK: - 站点队列

    private var stopsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("站点队列")
                    .font(NearNoteStyle.Typeface.title)
                    .foregroundStyle(NearNoteStyle.textPrimary)
                Spacer()
                Button(action: onAdd) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        Text("添加").font(NearNoteStyle.Typeface.micro)
                    }
                    .foregroundStyle(NearNoteStyle.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(NearNoteStyle.accentGhost, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }

            if orderedStations.isEmpty {
                emptyCard
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(visibleStops.enumerated()), id: \.element.id) { index, stop in
                        stopRow(index: index, stop: stop, isLast: index == orderedStations.count - 1)
                    }
                }

                if orderedStations.count > 4 {
                    Button {
                        withAnimation(.easeOut(duration: 0.22)) { expandedList.toggle() }
                    } label: {
                        Text(expandedList ? "收起" : "展开全部 \(orderedStations.count) 站")
                            .font(NearNoteStyle.Typeface.micro)
                            .foregroundStyle(NearNoteStyle.textSecondary)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    private var visibleStops: [Reminder] {
        expandedList ? orderedStations : Array(orderedStations.prefix(4))
    }

    private func stopRow(index: Int, stop: Reminder, isLast: Bool) -> some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isLast ? NearNoteStyle.accentSoft : NearNoteStyle.raisedSurface)
                Text("\(index + 1)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(isLast ? NearNoteStyle.accent : NearNoteStyle.textSecondary)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(stop.title)
                        .font(NearNoteStyle.Typeface.rowTitle)
                        .foregroundStyle(NearNoteStyle.textPrimary)
                        .lineLimit(1)
                    if isLast {
                        MetaTag(text: "终点", tint: NearNoteStyle.accent)
                    }
                    if stop.id == activeStopID {
                        MetaTag(text: "当前", tint: NearNoteStyle.accent)
                    }
                }
                Text("提醒 \(stop.radius.distanceText)")
                    .font(NearNoteStyle.Typeface.label)
                    .foregroundStyle(NearNoteStyle.textTertiary)
            }

            Spacer(minLength: 8)

            Text(distanceLabel(stop))
                .font(NearNoteStyle.Typeface.metric)
                .monospacedDigit()
                .foregroundStyle(NearNoteStyle.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(NearNoteStyle.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(NearNoteStyle.hairline, lineWidth: 0.5)
        }
        .contextMenu {
            Button {
                withAnimation { currentIndex = max(0, index) }
            } label: {
                Label("设为下一站", systemImage: "arrow.up.forward")
            }
            Button(role: .destructive) {
                delete(stop)
            } label: {
                Label("删除站点", systemImage: "trash")
            }
        }
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(NearNoteStyle.accent)
                    .frame(width: 42, height: 42)
                    .background(NearNoteStyle.accentGhost, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("还没有站点")
                        .font(NearNoteStyle.Typeface.rowTitle)
                        .foregroundStyle(NearNoteStyle.textPrimary)
                    Text("在地图上选一个下车点，到站时手机会响。")
                        .font(NearNoteStyle.Typeface.label)
                        .foregroundStyle(NearNoteStyle.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: onAdd) {
                Text("添加一个站点")
                    .font(NearNoteStyle.Typeface.micro)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(NearNoteStyle.accentDeep, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NearNoteStyle.surface, in: RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous)
                .stroke(NearNoteStyle.hairline, lineWidth: 0.5)
        }
    }

    // MARK: - 权限

    private var hasAlwaysPermission: Bool {
        locationService.authorizationStatus == .authorizedAlways
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(NearNoteStyle.accent)
                Text("定位权限还不是「始终」")
                    .font(NearNoteStyle.Typeface.rowTitle)
                    .foregroundStyle(NearNoteStyle.textPrimary)
            }
            Text("只有「始终允许」，App 在后台或被系统回收后才能真正收到到站提醒。")
                .font(NearNoteStyle.Typeface.label)
                .foregroundStyle(NearNoteStyle.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    locationService.requestAlwaysPermission()
                } label: {
                    Text("现在授权")
                        .font(NearNoteStyle.Typeface.micro)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(NearNoteStyle.accentDeep, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(PressableStyle())

                Button {
                    openAppSettings()
                } label: {
                    Text("去设置")
                        .font(NearNoteStyle.Typeface.micro)
                        .foregroundStyle(NearNoteStyle.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(NearNoteStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NearNoteStyle.surface, in: RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous)
                .stroke(NearNoteStyle.hairline, lineWidth: 0.5)
        }
    }

    // MARK: - 底部主按钮

    private var ctaBar: some View {
        VStack(spacing: 9) {
            Text(isTracking ? "灵动岛显示下一站距离，锁屏也能看。" : "开始后，接近下一站时手机会响铃并语音播报。")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(NearNoteStyle.textTertiary)
                .lineLimit(1)

            PrimaryActionButton(
                title: isTracking ? "结束追踪" : "开始追踪",
                symbol: isTracking ? "stop.circle.fill" : "location.north.line.fill",
                role: isTracking ? .secondary : .primary
            ) {
                toggleTracking()
            }
            .disabled(orderedStations.isEmpty)
            .opacity(orderedStations.isEmpty ? 0.45 : 1)
        }
        .padding(.horizontal, NearNoteStyle.gutter)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .background {
            LinearGradient(
                colors: [
                    NearNoteStyle.canvas.opacity(0),
                    NearNoteStyle.canvas.opacity(0.92),
                    NearNoteStyle.canvas,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: - 数据

    private var activeStations: [Reminder] {
        let all = reminders.filter { $0.isEnabled && !$0.isCompleted && !$0.isArchived }
        // 首页只关心"此刻生效"的项目（星期 + 时间段都对得上）；
        // 万一个都没生效（比如周末不开车），就把全部项目放出来手动挑。
        let scheduled = all.filter { $0.isScheduled() }
        return scheduled.isEmpty ? all : scheduled
    }

    /// 追踪中按开始时的顺序（接力顺序不能因为位置变化而乱跳），
    /// 未开始时按距离由近到远。
    private var orderedStations: [Reminder] {
        let byDistance = activeStations.sorted { distance(to: $0) < distance(to: $1) }
        guard isTracking else { return byDistance }

        let savedIDs = stationIDsRaw
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
        guard !savedIDs.isEmpty else { return byDistance }

        let lookup = Dictionary(uniqueKeysWithValues: activeStations.map { ($0.id, $0) })
        let restored = savedIDs.compactMap { lookup[$0] }
        return restored.isEmpty ? byDistance : restored
    }

    /// 追踪中"下一站"由队列游标决定，未开始则取离你最近的那站。
    private var queueIndex: Int {
        guard isTracking else { return 0 }
        let list = orderedStations
        return list.indices.contains(currentIndex) ? currentIndex : 0
    }

    private var nextStop: Reminder? {
        let list = orderedStations
        return list.indices.contains(queueIndex) ? list[queueIndex] : list.first
    }

    private var activeStopID: UUID? { nextStop?.id }

    /// 还没走完的站数（含当前站）
    private var remainingStopCount: Int {
        max(0, orderedStations.count - queueIndex)
    }

    private func distance(to reminder: Reminder) -> Double {
        guard let location = locationService.currentLocation else {
            return .greatestFiniteMagnitude
        }
        return location.distance(
            from: CLLocation(latitude: reminder.latitude, longitude: reminder.longitude)
        )
    }

    private func distanceLabel(_ reminder: Reminder) -> String {
        let meters = distance(to: reminder)
        guard meters.isFinite, meters < 1_000_000 else { return "—" }
        return meters.distanceText
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    // MARK: - 动作

    private func toggleTracking() {
        if isTracking {
            stopTracking()
        } else {
            startTracking()
        }
    }

    private func startTracking() {
        let plan = orderedStations
        guard let first = plan.first else { return }

        stationIDsRaw = plan.map { $0.id.uuidString }.joined(separator: ",")
        currentIndex = 0
        isTracking = true
        smoothedSpeed = nil
        lastMovementFix = nil
        lastMovementAt = Date()
        isStationary = false
        // 静音保活：追踪期间让 App 不被挂起，围栏触发时才有机会跑语音与灵动岛接力
        AudioKeepAliveService.shared.startIfNeeded()

        Task {
            if locationService.authorizationStatus == .notDetermined {
                locationService.requestAlwaysPermission()
            }
            locationService.startInUseTracking()
            await GeofenceManager.shared.refresh(near: locationService.currentLocation)

            do {
                try await liveActivity.start(
                    stations: plan,
                    destinationName: plan.last?.title ?? first.title
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func stopTracking() {
        isTracking = false
        currentIndex = 0
        AudioKeepAliveService.shared.stop()
        routePlan = nil
        routeProgress = nil
        routeRemaining = nil
        routeError = nil
        routedETA = nil
        lastRouteFix = nil
        smoothedSpeed = nil
        lastMovementFix = nil
        lastMovementAt = Date()
        isStationary = false
        Task {
            await RouteService.shared.clear()
            await liveActivity.end()
        }
    }

    private func applyRadius(_ meters: Double) {
        defaultRadius = meters
        if let stop = nextStop {
            stop.radius = meters
            try? modelContext.save()
        }
        Task { await GeofenceManager.shared.refresh(near: locationService.currentLocation) }
    }

    private func delete(_ reminder: Reminder) {
        Task { @MainActor in
            GeofenceManager.shared.stop(reminder: reminder)
            modelContext.delete(reminder)
            try? modelContext.save()
            await liveActivity.end(reminderID: reminder.id)
            await GeofenceManager.shared.refresh(near: locationService.currentLocation)
        }
    }

    /// 锁屏卡片上点了「结束」：系统已经关掉活动卡片并把 trip.isTracking 置 false，
    /// 这里负责收拾 App 侧的东西（保活音频、路线缓存、定位）。
    private func handleExternalEnd() {
        guard isTracking else { return }
        isTracking = false
        currentIndex = 0
        AudioKeepAliveService.shared.stop()
        routePlan = nil
        routeProgress = nil
        routeRemaining = nil
        routeError = nil
        routedETA = nil
        lastRouteFix = nil
        smoothedSpeed = nil
        lastMovementFix = nil
        lastMovementAt = Date()
        isStationary = false
        Task {
            await RouteService.shared.clear()
            await GeofenceManager.shared.refresh(near: locationService.currentLocation)
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// ETA 定时刷新。`task(id:)` 在切换下一站时会自动重跑并取消旧的循环。
    private func etaLoop() async {
        while !Task.isCancelled {
            await refreshETA()
            try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
        }
    }

    private func refreshETA() async {
        // 候车中不刷新剩余时间（保持上一次的数，别让它越等越涨）
        guard !isStationary else { return }
        guard let stop = nextStop, let here = locationService.currentLocation else { return }
        let destination = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
        let estimate = await RouteETAService.shared.estimate(from: here.coordinate, to: destination)
        routedETA = estimate.minutes
        await liveActivity.setETA(minutes: estimate.minutes)
    }
}
