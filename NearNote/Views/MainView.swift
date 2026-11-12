import SwiftUI

struct MainView: View {
    @State private var selectedTab = 0
    @State private var showComposer = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var composerPlace: Place?
    // 只留一个 fullScreenCover：同一层级挂两个 presentation 修饰器时，
    // 弹出的 sheet 会拿到错误的点击区域（键盘能点、别的全点不动），这是个真机上会复现的坑。
    @State private var cover: AppCover?

    var body: some View {
        Group {
            if hasSeenOnboarding {
                TabView(selection: $selectedTab) {
                    // 首页 = 追踪页：一屏看到「还有多少米」，灵动岛和静音保活也从这里起
                    AlightingTripView(onAdd: { showComposer = true })
                        .tabItem { Label("追踪", systemImage: "location.north.line.fill") }.tag(0)
                    PlansView(onAdd: { showComposer = true }, onMap: { selectedTab = 2 })
                        .tabItem { Label("项目", systemImage: "square.stack.3d.up.fill") }.tag(1)
                    MapView(onAdd: { place in
                        composerPlace = place
                        showComposer = true
                    })
                        .tabItem { Label("地图", systemImage: "map.fill") }.tag(2)
                    SettingsView()
                        .tabItem { Label("设置", systemImage: "gearshape.fill") }.tag(3)
                }
                .tint(NearNoteStyle.accent)
                // sheet 挂在 TabView 上，别和外面的 fullScreenCover 挂在同一层：
                // 同一层挂两个 presentation 修饰器时，sheet 里的键盘会拿到错的点击区域。
                .sheet(isPresented: $showComposer, onDismiss: { composerPlace = nil }) {
                    ReminderComposerView(initialPlace: composerPlace)
                }
            } else {
                OnboardingView(hasSeenOnboarding: $hasSeenOnboarding)
            }
        }
        .fullScreenCover(item: $cover) { target in
            switch target {
            case .dim:
                DimView()
            case .arrival(let id):
                if let reminder = ReminderStore.shared.fetchReminder(withId: id) {
                    ArrivalFullScreenView(reminder: reminder)
                } else {
                    NearNoteBackground()
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
}

/// fullScreenCover(item:) 的载荷：到站全屏页 / 极暗页，共用一个覆盖层
private enum AppCover: Identifiable {
    case arrival(UUID)
    case dim

    var id: String {
        switch self {
        case .arrival(let uuid): return "arrival-\(uuid.uuidString)"
        case .dim: return "dim"
        }
    }
}

#Preview { MainView().environmentObject(LocationService.shared).environmentObject(NotificationService.shared) }
