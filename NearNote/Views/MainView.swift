import SwiftUI

struct MainView: View {
    @State private var selectedTab = 0
    @State private var showComposer = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var composerPlace: Place?
    @State private var arrivalTarget: ArrivalTarget?

    var body: some View {
        Group {
            if hasSeenOnboarding {
                TabView(selection: $selectedTab) {
                    PlansView(onAdd: { showComposer = true }, onMap: { selectedTab = 1 })
                        .tabItem { Label("项目", systemImage: "square.stack.3d.up.fill") }.tag(0)
                    MapView(onAdd: { place in
                        composerPlace = place
                        showComposer = true
                    })
                        .tabItem { Label("地图", systemImage: "map.fill") }.tag(1)
                    SettingsView()
                        .tabItem { Label("设置", systemImage: "gearshape.fill") }.tag(2)
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
        .onReceive(NotificationCenter.default.publisher(for: .arrivalOpened)) { note in
            guard let id = note.object as? UUID else { return }
            arrivalTarget = ArrivalTarget(id: id)
        }
        .onOpenURL { url in
            guard url.scheme == "arrival" else { return }
            // arrival://arrival/<uuid> → 到站全屏页；arrival://trip → 项目页
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
