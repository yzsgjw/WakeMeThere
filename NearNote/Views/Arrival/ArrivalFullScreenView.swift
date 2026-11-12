import SwiftUI
import SwiftData
import UIKit
import CoreLocation

/// 到站全屏。
///
/// 边界说明（别指望更多）：iOS 不允许第三方 App 在锁屏上"不碰手机自己铺满屏幕"，
/// 那是来电/闹钟的特权，第三方要同等效果得申请 Critical Alerts 并由 Apple 单独审批。
/// 这里能做到的三条路，全部接上了：
/// 1. 通知点一下 → `arrival://arrival/<uuid>` → 直接打开这一页；
/// 2. 通知横幅的默认动作 → 同样落到这一页（不再擅自跳到 Apple 地图）；
/// 3. App 正开着时围栏触发 → 自动 `fullScreenCover` 盖上来。
struct ArrivalFullScreenView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let reminder: Reminder
    /// 作为 App 内覆盖层呈现时由外面关；用 sheet 呈现时留空走 dismiss
    var onClose: (() -> Void)? = nil

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }


    private var stationName: String {
        reminder.placeName.isEmpty ? reminder.title : reminder.placeName
    }

    private var distance: Double? {
        guard let location = LocationService.shared.currentLocation else { return nil }
        return location.distance(from: CLLocation(latitude: reminder.latitude, longitude: reminder.longitude))
    }

    var body: some View {
        ZStack {
            NearNoteBackground()

            RadialGradient(
                colors: [NearNoteStyle.accent.opacity(0.30), .clear],
                center: .top,
                startRadius: 8,
                endRadius: 460
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 30)

                VStack(spacing: 10) {
                    Image(systemName: "figure.walk.arrival")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(NearNoteStyle.accent)
                        .padding(.bottom, 4)

                    Text("到站了")
                        .font(NearNoteStyle.Typeface.label)
                        .foregroundStyle(NearNoteStyle.textSecondary)
                        .tracking(2)

                    Text(stationName)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(NearNoteStyle.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 24)

                    if let distance {
                        Text("距站点约 \(distance.distanceText)")
                            .font(NearNoteStyle.Typeface.body)
                            .foregroundStyle(NearNoteStyle.textSecondary)
                            .monospacedDigit()
                    } else {
                        Text("已进入 \(reminder.radius.distanceText) 提醒范围")
                            .font(NearNoteStyle.Typeface.body)
                            .foregroundStyle(NearNoteStyle.textSecondary)
                    }

                    HStack(spacing: 6) {
                        MetaTag(text: reminder.scheduleText, symbol: "clock")
                        MetaTag(text: reminder.chime.label, symbol: "bell.fill")
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)

                Spacer(minLength: 24)

                VStack(spacing: 12) {
                    PrimaryActionButton(title: "我到了", symbol: "checkmark.circle.fill") {
                        complete()
                    }

                    Button {
                        snooze()
                    } label: {
                        Text("30 分钟后再提醒")
                            .font(NearNoteStyle.Typeface.cta)
                            .foregroundStyle(NearNoteStyle.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(
                                NearNoteStyle.surface,
                                in: RoundedRectangle(cornerRadius: NearNoteStyle.buttonRadius, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: NearNoteStyle.buttonRadius, style: .continuous)
                                    .strokeBorder(NearNoteStyle.hairlineStrong, lineWidth: 1)
                            }
                    }
                    .buttonStyle(PressableStyle())

                    Button("关闭") { close() }
                        .font(NearNoteStyle.Typeface.label)
                        .foregroundStyle(NearNoteStyle.textTertiary)
                        .padding(.top, 2)
                }
                .padding(.horizontal, NearNoteStyle.gutter)
                .padding(.bottom, 28)
            }
        }
        .onAppear {
            // 进来先让声音停下来：用户已经在看这一页，继续响铃只会烦
            AlarmPlaybackService.shared.stop()
            AudioKeepAliveService.shared.pauseForAnnouncement()
        }
        .onDisappear {
            AudioKeepAliveService.shared.resumeAfterAnnouncement()
        }
    }

    private func complete() {
        reminder.markDone()
        GeofenceManager.shared.stop(reminder: reminder)
        try? modelContext.save()
        let location = LocationService.shared.currentLocation
        Task { await GeofenceManager.shared.refresh(near: location) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        close()
    }

    private func snooze() {
        reminder.snoozedUntil = Date().addingTimeInterval(30 * 60)
        try? modelContext.save()
        AlarmPlaybackService.shared.stop()
        close()
    }
}
