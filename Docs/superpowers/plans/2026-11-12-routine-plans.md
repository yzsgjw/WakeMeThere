# 通勤项目（Routine Plans）实施计划

> **For agentic workers:** 本计划按任务顺序执行，每个任务单独提交。步骤用 `- [ ]` 跟踪。

**Goal:** 用「通勤项目」（名字 + 目的地 + 半径 + 星期 + 时间段 + 铃声 + 震动 + 开关）替换站点队列，列表按开关分「进行中 / 未进行」。

**Architecture:** 不新建模型——在既有 SwiftData `Reminder` 上加四个带默认值的字段，复用现有围栏/通知/铃声管线。新增一个纯函数模块 `PlanSchedule` 负责「星期 + 时间窗」判定，配单元测试。UI 把「站点」tab 换成「项目」列表，编辑页就地扩展。

**Tech Stack:** SwiftUI / SwiftData / CoreLocation / UserNotifications / ActivityKit / XCTest

**Spec:** `Docs/superpowers/specs/2026-11-12-routine-plans-design.md`

## Global Constraints

- 部署目标 iOS 17.0；只用系统框架，不引入任何第三方依赖。
- 围栏最小半径 100 m；最多 20 个同时注册。
- 全中文界面文案；颜色/字体只能来自 `NearNoteStyle`。
- SwiftData 只能加带默认值的字段。
- 本机无 Xcode：编译与测试的唯一验证通道是 GitHub Actions。

## Review Focus

- 跨零点时间窗（23:00–01:00）不能被判成"不在窗口内"。
- `weekdayMask == 0`（用户全不选）应当视为"每天"还是"永不生效"——取"每天"，并在编辑页强制至少选一天。
- 项目 `isEnabled == false` 时不得注册围栏，切开关后必须立刻重注册。
- 到达阈值附近的抖动不能因为新增的星期判断而变成"永不触发"。
- 通知/铃声/震动三者必须读**项目自身**字段，不能被全局设置覆盖。

---

### Task 1: PlanSchedule（星期 + 时间窗判定）

**Files:**
- Create: `NearNote/Services/PlanSchedule.swift`
- Test: `NearNoteTests/PlanScheduleTests.swift`

**Interfaces:**
- Produces:
  - `enum PlanSchedule { static func isActive(weekdayMask: Int, start: Date?, end: Date?, at now: Date, calendar: Calendar) -> Bool }`
  - `static func weekdayBits(from date: Date, calendar: Calendar) -> Int`（返回 `1 << (weekday - 1)`）
  - `static func maskText(_ mask: Int) -> String`（"每天" / "周一~五" / "周一、周三"）
- 语义：`weekdayMask == 0` 视为每天；`start`/`end` 都为 nil 视为全天；`start > end` 视为跨零点。

- [ ] Step 1: 写失败测试 `NearNoteTests/PlanScheduleTests.swift`，覆盖：普通窗口命中/未命中、跨零点窗口两端、mask=0、mask 只含周末、hour 边界取闭区间。
- [ ] Step 2: CI 跑 `xcodebuild test`，确认新测试失败（`PlanSchedule` 未定义）。
- [ ] Step 3: 实现 `PlanSchedule`（纯函数，无状态，不依赖 CoreLocation）。
- [ ] Step 4: CI 测试通过。
- [ ] Step 5: 提交。

### Task 2: Reminder 加字段

**Files:** Modify `NearNote/Models/Reminder.swift`

**Interfaces:** 新增 `weekdayMask: Int = 62`、`chimeName: String = AlarmChime.classic.rawValue`、`vibrationEnabled: Bool = true`、`fullScreenOnArrival: Bool = true`。

- [ ] Step 1: 加四个 `public var`（带默认值，SwiftData 轻量迁移）。
- [ ] Step 2: CI 构建通过。
- [ ] Step 3: 提交。

### Task 3: 铃声与震动下沉到项目

**Files:** Modify `NearNote/Services/AlarmPlaybackService.swift`、`NearNote/Services/NotificationService.swift`

**Interfaces:**
- `AlarmPlaybackService.announceArrival(stationName:chime:vibrate:extraSentence:)`
- `NotificationService.arrivalSound(for chime: AlarmChime)`
- 震动用 `AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)`，只在 `vibrate == true` 时触发。

- [ ] Step 1: 播放器与通知改读项目字段，保留旧签名重载指向新实现。
- [ ] Step 2: CI 构建通过。
- [ ] Step 3: 提交。

### Task 4: 围栏接入 PlanSchedule

**Files:** Modify `NearNote/Services/GeofenceManager.swift`

- [ ] Step 1: `refresh` 只注册 `isEnabled && isActive(now)`… 改为：注册全部启用项目（见 spec「围栏注册策略 A」）。
- [ ] Step 2: `handle(region:)` 在到站复核前加 `guard PlanSchedule.isActive(...)`。
- [ ] Step 3: CI 构建通过。
- [ ] Step 4: 提交。

### Task 5: 项目列表页

**Files:** Create `NearNote/Views/Plans/PlansView.swift`；Modify `NearNote/Views/MainView.swift`

- [ ] Step 1: 列表按 `isEnabled` 分两组，行内 Toggle + 摘要（目的地/半径/星期/时间/铃声/震动）。
- [ ] Step 2: 点击进编辑页，左滑删除，底部「新建项目」。
- [ ] Step 3: `MainView` 改为 项目 / 地图 / 设置 三个 tab，撤掉行程页入口。
- [ ] Step 4: CI 构建通过 → 提交。

### Task 6: 编辑页扩展

**Files:** Modify `NearNote/Views/ReminderEditSheet.swift`

- [ ] Step 1: 加星期多选 chips（默认周一~五，至少选一天）、时间段 DatePicker、铃声 Picker + 试听、震动 Toggle、全屏到站 Toggle。
- [ ] Step 2: 保存时写回四个新字段。
- [ ] Step 3: CI 构建通过 → 提交。

### Task 7: 地图选点直径滑杆

**Files:** Modify `NearNote/Views/MapPickerView.swift`

- [ ] Step 1: 底部加 100–4000 m 直径滑杆，`MapCircle` 实时缩放，显示"直径 X 米 · 半径 Y 米"。
- [ ] Step 2: 确认时把半径写回。
- [ ] Step 3: CI 构建通过 → 提交。

### Task 8: 全屏到站页

**Files:** Create `NearNote/Views/Arrival/ArrivalFullScreenView.swift`；Modify `NearNote/Views/MainView.swift`、`NearNote/Services/NotificationService.swift`

- [ ] Step 1: 全屏页（站名 / 距离 / 「我到了」「稍后再提醒」/ 响铃状态）。
- [ ] Step 2: deep link `arrival://arrival/<uuid>` 路由到 fullScreenCover。
- [ ] Step 3: App 在前台时由围栏事件直接弹出。
- [ ] Step 4: CI 构建通过 → 提交。

### Task 9: 文档与收尾

- [ ] Step 1: README 功能表与 ROADMAP 更新。
- [ ] Step 2: 提交。
