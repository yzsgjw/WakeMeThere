import SwiftUI
import WidgetKit

// 这个扩展**只**承载 Live Activity（灵动岛 / 锁屏卡片）。
// 原项目的桌面小组件依赖 App Group 读 SwiftData，第三方签名签不过，
// 已经移除；要恢复请先重新引入 App Group。
@main
struct NearNoteWidgetBundle: WidgetBundle {
    var body: some Widget {
        ReminderActivityWidget()
    }
}
