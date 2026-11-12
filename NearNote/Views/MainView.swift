import SwiftUI

struct MainView: View {
    @State private var selectedTab = 0
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    /// 全 App 只剩这一个 presentation：
    /// 同一层级挂两个 presentation 修饰器（sheet + fullScreenCover）时，
    /// 弹出的表单会拿到错的命中区域 —— 键盘能点、别的全点不动，或者干脆点不开。
    /// 所以到站全屏页 / 极暗页改成 App 内覆盖层，只有编辑页还是 sheet。
    @State private var composer: ComposerTarget?
    @State private var cover: AppCover?

    var body: some View {
        ZStack {
            if hasSeenOnboarding {
                TabView(selection: $selectedTab) {
                    // 首页 = 追踪页：一屏看到「还有多少米」，灵动岛和静音保活也从这里起
                    AlightingTripView(onAdd: { composer = .create(nil) })
                        .tabItem { Label("追踪", systemImage: "location.north.line.fill") }.tag(0)
                    PlansView(
                        onAdd: { composer = .create(nil) },
                        onMap: { selectedTab = 2 },
                        onEdit: { composer = .edit($0) }
                    )
                        .tabItem { Label("项目", systemImage: "square.stack.3d.up.fill") }.tag(1)
                    MapView(
                        onAdd: { place in composer = .create(place) },
                        onEdit: { composer = .edit($0) }
                    )
                        .tabItem { Label("地图", systemImage: "map.fill") }.tag(2)
                    SettingsView()
                        .tabItem { Label("设置", systemImage: "gearshape.fill") }.tag(3)
                }
                .tint(NearNoteStyle.accent)
            } else {
                OnboardingView(hasSeenOnboarding: $hasSeenOnboarding)
            }

            if let cover {
                coverView(cover)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.easeOut(duration: 0.18), value: cover == nil)
        // 用 fullScreenCover 而不是 sheet：sheet 进来时键盘会长在独立窗口里，
        // 一旦命中区域错位就会出现"只有键盘能点"。整页推上来没有这个问题。
        .fullScreenCover(item: $composer) { target in
            switch target {
            case .create(let place):
                ReminderComposerView(initialPlace: place)
            case .edit(let id):
                if let reminder = ReminderStore.shared.fetchReminder(withId: id) {
                    ReminderComposerView(reminder: reminder)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .arrivalOpened)) { note in
            guard let id = note.object as? UUID else { return }
            cover = .arrival(id)
        }
        .onOpenURL { url in
            guard url.scheme == "arrival" else { return }
            // arrival://arrival/<uuid> → 到站全屏页；arrival://dim → 极暗页；其余 → 追踪页
            if url.host == "dim" {
                cover = .dim
                return
            }
            if url.host == "arrival",
               let raw = url.pathComponents.last,
               let id = UUID(uuidString: raw) {
                cover = .arrival(id)
            } else {
                selectedTab = 0
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func coverView(_ cover: AppCover) -> some View {
        switch cover {
        case .dim:
            DimView(onClose: { self.cover = nil })
        case .arrival(let id):
            if let reminder = ReminderStore.shared.fetchReminder(withId: id) {
                ArrivalFullScreenView(reminder: reminder, onClose: { self.cover = nil })
            } else {
                NearNoteBackground().onTapGesture { self.cover = nil }
            }
        }
    }
}

/// 编辑页的两个入口：新建（可能带着地图选好的地点）/ 编辑已有项目
private enum ComposerTarget: Identifiable {
    case create(Place?)
    case edit(UUID)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let uuid): return "edit-\(uuid.uuidString)"
        }
    }
}

/// App 内全屏覆盖层：到站页 / 极暗页
private enum AppCover: Equatable {
    case arrival(UUID)
    case dim
}

#Preview { MainView().environmentObject(LocationService.shared).environmentObject(NotificationService.shared) }
