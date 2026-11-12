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
            completion(granted)
        }
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
    private func arrivalSound() -> UNNotificationSound {
        let chime = AlarmChime.current
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
        content.sound = arrivalSound()
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

    /// 语音播报。前台：铃声 + 人声；后台/锁屏：只补人声（铃声已经由系统通知响过）。
    private func announceArrival(stationName: String, reminder: Reminder, deferred: TimeInterval) {
        // 免打扰时段里通知被推迟了，声音也跟着推迟，否则等于绕过用户设的安静时间
        guard deferred < 2 else { return }
        let extra = reminder.title.isEmpty ? nil : reminder.title
        if UIApplication.shared.applicationState == .active {
            AlarmPlaybackService.shared.announceArrival(stationName: stationName, extraSentence: extra)
        } else {
            AlarmPlaybackService.shared.speak(AlarmPlaybackService.arrivalSentence(stationName: stationName, extra: extra))
        }
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
                AlarmPlaybackService.shared.stop()
                reminder.markDone()
                GeofenceManager.shared.stop(reminder: reminder)
            case "WAIT_ORIGINAL_ACTION":
                reminder.alternativesDisabled = true
            case "SNOOZE_ACTION":
                reminder.snoozedUntil = Date().addingTimeInterval(30 * 60)
                scheduleSnooze(reminder)
            case "NAVIGATE_ACTION", UNNotificationDefaultActionIdentifier:
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
        content.sound = arrivalSound()
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
