import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// 地图选点。
///
/// 与"搜索选点"互补：搜索只在你知道名字时有用，公交站台、路口、小区门口这类
/// 地方往往搜不到准确坐标，只能在地图上点。
///
/// 交互：地图中心就是选中的点（拖动地图 = 移动选点），所以不需要"点击放钉"那一步，
/// 手指永远不用挡住要看的地方。中心同时画出**提醒半径的圆圈**——你能直接看到
/// "300 米到底是多大一片"，这比看数字靠谱。
///
/// 选完可以顺手收藏（写进 `SavedPlace`，type = `.custom`），下次在收藏列表里一点就到。
struct MapPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var locationService: LocationService

    @Query(sort: \SavedPlace.sortOrder) private var allSavedPlaces: [SavedPlace]

    let onSelect: (Place) -> Void
    /// 圆圈初始半径（米）。调用方通常是"这个提醒当前的提醒距离"。
    var radius: Double = 500
    /// 用户拖了直径滑杆后回调（米，半径值），让编辑页把半径带回去。
    var onRadiusChange: ((Double) -> Void)? = nil

    @State private var camera: MapCameraPosition = .automatic
    /// 用户选的直径（米）。半径 = 直径 / 2。
    @State private var diameter: Double = 0
    @State private var center: CLLocationCoordinate2D?
    @State private var resolvedName = ""
    @State private var resolvedAddress = ""
    @State private var isResolving = false
    @State private var geocodeTask: Task<Void, Never>?

    @State private var favoriteName = ""
    @State private var showFavoritePrompt = false
    @State private var toast: String?

    private var favorites: [SavedPlace] {
        allSavedPlaces.filter { $0.type != .recent }
    }

    var body: some View {
        ZStack {
            mapLayer
            VStack {
                hintChip
                Spacer()
                bottomCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .background(NearNoteStyle.canvas)
        .navigationTitle("地图选点")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    recenterOnUser()
                } label: {
                    Image(systemName: "location.fill")
                }
                .accessibilityLabel("回到我的位置")
            }
        }
        .alert("收藏这个地点", isPresented: $showFavoritePrompt) {
            TextField("给它起个名字，比如「公司楼下」", text: $favoriteName)
            Button("收藏") { saveFavorite() }
            Button("取消", role: .cancel) { favoriteName = "" }
        } message: {
            Text("收藏后会出现在「收藏地点」里，下次选站一点就到。")
        }
        .onAppear {
            if diameter == 0 { diameter = min(4000, max(100, radius * 2)) }
            recenterOnUser()
            geocodeTask?.cancel()
            if let coordinate = center { scheduleReverseGeocode(coordinate) }
        }
        .onDisappear { geocodeTask?.cancel() }
        .tint(NearNoteStyle.accent)
    }

    // MARK: - 地图

    private var mapLayer: some View {
        Map(position: $camera, interactionModes: .all) {
            UserAnnotation()

            if let center {
                // 半径圆圈：让"300 米"变成看得见的一片
                MapCircle(center: center, radius: previewRadius)
                    .foregroundStyle(NearNoteStyle.accent.opacity(0.14))
                    .stroke(NearNoteStyle.accent.opacity(0.9), lineWidth: 1.5)

                Annotation("", coordinate: center, anchor: .bottom) {
                    pinHead
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .mapControls {
            MapCompass()
        }
        .onMapCameraChange(frequency: .continuous) { context in
            center = context.region.center
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            center = context.region.center
            scheduleReverseGeocode(context.region.center)
        }
        .ignoresSafeArea()
    }

    /// 钉子指向地图中心：针尖对齐坐标，头在上面
    private var pinHead: some View {
        VStack(spacing: 0) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(NearNoteStyle.accent)
                .background(Circle().fill(NearNoteStyle.canvas).padding(3))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(NearNoteStyle.accent)
                .offset(y: -2)
        }
        .allowsHitTesting(false)
    }

    private var hintChip: some View {
        Text("拖动地图，把圆圈对准站点")
            .font(NearNoteStyle.Typeface.micro)
            .foregroundStyle(NearNoteStyle.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(NearNoteStyle.raisedSurface.opacity(0.92), in: Capsule())
            .overlay {
                Capsule().stroke(NearNoteStyle.hairline, lineWidth: 0.5)
            }
    }

    // MARK: - 底部卡片

    private var bottomCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let toast {
                Text(toast)
                    .font(NearNoteStyle.Typeface.micro)
                    .foregroundStyle(NearNoteStyle.accent)
                    .transition(.opacity)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(titleText)
                        .font(NearNoteStyle.Typeface.rowTitle)
                        .foregroundStyle(NearNoteStyle.textPrimary)
                        .lineLimit(1)
                    Text(subtitleText)
                        .font(NearNoteStyle.Typeface.label)
                        .foregroundStyle(NearNoteStyle.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)

                Button {
                    favoriteName = resolvedName.isEmpty ? "" : resolvedName
                    showFavoritePrompt = true
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "star.circle.fill")
                            .font(.system(size: 22))
                        Text("收藏").font(NearNoteStyle.Typeface.micro)
                    }
                    .foregroundStyle(NearNoteStyle.accent)
                    .frame(width: 48)
                }
                .buttonStyle(PressableStyle())
                .disabled(center == nil)
            }

            // 直径滑杆：圈多大由用户直接拖，比在设置里算半径直观
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("提醒范围")
                        .font(NearNoteStyle.Typeface.label)
                        .foregroundStyle(NearNoteStyle.textSecondary)
                    Spacer()
                    Text("直径 \(distanceText(diameter)) · 半径 \(distanceText(diameter / 2))")
                        .font(NearNoteStyle.Typeface.micro)
                        .foregroundStyle(NearNoteStyle.accent)
                        .monospacedDigit()
                }
                Slider(
                    value: $diameter,
                    in: 100...4000,
                    step: 50,
                    minimumValueLabel: Text("100m")
                        .font(NearNoteStyle.Typeface.micro)
                        .foregroundStyle(NearNoteStyle.textTertiary),
                    maximumValueLabel: Text("4km")
                        .font(NearNoteStyle.Typeface.micro)
                        .foregroundStyle(NearNoteStyle.textTertiary),
                    label: { Text("提醒范围") }
                )
                .tint(NearNoteStyle.accent)
            }

            HStack(spacing: 6) {
                MetaTag(text: "提醒半径 \(distanceText(previewRadius))", symbol: "circle.dashed", tint: NearNoteStyle.accent)
                if let coordinate = center {
                    MetaTag(text: coordinateText(coordinate), symbol: "mappin.and.ellipse")
                }
            }

            if !favorites.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(favorites) { place in
                            Button {
                                flyTo(place.coordinate)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: place.symbolName).font(.system(size: 11))
                                    Text(place.displayLabel).lineLimit(1)
                                }
                                .font(NearNoteStyle.Typeface.micro)
                                .foregroundStyle(NearNoteStyle.textPrimary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(NearNoteStyle.secondarySurface, in: Capsule())
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }
            }

            PrimaryActionButton(title: isResolving ? "识别中…" : "用此位置",
                                symbol: "checkmark",
                                action: confirm)
                .disabled(isResolving || center == nil)
                .opacity(center == nil ? 0.5 : 1)
        }
        .padding(16)
        .background(NearNoteStyle.surface, in: RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous)
                .stroke(NearNoteStyle.hairline, lineWidth: 0.5)
        }
    }

    /// 圆圈实际画的半径（米）
    private var previewRadius: Double {
        max(60, (diameter > 0 ? diameter : max(200, radius * 2)) / 2)
    }

    private func distanceText(_ meters: Double) -> String {
        meters >= 1_000 ? String(format: "%.1f km", meters / 1_000) : "\(Int(meters.rounded())) m"
    }

    private var titleText: String {
        if !resolvedName.isEmpty { return resolvedName }
        return isResolving ? "识别中…" : "已选位置"
    }

    private var subtitleText: String {
        if !resolvedAddress.isEmpty { return resolvedAddress }
        return isResolving ? "正在查地址" : "这个位置没有门牌地址，可用坐标。"
    }

    private func coordinateText(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    // MARK: - 动作

    private func confirm() {
        guard let center else { return }
        let name = resolvedName.isEmpty ? "地图选点" : resolvedName
        let place = Place(
            name: name,
            address: resolvedAddress,
            latitude: center.latitude,
            longitude: center.longitude,
            provider: .manual
        )
        // 记一条"最近"，和搜索选点保持同一套习惯
        modelContext.insert(SavedPlace(
            name: name,
            address: resolvedAddress,
            latitude: center.latitude,
            longitude: center.longitude,
            type: .recent
        ))
        try? modelContext.save()
        onRadiusChange?(previewRadius)
        onSelect(place)
        dismiss()
    }

    private func saveFavorite() {
        guard let center else { return }
        let typed = favoriteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = typed.isEmpty ? (resolvedName.isEmpty ? "收藏地点" : resolvedName) : typed

        // 同一个坐标已经收藏过就不再来一条
        let exists = favorites.contains {
            abs($0.latitude - center.latitude) < 0.00005 && abs($0.longitude - center.longitude) < 0.00005
        }
        if !exists {
            modelContext.insert(SavedPlace(
                name: name,
                address: resolvedAddress,
                latitude: center.latitude,
                longitude: center.longitude,
                type: .custom,
                symbolName: "star.fill",
                sortOrder: (allSavedPlaces.map(\.sortOrder).max() ?? -1) + 1
            ))
            try? modelContext.save()
        }
        favoriteName = ""
        withAnimation { toast = exists ? "这里已经收藏过了" : "已收藏「\(name)」" }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            withAnimation { toast = nil }
        }
    }

    private func recenterOnUser() {
        guard let coordinate = locationService.currentLocation?.coordinate else { return }
        flyTo(coordinate)
        scheduleReverseGeocode(coordinate)
    }

    private func flyTo(_ coordinate: CLLocationCoordinate2D) {
        withAnimation(.easeInOut(duration: 0.35)) {
            camera = .region(MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 1_400,
                longitudinalMeters: 1_400
            ))
        }
        center = coordinate
    }

    // MARK: - 反查地址

    /// 拖动地图时会连续触发，所以防抖 700ms，停了才去查，免得打爆地理编码配额。
    private func scheduleReverseGeocode(_ coordinate: CLLocationCoordinate2D) {
        geocodeTask?.cancel()
        isResolving = true
        geocodeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }

            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let geocoder = CLGeocoder()
            let marks: [CLPlacemark] = await withCheckedContinuation { continuation in
                geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                    continuation.resume(returning: placemarks ?? [])
                }
            }
            guard !Task.isCancelled else { return }

            if let mark = marks.first {
                let poi = mark.areasOfInterest?.first
                resolvedName = poi ?? mark.name ?? mark.locality ?? ""
                resolvedAddress = [
                    mark.thoroughfare,
                    mark.subThoroughfare,
                    mark.locality,
                    mark.administrativeArea
                ]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            } else {
                resolvedName = ""
                resolvedAddress = ""
            }
            isResolving = false
        }
    }
}
