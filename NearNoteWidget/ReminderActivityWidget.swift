import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - 配色
//
// Widget 扩展是和主 App 分开的 target，引用不到 NearNoteStyle，
// 所以这里镜像一份。改色时两边必须同时改（值必须逐字相同）。

private enum Ink {
    static let accent = Color(red: 0x3B / 255, green: 0x7D / 255, blue: 0xFF / 255)
    static let card = Color(red: 0x0F / 255, green: 0x16 / 255, blue: 0x1F / 255)
    static let primary = Color(red: 0xF4 / 255, green: 0xF7 / 255, blue: 0xFB / 255)
    static let secondary = Color(red: 0x93 / 255, green: 0xA1 / 255, blue: 0xB4 / 255)
    static let tertiary = Color(red: 0x64 / 255, green: 0x74 / 255, blue: 0x8B / 255)
}

private var tripURL: URL? { URL(string: "arrival://trip") }

// MARK: - Widget

struct ReminderActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ReminderActivityAttributes.self) { context in
            // 锁屏 / 通知中心 / 横幅
            TripLockScreenView(state: context.state)
                .activityBackgroundTint(Ink.card)
                .activitySystemActionForegroundColor(Ink.primary)
                .widgetURL(tripURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DistanceHeadline(state: context.state, size: 24, unitSize: 12)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(context.state.etaText)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Ink.secondary)
                        Text(context.attributes.destinationName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedFooter(state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.state.phase == .arrived
                      ? "checkmark.circle.fill"
                      : "location.north.line.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Ink.accent)
            } compactTrailing: {
                Text(context.state.distanceCompact)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Ink.primary)
            } minimal: {
                Image(systemName: context.state.phase == .arrived
                      ? "checkmark.circle.fill"
                      : "location.north.line.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Ink.accent)
            }
            .keylineTint(Ink.accent)
        }
    }
}

// MARK: - 锁屏卡片

private struct TripLockScreenView: View {
    let state: ReminderActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 13) {
                ApproachRing(state: state, size: 40, lineWidth: 3.5)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("下一站")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Ink.tertiary)
                        Text(state.stationProgressText)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Ink.tertiary.opacity(0.8))
                        if state.phase != .tracking {
                            PhasePill(phase: state.phase)
                        }
                    }
                    Text(state.stationName)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    DistanceHeadline(state: state, size: 26, unitSize: 12)
                    Text(state.etaText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Ink.tertiary)
                }
            }

            ProgressBar(progress: state.progress, height: 3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

// MARK: - 灵动岛展开态底部

private struct ExpandedFooter: View {
    let state: ReminderActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 9) {
            HStack(alignment: .center, spacing: 9) {
                ApproachRing(state: state, size: 26, lineWidth: 2.5)
                Text(state.stationName)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Text(state.stationProgressText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Ink.tertiary)
                Spacer(minLength: 6)
                PhasePill(phase: state.phase)
            }
            ProgressBar(progress: state.progress, height: 3)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }
}

// MARK: - 零件

/// 距离主指标：数值 + 单位两档字号，数字等宽避免跳动
private struct DistanceHeadline: View {
    let state: ReminderActivityAttributes.ContentState
    var size: CGFloat = 24
    var unitSize: CGFloat = 12

    var body: some View {
        let parts = state.distanceParts
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(parts.value)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Ink.primary)
            if !parts.unit.isEmpty {
                Text(parts.unit)
                    .font(.system(size: unitSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(Ink.secondary)
            }
        }
    }
}

/// 进度环：走了多少行程 + 阶段图标（到站后变对勾）
private struct ApproachRing: View {
    let state: ReminderActivityAttributes.ContentState
    var size: CGFloat = 34
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle()
                .stroke(Ink.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.04, state.progress))
                .stroke(Ink.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: state.phase == .arrived ? "checkmark" : "location.north.fill")
                .font(.system(size: size * 0.30, weight: .black))
                .foregroundStyle(state.phase == .arrived ? Ink.accent : Ink.primary)
        }
        .frame(width: size, height: size)
    }
}

private struct ProgressBar: View {
    let progress: Double
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.primary.opacity(0.11))
                Capsule()
                    .fill(Ink.accent)
                    .frame(width: max(height, proxy.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: height)
    }
}

private struct PhasePill: View {
    let phase: ReminderActivityAttributes.Phase

    var body: some View {
        Text(phase.label)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(phase == .tracking ? Ink.secondary : .white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                phase == .tracking ? Ink.primary.opacity(0.10) : Ink.accent,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }
}
