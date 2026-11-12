# 开发交接说明

> 站下车提醒 App。底座来自 [joeVenner/nearnotes](https://github.com/joeVenner/nearnotes)，已做「可签名 + 纯本地」改造。
> 本地开发机是 Windows，**没有 macOS**，所以：代码在 Windows 上写，编译验证与打包全部由 GitHub Actions 完成。

---

## 1. 当前状态

底座已克隆并完成改造，**编译已在 GitHub Actions 上验证通过**（`macos-15` + XcodeGen，产物是 9.45MB 未签名 ipa，内含 Widget 扩展；build.log 零警告）。

| 改造项 | 说明 |
|---|---|
| 剥离 CloudKit | `ReminderStore.swift` 的 `cloudKitDatabase: .automatic` → `.none` |
| 剥离 App Group | `groupContainer: .identifier("group.com.mosaab.NearNote")` → `.none` |
| 清空 entitlements | `NearNote/NearNote.entitlements` 置空，不再引用 iCloud / App Group |
| 移除原作者身份 | `project.yml` 删掉 `DEVELOPMENT_TEAM: 7877JLKPRQ` |
| 换 Bundle ID | `com.mosaab.NearNote` → `com.wayzs999.arrival`（可改，见下） |
| 换显示名 | `NearNotes` → `到站提醒` |
| 权限文案中文化 | 三条 `NSLocation*UsageDescription` |
| 补后台权限 | `Info.plist` 新增 `UIBackgroundModes: [audio, location]`（语音播报需要） |
| 重建 Widget 扩展 | 只保留 Live Activity（灵动岛必须在扩展里）；桌面小组件依赖 App Group，已删除 |
| 只出 iPhone 版 | `TARGETED_DEVICE_FAMILY: 1` |

**已有**：行程主页（`Views/Trip/AlightingTripView.swift`）、灵动岛 / 锁屏实时活动、驾车 ETA、新设计系统（`Views/Components/NearNoteStyle.swift`）。
**尚未做**：多站点自动接力、语音播报、自定义铃声 —— 见第 5 节阶段计划。

---

## 2. 推送到你自己的仓库

### 2.1 一次性配置

**已经配好了**，仓库是 https://github.com/yzsgjw/WakeMeThere ，`origin` 指向它、`upstream` 指向原作者仓库。

当初踩的两个坑，换机器重配时会再遇到，记在这里：

1. **token 必须有 `workflow` scope**。只有 `repo` 时 GitHub 拒绝推送 `.github/workflows/` 下任何文件，报
   `refusing to allow a Personal Access Token to create or update workflow ... without workflow scope`。
   去 https://github.com/settings/tokens 勾上 `workflow` 再 push。
2. **浅克隆推不上去**。`--depth 1` 克隆出来的仓库 push 时报
   `remote: fatal: did not receive expected object ...` / `remote unpack failed`。
   先 `git fetch --unshallow upstream` 补全历史（约 1 分钟）再推。
3. 仓库创建时勾了 README 的话，远端会有一个 `Initial commit`，和本地历史无关；用
   `git push --force-with-lease=main:<远端sha> ...` 覆盖掉即可（两边历史无共同祖先，`git pull` 会拒绝合并）。

原始项目保留在 `upstream` 远端，方便以后同步作者的上游修复：

```bash
git fetch upstream
git log upstream/main --oneline -10
```

### 2.2 每次推送

```bash
git add -A
git commit -m "说明这次改了什么"
git push -u origin main
```

推上去之后 GitHub Actions 会自动跑 `iOS Build (unsigned ipa)`，约 5~10 分钟。

---

## 3. 编译验证怎么看

打开仓库的 **Actions** 标签页：

- ✅ 绿色 → 代码能过编译，在本次运行的 **Artifacts** 里下载 `NearNote-unsigned-<序号>`，里面是 `NearNote-unsigned.ipa`
- ❌ 红色 → 下载 `build-log-<序号>`，里面是完整 `xcodebuild` 日志。把这个日志贴给我，我按报错改

**这是唯一的编译反馈通道**，所以改动要小步提交，不要一次堆几百行再看结果。

几个读日志的常识：

- 命令带 `-quiet`，**成功时 `build.log` 是空的**（空 ≠ 出错）。判断成败看绿色对勾，不要 grep 文件内容。
- 失败时 `build.log` 里只有 `error:` / `warning:` 行，定位靠 `文件:行:列`，比在 Xcode 里翻更快。
- 只改 `.md` / `Docs/` / `site/` 不会触发构建（`paths-ignore` 已配）。
- 一次成功构建 ≈ 2 分钟（`macos-15` 冷启动 + XcodeGen + 全量 swiftc）。

历史验证记录：run [#43181875503](https://github.com/yzsgjw/WakeMeThere/actions/runs/43181875503) 首次全绿；
随后修掉唯一一条警告（widget 扩展版本号 `1.0` 与主 App `0.1.0` 不一致）后 run `43182391020` 零警告。

---

## 4. 装到 iPhone 的两条路

### 路线 A：第三方签名平台（现在就能用，¥10~30/次）

1. 从 CI 的 Artifacts 下载 `NearNote-unsigned.ipa`
2. 上传到你选的企业签名平台
3. 平台返回已签名包，用手机浏览器下载安装
4. 首次安装后到 **设置 → 通用 → VPN与设备管理** 里信任该证书

**风险（已知并接受）**：证书被苹果吊销后 App 会直接闪退打不开，且没有任何预警，只能重新签。适合验证功能，不适合长期日常使用。

### 路线 B：付费开发者账号 + TestFlight（¥688/年，推荐长期用）

一次性准备：

1. 注册 Apple Developer Program，记下 **Team ID**
2. App Store Connect → 用户与访问 → 集成 → 生成 **App Store Connect API Key**，下载 `.p8`（只能下载一次）
3. 在 GitHub 仓库 Settings → Secrets and variables → Actions 里加 4 个 secret：

| Secret 名 | 值 |
|---|---|
| `APPLE_TEAM_ID` | 10 位 Team ID |
| `APP_STORE_CONNECT_KEY_ID` | API Key 的 Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID |
| `APP_STORE_CONNECT_KEY_P8_BASE64` | `.p8` 文件内容的 Base64 |

生成 Base64（在有 Python 的机器上）：

```bash
python -c "import base64;print(base64.b64encode(open(r'AuthKey_XXXX.p8','rb').read()).decode())"
```

之后每次发版：Actions → **Upload to TestFlight** → Run workflow，等 20 分钟左右，手机上的 TestFlight 就会出现新版本。**全程不需要 Mac。**

---

## 5. 阶段计划

### 阶段 1：单站跑通（底座基本已有，需验收）

底座已经具备：地图选点、地点搜索、围栏创建、本地通知、SwiftData 持久化。
剩下要做的是**简化 UI 到「起点→目的地→提醒距离→开始追踪」**这一条主线。

- [ ] 推一次 CI，确认编译通过
- [ ] 真机验证：设置一个目的地 → 锁屏放到后台 → 走进半径内 → 收到通知
- [ ] 确认围栏半径下拉（1km / 2km / 3km）与 `Reminder.radius` 打通

**验收**：App 在后台/被系统回收/几天没打开的情况下，进入半径能收到通知。
（**注意**：手动上滑划掉 App 后不再触发，这是 iOS 行为，不是 bug。）

### 阶段 2：到站提醒体验

- [ ] `AVSpeechSynthesizer` 语音播报「即将到达 XXX」
- [ ] `AVAudioSession` 配 `.playback` + 后台 audio 权限（`Info.plist` 已加），确保耳机内出声
- [ ] 自定义铃声：`UNNotificationSound(named:)`，音频放 bundle，≤30 秒
- [ ] `MKDirections` 算 ETA，定时刷新显示「预计 12 分钟」
- [ ] UI 重做成截图那种简约蓝

**验收**：点开始追踪 → 页面显示预计时间 → 到距离自动通知 + 语音播报。

**做不到的**：静音键打开时普通通知不会响。唯一穿透方式是 Critical Alerts，需要 Apple 单独审批，个人账号拿不到。方案是引导用户关静音 + 靠语音播报。

### 阶段 3：多站接力（核心难点）

- [ ] 站点队列数据模型（SwiftData 新建 `Trip` / `TripStop`）
- [ ] 站点列表：添加、删除、拖拽排序
- [ ] 接力引擎：只监听当前站 → 触发后关掉当前围栏、开下一站围栏 → 全部完成结束
- [ ] 每站独立提醒距离
- [ ] 追踪状态持久化，App 重启后恢复

**验收**：设 2 个站，第 1 站提醒后自动开始听第 2 站。

### 阶段 4：打磨

- [ ] 防抖：连续 2~3 次定位都在圈内才判定到达，避免信号跳变误触发
- [ ] 灵动岛显示剩余距离 / ETA（`LiveActivityService` 已有基础）
- [ ] 地图画驾车路线
- [ ] 驾车 / 公交切换

### 阶段 5：可选

历史行程、快捷指令、导出导入、暂停/停止追踪。

---

## 6. 已知 iOS 限制（写需求时不要违背）

1. **手动划掉 App → 围栏不触发**，直到重新打开 App。系统级行为，无法绕过。
2. **静音键会屏蔽普通通知**，只有 Critical Alerts 能穿透（需 Apple 审批）。
3. **围栏最小半径 100 米**，小于 100m 系统静默忽略；`Reminder.radius` 默认就是 100。
4. **同时最多 20 个围栏**。`GeofenceManager.refresh` 已按距离排序取前 20，多站接力时要复用这套裁剪逻辑。
5. **远距离围栏有延迟**：2~3km 的围栏触发可能延迟几十秒到几分钟，系统按功耗策略决定采样频率。
6. **围栏是直线距离**，不是道路里程。想要「沿路剩余 2 公里提醒」只能持续前台定位 + 路网计算，耗电极大且锁屏易失效，不建议做。

---

## 7. 关键文件地图

```
app/
├── project.yml                      XcodeGen 配置（改 bundle id / 版本号 / 编译设置看这里）
├── .github/workflows/
│   ├── ios-build.yml                出未签名 ipa + 编译验证（主力）
│   ├── testflight.yml               传 TestFlight（需 4 个 secret）
│   └── pages.yml                    上游的隐私政策页，可忽略
├── NearNote/
│   ├── Info.plist                   权限文案、后台模式、显示名
│   ├── NearNote.entitlements        已清空（别加回 iCloud/App Group）
│   ├── NearNoteApp.swift            入口，三个单例在这里初始化
│   ├── Models/
│   │   ├── Reminder.swift           单条提醒（含 radius / clRegion）
│   │   ├── Place.swift              地点 + 分类枚举
│   │   ├── SavedPlace.swift
│   │   └── ReminderLiveActivityData.swift
│   ├── Services/
│   │   ├── ReminderStore.swift      SwiftData 容器（本地）
│   │   ├── GeofenceManager.swift    ★ 围栏核心：刷新、20 上限、进出触发、时间窗、冷却
│   │   ├── LocationService.swift    定位与权限
│   │   ├── NotificationService.swift 本地通知 + 通知动作
│   │   ├── PlaceSearchService.swift MapKit 搜索（Google 未配置时自动回退）
│   │   ├── LiveActivityService.swift 灵动岛
│   │   └── ...
│   └── Views/                       Home / Map / ReminderEditSheet / Settings / Onboarding
├── NearNoteWidget/                  Widget 扩展：只做灵动岛 / 锁屏实时活动
└── site/                            上游静态页，可忽略
```

---

## 8. 灵动岛 / Live Activity

一次行程 = 一条 Live Activity，三个位置共用同一份 `ContentState`：

| 位置 | 文件 | 说明 |
|---|---|---|
| 灵动岛（紧凑 / 最小 / 展开） | `NearNoteWidget/ReminderActivityWidget.swift` | `DynamicIsland { ... }` |
| 锁屏卡片 | 同上（`TripLockScreenView`） | 点它回 App，走 `arrival://trip` |
| App 内 | `NearNote/Views/Trip/AlightingTripView.swift` | 页首大号剩余距离 |

改之前先读这五条：

1. `NearNote/Models/ReminderActivityAttributes.swift` 被 **App 和 Widget 两个 target 同时编译**，所以只许 import `ActivityKit` / `Foundation`，**不要** import SwiftData。
2. 站点信息放 `ContentState`、不放 attributes：多站接力换下一站时只改 state，Live Activity 实例不重建 → 灵动岛不闪，也不撞 iOS 更新频率限制。
3. `attributes.stationIDs` 存站点顺序、`ContentState.stationIndex` 存当前位置；App 被系统回收后重开靠这两个字段恢复"现在在第几站"。
4. 更新有节流：距离变化 < 3% 且阶段没变就不推送（`LiveActivityService.update`）。iOS 对 Live Activity 更新有预算，别改成每秒推。
5. 配色在 widget 里另存了一份 `private enum Ink` —— widget target 编译不到 `NearNoteStyle`。**改主色时两边都要改**。

实测路径（iPhone 15 Pro Max / iOS 18.3.2）：设置 → 本 App → 确认「实时活动」为开 → 加 1~2 个站点 → 开始追踪 → 回主屏看紧凑态 → 长按看展开态 → 锁屏看卡片。

已知限制：

- 灵动岛只在「开始追踪」后出现，结束追踪立刻消失。
- 第三方重签时 `.appex` 必须和主 App 用同一张证书。重签平台若只签主 App，`PlugIns/NearNoteWidgetExtension.appex` 就废了 —— 表现是装得上但灵动岛不显示，或启动即闪退。

---

## 9. 待确认

- [ ] App 名字最终叫什么（现在是 `到站提醒`，改 `NearNote/Info.plist` 的 `CFBundleDisplayName` 一行）
- [ ] Bundle ID 最终用哪个（现在是 `com.wayzs999.arrival`，改 `project.yml` 一行）
- [ ] 阶段 2 的 UI 截图（Arrival 那张），发我才能对齐视觉
