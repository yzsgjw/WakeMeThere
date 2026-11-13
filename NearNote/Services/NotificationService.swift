import Foundation
import UserNotifications
import UIKit
import CoreLocation

@MainActor
public final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationService()
    @Published public private(set) var isAuthorized = false
    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
        setupCategories()
        checkPermissionStatus()
    }

    public func checkPermissionStatus() {
        Task { isAuthorized = await center.notificationSettings().authorizationStatus == .authorized }
    }

    public func requestPermission(completion: @escaping (Bool) -> Void = { _ in }) {
        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            isAuthorized = granted
            DiagnosticsLog.shared.record(granted ? "通知权限已开启" : "通知权限被拒绝（不会弹任何提醒）", tag: "通知")
            completion(granted)
        }
    }

    /// 精度太差时的降级：只发一条不响铃的静默通知。
    /// 这时候"在圈里"这个结论并不可信，响铃反而会误报，但也不能什么都不留。
    public func postSilent(for reminder: Reminder) {
        let content = UNMutableNotificationContent()
        let stationName = reminder.placeName.isEmpty ? reminder.title : reminder.placeName
        content.title = "接近 \(stationName)"
        content.body = "定位信号偏弱，先提示一下；到得更准时会再响铃。"
        content.sound = nil
        content.interruptionLevel = .active
        content.threadIdentifier = "arrival-alerts"
        content.userInfo = ["REMINDER_ID": reminder.id.uuidString]
        let request = UNNotificationRequest(identifier: "silent-\(reminder.id.uuidString)-\(Int(Date().timeIntervalSince1970))",
                                            content: content, trigger: nil)
        center.add(request)
        DiagnosticsLog.shared.record("已发静默通知：\(stationName)", tag: "通知")
    }

    public func setupCategories() {
        let done = UNNotificationAction(identifier: "DONE_ACTION", title: "已完成", options: [])
        let snooze = UNNotificationAction(identifier: "SNOOZE_ACTION", title: "30 分钟后再提醒", options: [])
        let navigate = UNNotificationAction(identifier: "NAVIGATE_ACTION", title: "导航", options: [.foreground])
        let wait = UNNotificationAction(identifier: "WAIT_ORIGINAL_ACTION", title: "仍等到原地点", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "REMINDER_CATEGORY", actions: [done, snooze, navigate], intentIdentifiers: []),
            UNNotificationCategory(identifier: "ALTERNATIVE_REMINDER_CATEGORY", actions: [done, wait, snooze, navigate], intentIdentifiers: [])
        ])
    }

    /// 到站铃声。文件不存在时退回系统默认音，不能让通知变成静默。
    private func arrivalSound(for chime: AlarmChime) -> UNNotificationSound {
        if Bundle.main.url(forResource: chime.resourceName, withExtension: "wav") != nil {
            return UNNotificationSound(named: UNNotificationSoundName(chime.fileName))
        }
        return .default
    }

    public func triggerNotification(for reminder: Reminder, alternativePlaceName: String? = nil,
                                    alternativeCoordinate: CLLocationCoordinate2D? = nil) {
        let content = UNMutableNotificationContent()
        let stationName = alternativePlaceName
            ?? (reminder.placeName.isEmpty ? reminder.title : reminder.placeName)

        if alternativePlaceName != nil {
            content.title = "快到 \(stationName) 了"
            content.body = reminder.title.isEmpty ? "已进入提醒范围" : reminder.title
            content.categoryIdentifier = "ALTERNATIVE_REMINDER_CATEGORY"
        } else {
            content.title = "到站提醒 · \(stationName)"
            content.body = reminder.title.isEmpty ? "已进入提醒范围，请准备下车" : reminder.title
            content.categoryIdentifier = "REMINDER_CATEGORY"
        }
        content.sound = arrivalSound(for: reminder.chime)
        DiagnosticsLog.shared.record("已发通知：\(content.title)（铃声 \(reminder.chime.label)）", tag: "通知")
        // 时间敏感通知：无声穿透「专注模式」，不需要任何特殊审批（Critical Alerts 才需要）。
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "arrival-alerts"
        content.userInfo = [
            "REMINDER_ID": reminder.id.uuidString,
            "LATITUDE": alternativeCoordinate?.latitude ?? reminder.latitude,
            "LONGITUDE": alternativeCoordinate?.longitude ?? reminder.longitude
        ]
        let delay = SettingsStore.shared.isQuiet() ? secondsUntilQuietHoursEnd() : 1
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)
        center.add(UNNotificationRequest(identifier: "\(reminder.id)-\(Date().timeIntervalSince1970)", content: content, trigger: trigger))

        announceArrival(stationName: stationName, reminder: reminder, deferred: delay)
    }

    /// 手动「试响一下」：整条到站链路（通知 + 铃声 + 震动 + 语音 + 全屏页）跑一遍，
    /// 但**不经过围栏**。用来把「围栏没触发」「通知没权限」「铃声没声音」三件事分开：
    /// 这条能响而走过去不响，问题就在围栏/权限；这条也不响，问题在通知或音频。
    public func testArrival(for reminder: Reminder) {
        let stationName = reminder.placeName.isEmpty ? reminder.title : reminder.placeName
        center.add(UNNotificationRequest(
            identifier: "test-\(reminder.id)-\(Date().timeIntervalSince1970)",
            content: testContent(for: reminder, stationName: stationName),
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        ))
        AlarmPlaybackService.shared.announceArrival(
            stationName: stationName,
            chime: reminder.chime,
            vibrate: reminder.vibrationEnabled,
            extraSentence: reminder.title.isEmpty ? nil : reminder.title
        )
        if reminder.fullScreenOnArrival {
            NotificationCenter.default.post(name: .arrivalOpened, object: reminder.id)
        }
    }

    private func testContent(for reminder: Reminder, stationName: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "到站提醒 · \(stationName)"
        content.body = "（试响）\(reminder.title.isEmpty ? "已进入提醒范围，请准备下车" : reminder.title)"
        content.categoryIdentifier = "REMINDER_CATEGORY"
        content.sound = arrivalSound(for: reminder.chime)
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "arrival-alerts"
        content.userInfo = ["REMINDER_ID": reminder.id.uuidString]
        return content
    }

    /// 到站发声：**持续响到人处理**。
    /// 通知自带的声音只响一次且上限约 30 秒，所以真正的"闹钟式"提醒由 App 自己循环播，
    /// 靠 `UIBackgroundModes: audio` 保住进程；停止入口在通知动作「已完成」、到站全屏页、
    /// 锁屏卡片的「结束」，以及 5 分钟兜底。
    private func announceArrival(stationName: String, reminder: Reminder, deferred: TimeInterval) {
        // 免打扰时段里通知被推迟了，声音也跟着推迟，否则等于绕过用户设的安静时间
        guard deferred < 2 else { return }
        let extra = reminder.title.isEmpty ? nil : reminder.title
        // 铃声与震动读「项目」自己的设置，不看全局开关
        AlarmPlaybackService.shared.startAlarm(
            stationName: stationName,
            chime: reminder.chime,
            vibrate: reminder.vibrationEnabled,
            extraSentence: extra
        )
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            defer { completionHandler() }
            let info = response.notification.request.content.userInfo
            guard let raw = info["REMINDER_ID"] as? String, let id = UUID(uuidString: raw),
                  let reminder = ReminderStore.shared.fetchReminder(withId: id) else { return }
            switch response.actionIdentifier {
            case "DONE_ACTION":
                // 项目是每天复用的通勤项：到站只结束"这一趟的声音"，
                // 不能 markDone，否则卡片会从列表里消失（用户抱怨的正是这个）。
                AlarmPlaybackService.shared.stop()
                reminder.snoozedUntil = Date().addingTimeInterval(30 * 60)
            case "WAIT_ORIGINAL_ACTION":
                reminder.alternativesDisabled = true
            case "SNOOZE_ACTION":
                reminder.snoozedUntil = Date().addingTimeInterval(30 * 60)
                scheduleSnooze(reminder)
            case UNNotificationDefaultActionIdentifier:
                // 点通知本身 → 打开 App 内的到站全屏页
                if reminder.fullScreenOnArrival {
                    NotificationCenter.default.post(name: .arrivalOpened, object: reminder.id)
                } else {
                    let lat = info["LATITUDE"] as? Double ?? reminder.latitude
                    let lon = info["LONGITUDE"] as? Double ?? reminder.longitude
                    if let url = URL(string: "http://maps.apple.com/?daddr=\(lat),\(lon)&dirflg=d") {
                        await UIApplication.shared.open(url)
                    }
                }
            case "NAVIGATE_ACTION":
                let lat = info["LATITUDE"] as? Double ?? reminder.latitude
                let lon = info["LONGITUDE"] as? Double ?? reminder.longitude
                if let url = URL(string: "http://maps.apple.com/?daddr=\(lat),\(lon)&dirflg=d") { await UIApplication.shared.open(url) }
            default: break
            }
            ReminderStore.shared.save()
            await GeofenceManager.shared.refresh(near: LocationService.shared.currentLocation)
        }
    }

    private func scheduleSnooze(_ reminder: Reminder) {
        let content = UNMutableNotificationContent()
        let stationName = reminder.placeName.isEmpty ? reminder.title : reminder.placeName
        content.title = "到站提醒 · \(stationName)"
        content.body = reminder.title.isEmpty ? "稍后提醒" : reminder.title
        content.sound = arrivalSound(for: reminder.chime)
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "arrival-alerts"
        content.categoryIdentifier = "REMINDER_CATEGORY"
        content.userInfo = ["REMINDER_ID": reminder.id.uuidString, "LATITUDE": reminder.latitude, "LONGITUDE": reminder.longitude]
        center.add(UNNotificationRequest(identifier: "\(reminder.id)-snooze", content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: 30 * 60, repeats: false)))
    }

    private func secondsUntilQuietHoursEnd() -> TimeInterval {
        let settings = SettingsStore.shared
        let now = Date()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let todayEnd = calendar.date(byAdding: .minute, value: settings.quietHoursEndMinutes, to: start) ?? now
        let end = todayEnd > now ? todayEnd : calendar.date(byAdding: .day, value: 1, to: todayEnd) ?? now
        return end.timeIntervalSince(now)
    }
}
