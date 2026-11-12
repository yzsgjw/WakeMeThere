# 到站提醒 · WakeMeThere

**坐过站了吗？让它在你到站前响一声。**

一个纯本地的 iOS 到站提醒 App：选好目的地（或几个途经站），上车开始追踪，快到时手机响铃 + 语音报站，锁屏和灵动岛一直显示"还有多远"。

> 本项目是 [joeVenner/nearnotes](https://github.com/joeVenner/nearnotes) 的**二开版本（derivative work）**，不是原作者的官方发布。详见下方[二开声明](#二开声明)。

---

## 二开声明

| 项目 | 说明 |
|---|---|
| 上游原版 | [NearNote](https://github.com/joeVenner/nearnotes) —— 作者 [@joeVenner](https://github.com/joeVenner)，一个"以位置为第一维度的私人提醒 App" |
| 本仓库 | 在 NearNote 代码基础上改造成「公交/地铁到站提醒」工具，仓库地址 [yzsgjw/WakeMeThere](https://github.com/yzsgjw/WakeMeThere) |
| 关系 | 本仓库**不是**官方分叉，不隶属原作者；上游的商标、品牌、隐私政策与支持渠道归原作者所有 |
| 署名 | 感谢原作者把完整的 SwiftUI + SwiftData 位置提醒底座开源出来，本项目的地图选点、围栏调度、提醒模型、隐私教育流程均来自上游 |
| 数据与品牌 | 本版**已移除** CloudKit 云同步与 App Group，改为纯本地存储；App 名称、图标、配色、文案均为本版自己的，与上游 App Store 版本无关 |
| 许可提示 | 上游仓库未附明示的开源许可证（LICENSE 文件）。本仓库仅供个人学习与自用；若要分发、上架或商用，请先向原作者取得授权 |
| 上游资源 | 隐私政策 <https://joevenner.github.io/nearnotes/privacy/> · 支持 <https://joevenner.github.io/nearnotes/support/> · 源码 <https://github.com/joeVenner/nearnotes> |

上游页面描述的是 **NearNote 原版**的行为（含 iCloud 同步）。本版的隐私情况不同，见[隐私](#隐私)。

---

## 这个版本改了什么

面向「我坐车容易坐过站」这一个场景，把通用的地点提醒 App 收窄成一条行程流程。

**新增**

- **行程主页**：一个大号剩余距离 + 预计到达时间 + 剩余站数，一眼看完；常用提醒距离 200 m / 300 m / 500 m / 1 km / 2 km 一键切换。
- **多站接力**：一次排多个途经站，按顺序跟踪，一站到了自动切下一站（队列可拖拽、可删除、可指定"设为下一站"）。
- **到站发声**：1.16 秒双音提示音（`AlarmChime.wav`）+ 中文语音播报「前方到站，XX，请准备下车」。先响铃后说话，不叠在一起。
- **灵动岛 / 锁屏实时卡片**：环形进度 + 剩余距离 + ETA + "第 x/y 站"，多站切换时**不重建卡片**，只更新状态，所以不会闪。
- **静音保活**：追踪期间用一段全零音频维持播放会话，让 App 不被系统挂起（否则围栏触发后只剩一条通知，语音和多站接力都跑不了）。混音模式，**不影响你听歌、刷视频**。
- **预计到达时间**：`MKDirections` 算驾车路线时长，90 秒刷新一次，断网时用距离/平均车速兜底估算，绝不空着。
- **时间敏感通知**：`interruptionLevel = .timeSensitive`，专注模式下也能穿透（这一项不需要 Apple 审批）。

**移除 / 替换**

- CloudKit 云同步、App Group 共享容器、桌面小组件、App Intents 快捷指令 —— 为了能自由签名安装，全部剥离，改纯本地单机。
- 原作者的后台服务端点（Telemetry / Feedback / Google Places 密钥）全部留空，默认零联网。
- 原版四页导航（Nearby / Map / Reminders / Settings）改为 行程 / 地图 / 站点 / 设置。
- 视觉系统整体重做：深色 + 单一强调蓝（`#3B7DFF`）+ SF Rounded 数字，形状半径统一为 22 / 14 / 18。

---

## 功能现状

| 能力 | 状态 |
|---|---|
| 地图选点、搜索、粘贴地图链接 | ✅ |
| 全中文界面 | ✅ 行程 / 地图 / 提醒 / 设置 / 引导 / 权限页全部中文，单一强调色 #3B7DFF |
| 地图拖拽选点 + 提醒半径实时预览 + 收藏地点 | ✅ |
| CLCircularRegion 系统围栏（后台/被回收可唤醒） | ✅ |
| 自定义提醒半径、每站独立半径 | ✅ |
| 本地通知 + 自定义铃声 + 中文语音 | ✅ |
| 多站队列与接力（到站自动切下一站） | ✅ |
| 灵动岛 / 锁屏实时状态 | ✅ |
| ETA 自动刷新 | ✅ |
| 静音保活、追踪状态持久化 | ✅ |
| 地图页叠加围栏圈 | ✅ 每个提醒的半径圆直接画在地图上，一眼看出盖住哪几条街 |
| GPS 信号质量展示（防漂移） | ⬜ 待做 |
| 行程分享 / 导出 | ⬜ 待做 |
| Siri / 快捷指令 | ⬜ 待做 |
| 多铃声选择 UI | ⬜ 待做 |

---

## 快速开始

需要 Xcode 16+、iOS 17+ 的构建环境（开发机为 Windows，实际编译在 GitHub Actions 上跑）。

```sh
brew install xcodegen      # 只有需要重新生成工程时
xcodegen generate
open NearNote.xcodeproj
```

命令行编译：

```sh
xcodebuild build \
  -project NearNote.xcodeproj -scheme NearNote \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

工程标识：

| 项 | 值 |
|---|---|
| Bundle ID（主 App） | `com.wayzs999.arrival` |
| Bundle ID（灵动岛扩展） | `com.wayzs999.arrival.widget` |
| 显示名 | 到站提醒 |
| 版本 | 0.1.0 |

---

## 构建与安装（无 Mac 路线）

`.github/workflows/ios-build.yml` 在每次推送 `main` 时自动编译，产出**未签名 ipa** 作为 Actions artifact（`NearNote-unsigned-<run_number>`）。纯文档提交不触发。

用第三方签名平台重签时注意两点：

1. ipa 里含 `Payload/NearNote.app/PlugIns/NearNoteWidgetExtension.appex`，**必须和主 App 用同一张证书一起签**，否则装上就闪退、灵动岛也不会出现。
2. 扩展的 Bundle ID 必须是主 App 的前缀 + `.widget`，改主 App ID 时要一起改。

将来有开发者账号后，`.github/workflows/testflight.yml` 可直接上传 TestFlight，需要四个 secrets：`APPLE_TEAM_ID`、`APP_STORE_CONNECT_KEY_ID`、`APP_STORE_CONNECT_ISSUER_ID`、`APP_STORE_CONNECT_KEY_P8_BASE64`。

开发与排错细节（改造清单、CI 踩坑、签名问题）见 [README-DEV.md](README-DEV.md)。

---

## 隐私

**这一版不联网、不登录、不上传。**

- 提醒、站点、坐标、偏好全部存在设备本地的 SwiftData 数据库里；**没有** iCloud / CloudKit 同步，卸载即消失。
- 没有账号系统、没有自建后端、没有统计 SDK、没有广告标识符。
- 位置只用于：按距离排序、地图选点、以及交给 iOS 的围栏服务在到站时唤醒 App。不积累、不上传位置轨迹。
- 通知全部是本机 `UNNotification`，不经推送服务器。
- 地图渲染与地址搜索默认走 Apple MapKit；若你主动粘贴 Google Maps / Waze 短链，App 会请求该服务解析坐标，此时遵守对方隐私政策。
- 上游原版（含 iCloud 同步）的隐私政策：<https://joevenner.github.io/nearnotes/privacy/> —— 供对照参考，本版行为以上面几条为准。

---

## 已知的 iOS 硬限制

这些不是实现问题，是系统行为，先说清楚免得白等：

1. **手动上滑划掉 App 后，围栏不会再唤醒它。** 后台、锁屏、被系统因内存压力回收——这些都能触发；用户主动强杀不行。
2. **静音拨片能吃掉通知铃声，但吃不掉 App 自己播的声音。** 保活成立时，响铃与语音在静音模式下照样出声；若 App 被系统回收，那一刻只剩通知，静音就真静音了。
3. **围栏最小半径 100 m。** 更小的值会被静默忽略，所以提醒距离从 200 m 起。
4. **最多同时监控 20 个围栏。** 本项目按距离排序取最近的一批，站再多也只盯最近的 20 个。
5. **围栏触发有延迟**，远距离围栏可能晚几十秒到几分钟；这是为了省电换来的。
6. **保活要耗电**，追踪期间约 1~2%/小时，所以只在「开始追踪 → 结束追踪」之间运行。

---

## 技术栈与目录

SwiftUI · SwiftData · ActivityKit（灵动岛）· CoreLocation 围栏 · MapKit（路线/ETA）· AVFoundation（铃音与语音）· XcodeGen 管理工程。

```
NearNote/
  Models/        Reminder、SavedPlace、ReminderActivityAttributes（App 与扩展共用）
  Services/      ReminderStore、GeofenceManager、LocationService、NotificationService、
                 LiveActivityService、RouteETAService、AlarmPlaybackService、AudioKeepAliveService
  Views/         Trip/（行程主页）、MapView、HomeView、ReminderEditSheet、SettingsView、Components/
  Resources/     AlarmChime.wav
NearNoteWidget/  ReminderActivityWidget（灵动岛 / 锁屏卡片）、NearNoteWidgetBundle
NearNoteTests/   单元测试
.github/workflows/  ios-build.yml（未签名 ipa）、testflight.yml（可选）
```

---

## 致谢

上游 [NearNote](https://github.com/joeVenner/nearnotes) 的作者 [@joeVenner](https://github.com/joeVenner) 把一整套做得相当完整的位置提醒 App 放在了 GitHub 上——围栏调度、隐私教育、地图选点、SwiftData 模型这些难点都是现成的，本项目只是把它掰向一个更窄的用途。原作者的支持渠道与隐私政策见上方二开声明。
