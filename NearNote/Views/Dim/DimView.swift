import SwiftUI
import UIKit
import CoreLocation

/// 极暗页：锁屏卡片上点「调暗」进来。
///
/// 为什么不是直接在锁屏上改亮度？Live Activity 跑在扩展进程里，
/// 系统不允许扩展调屏幕亮度，只有 App 在前台时 `UIScreen.main.brightness` 才有效。
/// 所以「调暗」做成一次深链：点一下进 App，屏幕压到最暗、只留剩余里程和分钟，
/// 点任意位置退出并恢复原亮度。夜里看一眼不用被白光糊一脸。
struct DimView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var locationService: LocationService

    @State private var previousBrightness: CGFloat?
    @State private var now = Date()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                Text(target == nil ? "还没有生效的通勤项目" : "还有")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(bright(0.38))

                Text(minutesText)
                    .font(.system(size: 132, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(bright(0.72))
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                if target != nil {
                    Text("分钟")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(bright(0.38))
                }

                if let target {
                    Text(target.title)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(bright(0.55))
                        .lineLimit(1)
                        .padding(.top, 26)

                    Text("\(distanceText) · 到站会响铃")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(bright(0.3))
                        .padding(.top, 7)
                }

                Spacer(minLength: 0)

                Text("点任意位置退出")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(bright(0.22))
                    .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { dim() }
        .onDisappear { restore() }
        .task {
            // 每 10 秒重算一次，页面开着也能看到数字在变
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                now = Date()
            }
        }
    }

    // MARK: - 数据

    private var target: Reminder? {
        let candidates = ReminderStore.shared.fetchActive().filter { $0.isScheduled(at: now) }
        guard locationService.currentLocation != nil else { return candidates.first }
        return candidates.min { distance(to: $0) < distance(to: $1) }
    }

    private func distance(to reminder: Reminder) -> Double {
        guard let location = locationService.currentLocation else { return .greatestFiniteMagnitude }
        return location.distance(
            from: CLLocation(latitude: reminder.latitude, longitude: reminder.longitude)
        )
    }

    private var meters: Double? {
        guard let target else { return nil }
        let value = distance(to: target)
        return value.isFinite && value < 1_000_000 ? value : nil
    }

    private var minutesText: String {
        guard let meters else { return "—" }
        return "\(RouteETAService.shared.heuristicMinutes(meters: meters))"
    }

    private var distanceText: String {
        meters?.distanceText ?? "—"
    }

    // MARK: - 亮度

    private func dim() {
        guard previousBrightness == nil else { return }
        previousBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0.02
    }

    private func restore() {
        if let previousBrightness {
            UIScreen.main.brightness = previousBrightness
        }
        previousBrightness = nil
    }

    /// 屏幕已经被压到 2% 了，再把字做得更暗就会看不见，所以这里只做很轻微的层次
    private func bright(_ value: Double) -> Color {
        Color(white: value)
    }
}

#Preview {
    DimView().environmentObject(LocationService.shared)
}
