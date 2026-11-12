import XCTest
@testable import NearNote

/// 通勤项目的生效时段判定。纯函数，不需要模拟器能力，CI 上跑 `xcodebuild test`。
final class PlanScheduleTests: XCTestCase {

    /// 固定日历：不依赖跑测试那台机器的时区/区域设置
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        c.locale = Locale(identifier: "zh_CN")
        return c
    }()

    /// 2026-11-12 是星期四
    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 11
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        return calendar.date(from: comps)!
    }

    private func window(_ sh: Int, _ sm: Int, _ eh: Int, _ em: Int) -> (Date, Date) {
        (date(12, sh, sm), date(12, eh, em))
    }

    // MARK: - 普通窗口

    func testInsideWeekdayWindow() {
        let (start, end) = window(7, 30, 9, 0)
        XCTAssertTrue(PlanSchedule.isActive(
            weekdayMask: PlanSchedule.weekdaysMask, start: start, end: end,
            at: date(12, 8, 0), calendar: calendar))
    }

    func testAfterWindowOnWeekday() {
        let (start, end) = window(7, 30, 9, 0)
        XCTAssertFalse(PlanSchedule.isActive(
            weekdayMask: PlanSchedule.weekdaysMask, start: start, end: end,
            at: date(12, 9, 30), calendar: calendar))
    }

    func testWindowExcludesWeekend() {
        let (start, end) = window(7, 30, 9, 0)
        // 2026-11-14 是星期六
        XCTAssertFalse(PlanSchedule.isActive(
            weekdayMask: PlanSchedule.weekdaysMask, start: start, end: end,
            at: date(14, 8, 0), calendar: calendar))
    }

    func testWindowBoundariesAreInclusive() {
        let (start, end) = window(7, 30, 9, 0)
        XCTAssertTrue(PlanSchedule.isActive(
            weekdayMask: PlanSchedule.weekdaysMask, start: start, end: end,
            at: date(12, 7, 30), calendar: calendar))
        XCTAssertTrue(PlanSchedule.isActive(
            weekdayMask: PlanSchedule.weekdaysMask, start: start, end: end,
            at: date(12, 9, 0), calendar: calendar))
    }

    // MARK: - 空掩码与空窗口

    func testZeroMaskMeansEveryDay() {
        let (start, end) = window(7, 30, 9, 0)
        XCTAssertTrue(PlanSchedule.isActive(
            weekdayMask: 0, start: start, end: end,
            at: date(14, 8, 0), calendar: calendar))
    }

    func testNilWindowMeansAllDay() {
        XCTAssertTrue(PlanSchedule.isActive(
            weekdayMask: PlanSchedule.weekdaysMask, start: nil, end: nil,
            at: date(12, 3, 0), calendar: calendar))
        XCTAssertFalse(PlanSchedule.isActive(
            weekdayMask: PlanSchedule.weekendMask, start: nil, end: nil,
            at: date(12, 3, 0), calendar: calendar))
    }

    // MARK: - 跨零点

    func testCrossMidnightBeforeMidnight() {
        let (start, end) = window(23, 0, 1, 0)
        XCTAssertTrue(PlanSchedule.isActive(
            weekdayMask: PlanSchedule.weekdaysMask, start: start, end: end,
            at: date(12, 23, 30), calendar: calendar))
    }

    func testCrossMidnightAfterMidnightUsesPreviousDay() {
        let (start, end) = window(23, 0, 1, 0)
        // 2026-11-13 星期五的 00:30 属于星期四那一段
        XCTAssertTrue(PlanSchedule.isActive(
            weekdayMask: PlanSchedule.weekdaysMask, start: start, end: end,
            at: date(13, 0, 30), calendar: calendar))
    }

    func testCrossMidnightAfterMidnightRejectsNonWorkingDay() {
        let (start, end) = window(23, 0, 1, 0)
        // 2026-11-15 星期日 00:30 → 前一天是星期六，工作日项目不该生效
        XCTAssertFalse(PlanSchedule.isActive(
            weekdayMask: PlanSchedule.weekdaysMask, start: start, end: end,
            at: date(15, 0, 30), calendar: calendar))
    }

    func testCrossMidnightMiddleOfDayIsInactive() {
        let (start, end) = window(23, 0, 1, 0)
        XCTAssertFalse(PlanSchedule.isActive(
            weekdayMask: PlanSchedule.weekdaysMask, start: start, end: end,
            at: date(12, 12, 0), calendar: calendar))
    }

    // MARK: - 文案

    func testMaskText() {
        XCTAssertEqual(PlanSchedule.maskText(PlanSchedule.everyDayMask), "每天")
        XCTAssertEqual(PlanSchedule.maskText(0), "每天")
        XCTAssertEqual(PlanSchedule.maskText(PlanSchedule.weekdaysMask), "工作日")
        XCTAssertEqual(PlanSchedule.maskText(PlanSchedule.weekendMask), "周末")
        XCTAssertEqual(PlanSchedule.maskText(1 << 3), "周三")
        XCTAssertEqual(PlanSchedule.maskText((1 << 3) | (1 << 5)), "周三、周五")
    }

    func testSummary() {
        let (start, end) = window(7, 30, 9, 0)
        XCTAssertEqual(
            PlanSchedule.summary(weekdayMask: PlanSchedule.weekdaysMask, start: start, end: end, calendar: calendar),
            "工作日 07:30–09:00")
        XCTAssertEqual(PlanSchedule.summary(weekdayMask: PlanSchedule.everyDayMask, start: nil, end: nil, calendar: calendar), "每天")
    }
}
