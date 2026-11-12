import SwiftUI

struct MainView: View {
    @State private var selectedTab = 0
    @State private var showComposer = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var composerPlace: Place?
    @State private var arrivalTarget: ArrivalTarget?
    @State private var showDim = false

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
            } else {
                OnboardingView(hasSeenOnboarding: $hasSeenOnboarding)
            }
        }
        .sheet(isPresented: $showComposer, onDismiss: { composerPlace = nil }) {
            ReminderComposerView(initialPlace: composerPlace)
        }
        .fullScreenCover(item: $arrivalTarget) { target in
            if let reminder = ReminderStore.shared.fetchReminder(withId: target.id) {
                ArrivalFullScreenView(reminder: reminder)
            } else {
                NearNoteBackground()
            }
        }
        .fullScreenCover(isPresented: $showDim) { DimView() }
        .onReceive(NotificationCenter.default.publisher(for: .arrivalOpened)) { note in
            guard let id = note.object as? UUID else { return }
            arrivalTarget = ArrivalTarget(id: id)
        }
        .onOpenURL { url in
            guard url.scheme == "arrival" else { return }
            // arrival://arrival/<uuid> → 到站全屏页；arrival://dim → 极暗页；其余 → 追踪页
            if url.host == "dim" {
                showDim = true
                return
            }
            if url.host == "arrival",
               let raw = url.pathComponents.last,
               let id = UUID(uuidString: raw) {
                arrivalTarget = ArrivalTarget(id: id)
            } else {
                selectedTab = 0
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// fullScreenCover(item:) 需要一个可比较的壳
private struct ArrivalTarget: Identifiable {
    let id: UUID
}

#Preview { MainView().environmentObject(LocationService.shared).environmentObject(NotificationService.shared) }
