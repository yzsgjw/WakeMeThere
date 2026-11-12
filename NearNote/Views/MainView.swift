import SwiftUI

struct MainView: View {
    @State private var selectedTab = 0
    @State private var showComposer = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var composerPlace: Place?

    var body: some View {
        Group {
            if hasSeenOnboarding {
                TabView(selection: $selectedTab) {
                    AlightingTripView(onAdd: { showComposer = true })
                        .tabItem { Label("行程", systemImage: "location.north.line.fill") }.tag(0)
                    MapView(onAdd: { place in
                        composerPlace = place
                        showComposer = true
                    })
                        .tabItem { Label("地图", systemImage: "map.fill") }.tag(1)
                    RemindersView(onAdd: { showComposer = true })
                        .tabItem { Label("站点", systemImage: "list.bullet") }.tag(2)
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
        .onOpenURL { url in
            // 点灵动岛 / 锁屏卡片 → arrival://trip → 回到行程页
            if url.scheme == "arrival" { selectedTab = 0 }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview { MainView().environmentObject(LocationService.shared).environmentObject(NotificationService.shared) }
