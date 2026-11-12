import SwiftUI
import SwiftData
import MapKit

struct MapView: View {
    var onAdd: (Place?) -> Void = { _ in }
    @Query private var reminders: [Reminder]
    @EnvironmentObject private var locationService: LocationService
    @State private var position: MapCameraPosition = .automatic
    @State private var selected: Reminder?
    @State private var showLocationPicker = false

    private var activeReminders: [Reminder] {
        reminders
            .filter { !$0.isCompleted && !$0.isArchived && $0.isEnabled }
            .sorted { $0.placeName.localizedCaseInsensitiveCompare($1.placeName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NearNoteBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        mapHero
                        placesList
                    }
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
            .tint(NearNoteStyle.accent)
            .sheet(item: $selected) { ReminderComposerView(reminder: $0) }
            .fullScreenCover(isPresented: $showLocationPicker) {
                LocationPickerView(onPlaceSelected: { place in onAdd(place) })
            }
            .onAppear { locationService.startInUseTracking() }
            .onDisappear { locationService.stopInUseTracking() }
        }
    }

    private var mapHero: some View {
        ZStack(alignment: .top) {
            Map(position: $position) {
                UserAnnotation()

                // 围栏圈：直接把每个提醒的提醒范围画在地图上，
                // 一眼看得出"这个圈到底盖住哪几条街"。
                ForEach(activeReminders) { reminder in
                    MapCircle(center: reminder.coordinate, radius: max(60, reminder.radius))
                        .foregroundStyle(NearNoteStyle.accent.opacity(0.13))
                        .stroke(NearNoteStyle.accent.opacity(0.55), lineWidth: 1)
                }

                ForEach(activeReminders) { reminder in
                    Annotation(reminder.placeName, coordinate: reminder.coordinate) {
                        Button { selected = reminder } label: {
                            PlaceIcon(category: reminder.category, size: 34)
                                .overlay {
                                    Circle().stroke(.white.opacity(0.75), lineWidth: 1.2)
                                }
                                .shadow(color: .black.opacity(0.4), radius: 5, y: 2)
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .mapControls { MapCompass() }
            .frame(height: 440)

            LinearGradient(
                colors: [NearNoteStyle.canvas.opacity(0.92), .clear, NearNoteStyle.canvas],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            HStack(spacing: 10) {
                Button { showLocationPicker = true } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                        Text("搜索地点，或在地图上选点")
                            .font(NearNoteStyle.Typeface.body)
                            .foregroundStyle(NearNoteStyle.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)

                Button { centerOnUser() } label: {
                    Image(systemName: "location.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(NearNoteStyle.accent)
                        .frame(width: 46, height: 46)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("回到我的位置")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 5) {
                Text("我的地点")
                    .font(NearNoteStyle.Typeface.title)
                    .foregroundStyle(NearNoteStyle.textPrimary)
                Text(activeReminders.isEmpty
                     ? "还没有启用的提醒"
                     : "\(activeReminders.count) 个提醒正在生效")
                    .font(NearNoteStyle.Typeface.label)
                    .foregroundStyle(NearNoteStyle.textSecondary)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
    }

    private var placesList: some View {
        LazyVStack(spacing: 12) {
            if activeReminders.isEmpty {
                VStack(spacing: 12) {
                    Image("pebble_idle")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 132, height: 112)
                    Text("还没有地点")
                        .font(NearNoteStyle.Typeface.title)
                        .foregroundStyle(NearNoteStyle.textPrimary)
                    Text("添加一个站点，它就会出现在这张地图上。")
                        .font(NearNoteStyle.Typeface.label)
                        .foregroundStyle(NearNoteStyle.textSecondary)
                        .multilineTextAlignment(.center)
                    PrimaryActionButton(title: "添加地点", symbol: "plus") { onAdd(nil) }
                        .padding(.top, 6)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            } else {
                ForEach(activeReminders) { reminder in
                    HStack(spacing: 12) {
                        Button { show(reminder) } label: {
                            HStack(spacing: 12) {
                                PlaceIcon(category: reminder.category, size: 42)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(reminder.placeName)
                                        .font(NearNoteStyle.Typeface.rowTitle)
                                        .foregroundStyle(NearNoteStyle.textPrimary)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(reminder.title)
                                            .lineLimit(1)
                                        Text("·")
                                        Text("半径 \(reminder.radius.distanceText)")
                                    }
                                    .font(NearNoteStyle.Typeface.micro)
                                    .foregroundStyle(NearNoteStyle.textSecondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)

                        Button { selected = reminder } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(NearNoteStyle.textSecondary)
                                .frame(width: 34, height: 34)
                                .background(NearNoteStyle.raisedSurface, in: Circle())
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("编辑 \(reminder.title)")
                    }
                    .padding(14)
                    .background(NearNoteStyle.surface, in: RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous)
                            .stroke(NearNoteStyle.hairline, lineWidth: 0.5)
                    }
                }
            }
        }
        .padding(.horizontal, NearNoteStyle.gutter)
    }

    private func centerOnUser() {
        guard let coordinate = locationService.currentLocation?.coordinate else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            position = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1_200, longitudinalMeters: 1_200))
        }
    }

    private func show(_ reminder: Reminder) {
        withAnimation(.easeInOut(duration: 0.35)) {
            position = .region(MKCoordinateRegion(center: reminder.coordinate, latitudinalMeters: 900, longitudinalMeters: 900))
        }
    }
}

#Preview { MapView().environmentObject(LocationService.shared) }
