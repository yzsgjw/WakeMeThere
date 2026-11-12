import Foundation
import SwiftData
import CoreLocation

@Model
public final class Reminder {
    public var id: UUID = UUID()
    public var title: String = ""
    public var notes: String = ""
    public var latitude: Double = 0.0
    public var longitude: Double = 0.0
    public var placeName: String = ""
    public var placeAddress: String = ""
    public var placeProvider: String = PlaceProvider.apple.rawValue
    public var providerPlaceID: String?
    public var placeCategory: String?
    public var categoryConfidence: Double = 0
    public var triggerModeRaw: String = ReminderTriggerMode.specificPlace.rawValue
    public var alternativesDisabled: Bool = false
    public var radius: Double = 100.0 // meters
    public var triggerOnArrival: Bool = true // true = arrival, false = departure
    public var isOneTime: Bool = true
    public var isEnabled: Bool = true
    public var isCompleted: Bool = false
    public var isArchived: Bool = false
    public var createdAt: Date = Date()
    // Phase 1 Additions
    public var colorHex: String = "#007AFF"
    public var startTime: Date? = nil
    public var endTime: Date? = nil
    public var lastTriggeredAt: Date?
    public var snoozedUntil: Date?

    // MARK: - 通勤项目（Routine Plans）
    // 四个字段都带默认值 → SwiftData 走轻量迁移，老数据自动补齐。
    /// bit0 = 周日 … bit6 = 周六；默认周一~周五（62 = 0b0111110）
    public var weekdayMask: Int = 62
    /// 对应 AlarmChime.rawValue
    public var chimeName: String = AlarmChime.classic.rawValue
    public var vibrationEnabled: Bool = true
    public var fullScreenOnArrival: Bool = true

    public init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        latitude: Double,
        longitude: Double,
        placeName: String = "",
        placeAddress: String = "",
        placeProvider: PlaceProvider = .apple,
        providerPlaceID: String? = nil,
        placeCategory: PlaceCategory? = nil,
        categoryConfidence: Double = 0,
        triggerMode: ReminderTriggerMode = .specificPlace,
        radius: Double = 100.0,
        triggerOnArrival: Bool = true,
        isOneTime: Bool = true,
        isEnabled: Bool = true,
        isCompleted: Bool = false,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        lastTriggeredAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.placeAddress = placeAddress
        self.placeProvider = placeProvider.rawValue
        self.providerPlaceID = providerPlaceID
        self.placeCategory = placeCategory?.rawValue
        self.categoryConfidence = categoryConfidence
        self.triggerModeRaw = triggerMode.rawValue
        self.radius = radius
        self.triggerOnArrival = triggerOnArrival
        self.isOneTime = isOneTime
        self.isEnabled = isEnabled
        self.isCompleted = isCompleted
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.lastTriggeredAt = lastTriggeredAt
    }
    
    // MARK: - 通勤项目派生值

    /// 这个项目选的铃声
    public var chime: AlarmChime {
        AlarmChime(rawValue: chimeName) ?? .classic
    }

    /// 现在这一刻这个项目该不该响：既要是启用状态，也要落在它的星期 + 时间窗里
    public func isScheduled(at now: Date = Date(), calendar: Calendar = .current) -> Bool {
        isEnabled && !isCompleted && !isArchived &&
        PlanSchedule.isActive(
            weekdayMask: weekdayMask,
            start: startTime,
            end: endTime,
            at: now,
            calendar: calendar
        )
    }

    /// 给人看的名字：优先项目名，其次地点名。
    public var displayTitle: String {
        title.isEmpty ? (placeName.isEmpty ? "未命名项目" : placeName) : title
    }

    /// 列表行副标题用：「工作日 07:30–09:00」
    public var scheduleText: String {
        PlanSchedule.summary(weekdayMask: weekdayMask, start: startTime, end: endTime)
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public var triggerMode: ReminderTriggerMode {
        get { ReminderTriggerMode(rawValue: triggerModeRaw) ?? .specificPlace }
        set { triggerModeRaw = newValue.rawValue }
    }

    public var category: PlaceCategory? {
        get { placeCategory.flatMap(PlaceCategory.init(rawValue:)) }
        set { placeCategory = newValue?.rawValue }
    }
    
    public var regionIdentifier: String {
        id.uuidString
    }

    public func markDone() {
        isCompleted = true
        isEnabled = false
        isArchived = false
    }

    public func resume() {
        isCompleted = false
        isArchived = false
        isEnabled = true
        snoozedUntil = nil
        lastTriggeredAt = nil
    }

    public func archive() {
        isArchived = true
        isEnabled = false
    }

    public func restoreFromArchive() {
        isArchived = false
        if !isCompleted { isEnabled = true }
    }
    
    public var clRegion: CLCircularRegion {
        // iOS 对圆形围栏有硬下限：小于 100m 的区域系统不会保证触发
        // （低功耗下它靠基站/ Wi-Fi 定位判断进出，精度本来就几十米）。
        // 界面允许拖到更小，但注册时统一抬到 100m，否则就是「设了却永远不响」。
        let region = CLCircularRegion(
            center: coordinate,
            radius: max(100, radius),
            identifier: regionIdentifier
        )
        region.notifyOnEntry = triggerOnArrival
        region.notifyOnExit = !triggerOnArrival
        return region
    }
}
