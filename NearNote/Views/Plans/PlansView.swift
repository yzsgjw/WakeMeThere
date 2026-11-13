import SwiftUI
import SwiftData
import UIKit
import CoreLocation

/// 通勤项目列表。
///
/// 「项目」= 一条带星期 + 时间窗的到站提醒：早上上班、晚上回家各一条，
/// 各自带开关。开着的项目靠**时间段**分工，而不是靠「当前选中哪一条」——
/// iOS 在后台没法保证 7:30 那一刻叫醒 App 去切换，所以排队式「下一条」是伪需求。
struct PlansView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Reminder.createdAt, order: .reverse) private var reminders: [Reminder]
    @StateObject private var locationService = LocationService.shared
    @StateObject private var geofence = GeofenceManager.shared
    @StateObject private var notifications = NotificationService.shared
    /// 右滑删除：同时最多只允许一行露出删除按钮
    @State private var openedID: UUID?
    @State private var dragID: UUID?
    @State private var dragOffset: CGFloat = 0

    var onAdd: () -> Void
    var onMap: (() -> Void)?
    /// 编辑交给 MainView 统一呈现（全 App 只保留一个 sheet，避免命中区域错位）
    var onEdit: ((UUID) -> Void)?

    private var plans: [Reminder] {
        reminders.filter { !$0.isArchived && !$0.isCompleted }
    }

    private var activePlans: [Reminder] { plans.filter(\.isEnabled) }
    private var inactivePlans: [Reminder] { plans.filter { !$0.isEnabled } }

    /// 现在正在生效的项目（星期 + 时间窗都命中的那些）
    private var liveNow: [Reminder] {
        // 今天已经响过的不算「正在生效」——不然到站之后它还挂在生效里，看着像没结束。
        activePlans.filter { $0.isScheduled() && !$0.arrivedToday }
    }

    private var arrivedTodayPlans: [Reminder] {
        activePlans.filter(\.arrivedToday)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NearNoteBackground()
                if plans.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: NearNoteStyle.sectionGap) {
                            statusHeader
                            healthCard
                            if !activePlans.isEmpty {
                                section("进行中", plans: activePlans)
                            }
                            if !inactivePlans.isEmpty {
                                section("未进行", plans: inactivePlans)
                            }
                        }
                        .padding(.horizontal, NearNoteStyle.gutter)
                        .padding(.top, 12)
                        .padding(.bottom, 120)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    PrimaryActionButton(title: "新建通勤项目", symbol: "plus") { onAdd() }
                        .padding(.horizontal, NearNoteStyle.gutter)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                        // 材质会把底下的按钮压成半透明，看起来像"点不动"；用实心底
                        .background(
                            LinearGradient(
                                colors: [NearNoteStyle.canvas.opacity(0), NearNoteStyle.canvas.opacity(0.96), NearNoteStyle.canvas],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .overlay(alignment: .top) {
                                Rectangle().fill(NearNoteStyle.hairline).frame(height: 1)
                            }
                        )
                }
            }
            .navigationTitle("通勤项目")
            .navigationBarTitleDisplayMode(.large)
            .task {
                notifications.checkPermissionStatus()
                geofence.refreshRegisteredCount()
                // 有项目却还没问过定位 → 现在就问，否则系统压根不会注册围栏
                if locationService.authorizationStatus == .notDetermined, !plans.isEmpty {
                    locationService.requestWhenInUsePermission()
                }
                await locationService.updateMonitoredRegions()
                geofence.refreshRegisteredCount()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onAdd()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .tint(NearNoteStyle.accent)
                    .accessibilityLabel("新建通勤项目")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onMap?()
                    } label: {
                        Image(systemName: "map")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .tint(NearNoteStyle.accent)
                    .accessibilityLabel("打开地图")
                }
            }
        }
    }

    // MARK: - 状态头

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(liveNow.isEmpty ? "此刻没有生效中的项目" : "此刻生效中 \(liveNow.count) 个")
                .font(NearNoteStyle.Typeface.title)
                .foregroundStyle(NearNoteStyle.textPrimary)
            if !arrivedTodayPlans.isEmpty {
                Text("今天已完成 \(arrivedTodayPlans.count) 个（明天自动恢复）")
                    .font(NearNoteStyle.Typeface.micro)
                    .foregroundStyle(NearNoteStyle.textTertiary)
            }
            Text(liveNow.isEmpty
                 ? "开着的项目到点会自己接管，不用手动切换。"
                 : liveNow.map { $0.title.isEmpty ? $0.placeName : $0.title }.joined(separator: " · "))
                .font(NearNoteStyle.Typeface.body)
                .foregroundStyle(NearNoteStyle.textSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 到站体检

    private var locationOK: Bool { locationService.authorizationStatus == .authorizedAlways }

    private var locationValue: String {
        switch locationService.authorizationStatus {
        case .authorizedAlways: "始终允许"
        case .authorizedWhenInUse: "仅使用期间"
        case .denied: "已拒绝"
        case .restricted: "受限"
        case .notDetermined: "未询问"
        @unknown default: "未知"
        }
    }

    private var healthy: Bool { locationOK && notifications.isAuthorized && geofence.registeredCount > 0 }

    /// 「到站能不能响」的体检卡。
    /// 围栏是静默失败的：没权限、只有「使用期间」权限、半径太小，系统全都一声不吭。
    /// 与其让用户猜"为什么进去不响"，不如把三件必要条件直接摆出来，外加一个绕过围栏的试响按钮。
    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: healthy ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(healthy ? NearNoteStyle.accent : NearNoteStyle.textSecondary)
                Text(healthy ? "到站会响" : "现在有环节没接通")
                    .font(NearNoteStyle.Typeface.rowTitle)
                    .foregroundStyle(NearNoteStyle.textPrimary)
                Spacer()
                Text(geofence.registeredCount > 0 ? "盯 \(geofence.registeredCount) 个" : "还没盯上")
                    .font(NearNoteStyle.Typeface.label)
                    .foregroundStyle(NearNoteStyle.textTertiary)
            }

            healthRow("定位权限", locationValue, ok: locationOK)
            healthRow("通知权限", notifications.isAuthorized ? "已开启" : "没开", ok: notifications.isAuthorized)
            healthRow("系统围栏", "\(geofence.registeredCount) 个已注册", ok: geofence.registeredCount > 0)

            if let failure = geofence.lastFailure {
                Text(failure)
                    .font(NearNoteStyle.Typeface.micro)
                    .foregroundStyle(NearNoteStyle.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !geofence.recentEvents.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(geofence.recentEvents.prefix(3)), id: \.self) { line in
                        Text(line)
                            .font(NearNoteStyle.Typeface.micro)
                            .foregroundStyle(NearNoteStyle.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 8) {
                if !locationOK {
                    healthButton(locationService.authorizationStatus == .notDetermined ? "开启定位" : "改成始终") {
                        if locationService.authorizationStatus == .notDetermined {
                            locationService.requestWhenInUsePermission()
                        } else {
                            locationService.requestAlwaysPermission()
                        }
                    }
                }
                if !notifications.isAuthorized {
                    healthButton("开启通知") { notifications.requestPermission() }
                }
                healthButton("试响一下") { testArrival() }
                healthButton("重置冷却") {
                    geofence.clearCooldowns()
                    Task { await locationService.updateMonitoredRegions() }
                }
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous)
                .fill(NearNoteStyle.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous)
                        .stroke(NearNoteStyle.hairline, lineWidth: 1)
                )
        )
    }

    private func healthRow(_ title: String, _ value: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "circle.fill" : "circle")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(ok ? NearNoteStyle.accent : NearNoteStyle.textTertiary)
            Text(title)
                .font(NearNoteStyle.Typeface.label)
                .foregroundStyle(NearNoteStyle.textSecondary)
            Spacer()
            Text(value)
                .font(NearNoteStyle.Typeface.label)
                .foregroundStyle(ok ? NearNoteStyle.textPrimary : NearNoteStyle.textTertiary)
        }
    }

    private func healthButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(NearNoteStyle.Typeface.label)
                .foregroundStyle(NearNoteStyle.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(NearNoteStyle.accentGhost)
                        .overlay(Capsule().stroke(NearNoteStyle.accent.opacity(0.35), lineWidth: 1))
                )
        }
        .buttonStyle(PressableStyle())
    }

    /// 试响：整条到站链路跑一遍（含全屏页），不经过围栏。
    private func testArrival() {
        guard let plan = activePlans.first ?? plans.first else { return }
        notifications.testArrival(for: plan)
    }

    // MARK: - 分组

    private func section(_ title: String, plans: [Reminder]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(NearNoteStyle.Typeface.title)
                    .foregroundStyle(NearNoteStyle.textPrimary)
                Text("\(plans.count)")
                    .font(NearNoteStyle.Typeface.micro)
                    .foregroundStyle(NearNoteStyle.textTertiary)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            VStack(spacing: 10) {
                ForEach(plans) { plan in
                    swipeRow(plan)
                }
            }
        }
    }

    // MARK: - 右滑删除

    private static let deleteReveal: CGFloat = 84

    /// ScrollView 里没有原生的 .swipeActions，所以自己做一个：
    /// 卡片下面的 ZStack 底层放删除按钮，卡片按手势横向偏移把它露出来。
    private func swipeRow(_ plan: Reminder) -> some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive) {
                withAnimation(.easeOut(duration: 0.2)) { openedID = nil }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                delete(plan)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("删除")
                        .font(NearNoteStyle.Typeface.micro)
                }
                .foregroundStyle(.white)
                .frame(width: Self.deleteReveal)
                .frame(maxHeight: .infinity)
                .background(
                    NearNoteStyle.danger,
                    in: RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .opacity(swipeOffset(plan) < -8 ? 1 : 0)
            .allowsHitTesting(swipeOffset(plan) < -8)

            planRow(plan)
                .offset(x: swipeOffset(plan))
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            // 只在明显横向时接管，纵向留给 ScrollView
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            let base: CGFloat = openedID == plan.id ? -Self.deleteReveal : 0
                            dragID = plan.id
                            dragOffset = min(0, max(-Self.deleteReveal - 26, base + value.translation.width))
                        }
                        .onEnded { value in
                            guard dragID == plan.id else { return }
                            let base: CGFloat = openedID == plan.id ? -Self.deleteReveal : 0
                            let final = base + value.translation.width
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                openedID = final < -Self.deleteReveal / 2 ? plan.id : nil
                            }
                            dragID = nil
                            dragOffset = 0
                        }
                )
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: openedID)
        }
        .clipShape(RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous))
    }

    private func swipeOffset(_ plan: Reminder) -> CGFloat {
        if dragID == plan.id { return dragOffset }
        return openedID == plan.id ? -Self.deleteReveal : 0
    }

    private func planRow(_ plan: Reminder) -> some View {
        HStack(alignment: .top, spacing: 14) {
            PlaceIcon(category: plan.category, size: 38)
                .opacity(plan.isEnabled ? 1 : 0.45)

            VStack(alignment: .leading, spacing: 5) {
                Text(plan.title.isEmpty ? plan.placeName : plan.title)
                    .font(NearNoteStyle.Typeface.rowTitle)
                    .foregroundStyle(plan.isEnabled ? NearNoteStyle.textPrimary : NearNoteStyle.textSecondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(plan.scheduleText)
                    Text("·")
                    Text(plan.radius.distanceText)
                }
                .font(NearNoteStyle.Typeface.micro)
                .foregroundStyle(NearNoteStyle.textTertiary)
                .lineLimit(1)

                HStack(spacing: 6) {
                    MetaTag(
                        text: plan.chime.label,
                        symbol: "bell.fill",
                        tint: NearNoteStyle.textSecondary
                    )
                    if plan.vibrationEnabled {
                        MetaTag(text: "震动", symbol: "iphone.radiowaves.left.and.right",
                                tint: NearNoteStyle.textSecondary)
                    }
                    if plan.fullScreenOnArrival {
                        MetaTag(text: "全屏", symbol: "rectangle.inset.filled",
                                tint: NearNoteStyle.textSecondary)
                    }
                    if plan.arrivedToday {
                        MetaTag(text: "今日已到", symbol: "checkmark.circle.fill",
                                tint: NearNoteStyle.accent)
                    }
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { plan.isEnabled },
                set: { setEnabled(plan, $0) }
            ))
            .labelsHidden()
            .tint(NearNoteStyle.accent)
        }
        .padding(14)
        .background(NearNoteStyle.surface, in: RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous)
                .strokeBorder(NearNoteStyle.hairline, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if openedID == plan.id {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { openedID = nil }
            } else {
                onEdit?(plan.id)
            }
        }
        .contextMenu {
            Button {
                onEdit?(plan.id)
            } label: {
                Label("编辑", systemImage: "slider.horizontal.3")
            }
            Button {
                notifications.testArrival(for: plan)
            } label: {
                Label("立即测试", systemImage: "bell.badge")
            }
            Button {
                setEnabled(plan, !plan.isEnabled)
            } label: {
                Label(plan.isEnabled ? "关闭" : "打开", systemImage: plan.isEnabled ? "pause.circle" : "play.circle")
            }
            Divider()
            Button(role: .destructive) {
                delete(plan)
            } label: {
                Label("删除项目", systemImage: "trash")
            }
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sun.horizon.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(NearNoteStyle.accent)
            Text("还没有通勤项目")
                .font(NearNoteStyle.Typeface.title)
                .foregroundStyle(NearNoteStyle.textPrimary)
            Text("加一条「早上到公司」，选好星期和时间，\n到站前它会自己叫你下车。")
                .font(NearNoteStyle.Typeface.body)
                .foregroundStyle(NearNoteStyle.textSecondary)
                .multilineTextAlignment(.center)

            // 空态里也放一个入口：底部那条按钮万一被系统底栏压住，
            // 这里的按钮照样点得开。
            PrimaryActionButton(title: "新建通勤项目", symbol: "plus") { onAdd() }
                .padding(.horizontal, 30)
                .padding(.top, 8)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 动作

    private func setEnabled(_ plan: Reminder, _ value: Bool) {
        plan.isEnabled = value
        if !value { plan.isCompleted = false }
        try? modelContext.save()
        // 开关一变就重注册围栏：关掉的项目不该继续占 iOS 的 20 个名额
        let location = locationService.currentLocation
        Task { await GeofenceManager.shared.refresh(near: location) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func delete(_ plan: Reminder) {
        GeofenceManager.shared.stop(reminder: plan)
        modelContext.delete(plan)
        try? modelContext.save()
        let location = locationService.currentLocation
        Task { await GeofenceManager.shared.refresh(near: location) }
    }
}

#Preview {
    PlansView(onAdd: {})
        .modelContainer(for: Reminder.self, inMemory: true)
}
