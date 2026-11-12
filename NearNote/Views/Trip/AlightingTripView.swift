import CoreLocation
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
    @State private var activeStopID: UUID?
    @State private var expandedList = false
    @State private var errorMessage: String?

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
            statusPill
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isTracking ? NearNoteStyle.accent : NearNoteStyle.textTertiary)
                .frame(width: 6, height: 6)
            Text(isTracking ? "追踪中" : "未开始")
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
        let progress = "第 1 / \(orderedStations.count) 站"
        return "提醒半径 \(stop.radius.distanceText) · \(progress)"
    }

    // MARK: - 参数带

    private var metrics: some View {
        MetricStrip(items: [
            .init(value: etaValue, unit: etaValue == "—" ? nil : "分钟", caption: "预计"),
            .init(value: "\(orderedStations.count)", unit: "站", caption: "剩余"),
            .init(value: radiusShortLabel, unit: nil, caption: "提醒半径"),
        ])
    }

    private var etaValue: String {
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
                withAnimation { activeStopID = stop.id }
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
        reminders.filter { $0.isEnabled && !$0.isCompleted && !$0.isArchived }
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

    private var nextStop: Reminder? {
        orderedStations.first
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
        activeStopID = first.id
        isTracking = true
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
        activeStopID = nil
        AudioKeepAliveService.shared.stop()
        Task { await liveActivity.end() }
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
        guard let stop = nextStop, let here = locationService.currentLocation else { return }
        let destination = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
        let estimate = await RouteETAService.shared.estimate(from: here.coordinate, to: destination)
        routedETA = estimate.minutes
        await liveActivity.setETA(minutes: estimate.minutes)
    }
}
