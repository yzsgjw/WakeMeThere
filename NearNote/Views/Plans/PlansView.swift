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
        activePlans.filter { $0.isScheduled() }
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
            .toolbar {
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
            Text(liveNow.isEmpty
                 ? "开着的项目到点会自己接管，不用手动切换。"
                 : liveNow.map { $0.title.isEmpty ? $0.placeName : $0.title }.joined(separator: " · "))
                .font(NearNoteStyle.Typeface.body)
                .foregroundStyle(NearNoteStyle.textSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    planRow(plan)
                }
            }
        }
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
        .onTapGesture { onEdit?(plan.id) }
        .contextMenu {
            Button {
                onEdit?(plan.id)
            } label: {
                Label("编辑", systemImage: "slider.horizontal.3")
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
