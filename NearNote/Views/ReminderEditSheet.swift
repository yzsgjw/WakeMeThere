import SwiftUI
import SwiftData
import UIKit
import MapKit
import CoreLocation

struct ReminderEditSheet: View {
    let reminder: Reminder
    var body: some View { ReminderComposerView(reminder: reminder) }
}

struct ReminderComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var locationService: LocationService
    @StateObject private var searchService = PlaceSearchService()
    @StateObject private var settings = SettingsStore.shared
    @FocusState private var titleFocused: Bool

    private let reminder: Reminder?
    @State private var title: String
    @State private var selectedPlace: Place?
    @State private var triggerMode: ReminderTriggerMode
    @State private var radiusMode: RadiusMode
    @State private var customRadius: Double
    @State private var isOneTime: Bool
    @State private var triggerOnArrival: Bool
    @State private var hasTimeConstraints: Bool
    @State private var startTime: Date
    @State private var endTime: Date
    // 通勤项目
    @State private var weekdayMask: Int
    @State private var chime: AlarmChime
    @State private var vibrationEnabled: Bool
    @State private var fullScreenOnArrival: Bool

    init(reminder: Reminder? = nil, initialPlace: Place? = nil) {
        self.reminder = reminder
        _title = State(initialValue: reminder?.title ?? "")

        if let reminder {
            _selectedPlace = State(initialValue: Place(
                name: reminder.placeName,
                address: reminder.placeAddress,
                latitude: reminder.latitude,
                longitude: reminder.longitude,
                provider: PlaceProvider(rawValue: reminder.placeProvider) ?? .apple,
                providerPlaceID: reminder.providerPlaceID,
                category: reminder.category,
                categoryConfidence: reminder.categoryConfidence
            ))
            _triggerMode = State(initialValue: reminder.triggerMode)
            _radiusMode = State(initialValue: RadiusMode.closest(to: reminder.radius))
            _customRadius = State(initialValue: reminder.radius)
            _isOneTime = State(initialValue: reminder.isOneTime)
            _triggerOnArrival = State(initialValue: reminder.triggerOnArrival)
            _hasTimeConstraints = State(initialValue: reminder.startTime != nil)
            _startTime = State(initialValue: reminder.startTime ?? Date())
            _endTime = State(initialValue: reminder.endTime ?? Date().addingTimeInterval(3600))
            _weekdayMask = State(initialValue: reminder.weekdayMask)
            _chime = State(initialValue: reminder.chime)
            _vibrationEnabled = State(initialValue: reminder.vibrationEnabled)
            _fullScreenOnArrival = State(initialValue: reminder.fullScreenOnArrival)
        } else {
            let settings = SettingsStore.shared
            _selectedPlace = State(initialValue: initialPlace)
            _triggerMode = State(initialValue: .specificPlace)
            _radiusMode = State(initialValue: settings.radiusMode)
            _customRadius = State(initialValue: settings.customRadius)
            _isOneTime = State(initialValue: true)
            _triggerOnArrival = State(initialValue: true)
            _hasTimeConstraints = State(initialValue: false)
            _startTime = State(initialValue: Date())
            _endTime = State(initialValue: Date().addingTimeInterval(3600))
            _weekdayMask = State(initialValue: PlanSchedule.weekdaysMask)
            _chime = State(initialValue: AlarmChime.current)
            _vibrationEnabled = State(initialValue: true)
            _fullScreenOnArrival = State(initialValue: true)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NearNoteBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        titleCard
                        placeCard

                        if let place = selectedPlace {
                            triggerCard(for: place)
                            radiusCard
                            scheduleCard
                            timeCard
                            alarmCard
                            repeatCard
                            saveBlock
                        }
                    }
                    .padding(.horizontal, NearNoteStyle.gutter)
                    .padding(.top, 14)
                    .padding(.bottom, 44)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)
                .tint(NearNoteStyle.accent)
            }
            .navigationTitle(reminder == nil ? "新建通勤项目" : "编辑通勤项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .tint(NearNoteStyle.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onAppear {
                // 这里只做一件事：如果已经有定位权限就直接复用。
                // 不抢焦点、不申请权限 —— 两者都会让整张页面板卡住。
                if locationService.authorizationStatus == .authorizedWhenInUse
                    || locationService.authorizationStatus == .authorizedAlways {
                    locationService.startInUseTracking()
                }
            }
            .onDisappear { locationService.stopInUseTracking() }
        }
    }

    // MARK: - 页面骨架

    /// 这里故意不用系统 `Form`。
    /// `Form` 在 fullScreenCover 里和滚动、键盘、命中区域会互相打架，
    /// 症状就是「表单弹出来了，但整块点不动、只有键盘能点」。
    /// 换成自己搭的卡片：ScrollView + VStack，控制权全在自己手里。
    private func card<Content: View>(
        _ title: String?,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(NearNoteStyle.Typeface.label)
                    .foregroundStyle(NearNoteStyle.textTertiary)
                    .padding(.leading, 2)
            }

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                NearNoteStyle.surface,
                in: RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: NearNoteStyle.cardRadius, style: .continuous)
                    .strokeBorder(NearNoteStyle.hairline, lineWidth: 1)
            }

            if let footer {
                Text(footer)
                    .font(NearNoteStyle.Typeface.micro)
                    .foregroundStyle(NearNoteStyle.textTertiary)
                    .padding(.leading, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static let dayOptions: [(label: String, bit: Int)] = [
        ("一", 1 << 1), ("二", 1 << 2), ("三", 1 << 3), ("四", 1 << 4),
        ("五", 1 << 5), ("六", 1 << 6), ("日", 1 << 0)
    ]

    private var titleCard: some View {
        card("提醒") {
            TextField("要提醒什么？", text: $title, axis: .vertical)
                .font(NearNoteStyle.Typeface.title)
                .foregroundStyle(NearNoteStyle.textPrimary)
                .lineLimit(1...3)
                .focused($titleFocused)
        }
    }

    private var placeCard: some View {
        card("地点", footer: selectedPlace == nil ? "选一个要提醒的地点。" : nil) {
            if let place = selectedPlace {
                SelectedPlaceRow(place: place)

                Button {
                    withAnimation { selectedPlace = nil }
                } label: {
                    Text("换个地点")
                        .font(NearNoteStyle.Typeface.label)
                        .foregroundStyle(NearNoteStyle.accent)
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink {
                    PlaceSearchPickerView(service: searchService, onSelect: choose)
                } label: {
                    ComposerDestinationRow(
                        symbol: "magnifyingglass",
                        title: "搜索地点",
                        subtitle: "商户、地标、地址"
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    MapPickerView(
                        onSelect: choose,
                        radius: customRadius,
                        onRadiusChange: { newRadius in
                            customRadius = newRadius
                            radiusMode = .custom
                        }
                    )
                } label: {
                    ComposerDestinationRow(
                        symbol: "map",
                        title: "在地图上选点",
                        subtitle: "圆圈就是提醒范围，拖到站点上"
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    LinkPlacePickerView(onSelect: choose)
                } label: {
                    ComposerDestinationRow(
                        symbol: "link",
                        title: "粘贴地图链接",
                        subtitle: "Apple 地图、Google 地图、Waze"
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    SavedPlacePickerView(onSelect: choose)
                } label: {
                    ComposerDestinationRow(
                        symbol: "clock.arrow.circlepath",
                        title: "最近和收藏的地点",
                        subtitle: "家、公司，以及你用过的地点"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func triggerCard(for place: Place) -> some View {
        card(
            "触发方式",
            footer: triggerMode == .similarCategory && place.category != nil
                ? "也可以在附近的同类地点提醒你。"
                : "这条提醒只在 \(place.name) 附近出现。"
        ) {
            Picker("时间", selection: $triggerOnArrival) {
                Text("进入范围时").tag(true)
                Text("离开范围时").tag(false)
            }
            .pickerStyle(.segmented)

            Picker("触发方式", selection: $triggerMode) {
                Text("只在这个地点").tag(ReminderTriggerMode.specificPlace)
                if place.category != nil {
                    Text("附近任意同类地点").tag(ReminderTriggerMode.similarCategory)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private var radiusCard: some View {
        card(
            "到站半径",
            footer: radiusMode == .automatic
                ? "自动模式会按这个地点挑一个稳妥的距离，同时尽量省电。"
                : "用的是系统区域围栏，不做持续定位，耗电低。"
        ) {
            Picker("距离", selection: $radiusMode) {
                ForEach(RadiusMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            if radiusMode == .custom {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("自定义距离", value: customRadiusLabel)
                        .font(NearNoteStyle.Typeface.body)
                    Slider(value: $customRadius, in: 50...2_000, step: 50)
                        .tint(NearNoteStyle.accent)
                }
            }
        }
    }

    private var scheduleCard: some View {
        card("生效星期", footer: "选中的日子才响。至少选一天，默认周一~周五。") {
            HStack(spacing: 6) {
                ForEach(Self.dayOptions, id: \.bit) { option in
                    let on = weekdayMask & option.bit != 0
                    Button {
                        weekdayMask ^= option.bit
                        if weekdayMask == 0 { weekdayMask = PlanSchedule.weekdaysMask }
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Text(option.label)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(on ? Color.white : NearNoteStyle.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(
                                on ? NearNoteStyle.accent : NearNoteStyle.secondarySurface,
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var timeCard: some View {
        card(
            "时间窗",
            footer: hasTimeConstraints ? "只在这个时间段内触发提醒。" : "全天任意时间都可能触发。"
        ) {
            Toggle("时间限制", isOn: $hasTimeConstraints)

            if hasTimeConstraints {
                DatePicker("开始时间", selection: $startTime, displayedComponents: .hourAndMinute)
                DatePicker("结束时间", selection: $endTime, displayedComponents: .hourAndMinute)
            }
        }
    }

    private var alarmCard: some View {
        card(
            "到站提醒方式",
            footer: "项目自己的铃声与震动，不受别处设置影响。全屏提示会在 App 打开着时自动盖满屏幕；锁屏时点通知也能直接进全屏。"
        ) {
            Picker("铃声", selection: $chime) {
                ForEach(AlarmChime.allCases, id: \.self) { item in
                    Text(item.label).tag(item)
                }
            }

            Button {
                AlarmPlaybackService.shared.announceArrival(
                    stationName: selectedPlace?.name ?? "下一站",
                    chime: chime,
                    vibrate: vibrationEnabled
                )
            } label: {
                Label("试听", systemImage: "play.circle.fill")
                    .font(NearNoteStyle.Typeface.body)
                    .foregroundStyle(NearNoteStyle.accent)
            }
            .buttonStyle(.plain)

            Toggle("震动", isOn: $vibrationEnabled)
            Toggle("到站时全屏提示", isOn: $fullScreenOnArrival)
        }
    }

    private var repeatCard: some View {
        card(
            "重复",
            footer: isOneTime
                ? "完成后这条提醒会移到「已完成」。"
                : "可重复的提醒完成后，可以再把它打开。"
        ) {
            Picker("重复", selection: $isOneTime) {
                Text("一次性").tag(true)
                Text("可重复").tag(false)
            }
        }
    }

    private var saveBlock: some View {
        VStack(spacing: 8) {
            PrimaryActionButton(title: "保存项目", symbol: "checkmark") { save() }
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)

            Text(canSave ? "保存后会立刻按新设置注册到站提醒。" : "先选一个地点，才能保存。")
                .font(NearNoteStyle.Typeface.micro)
                .foregroundStyle(NearNoteStyle.textTertiary)
        }
        .padding(.top, 6)
    }

    private var customRadiusLabel: String {
        customRadius >= 1_000 ? String(format: "%.1f km", customRadius / 1_000) : "\(Int(customRadius))m"
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedPlace != nil
    }

    private func choose(_ place: Place) {
        selectedPlace = place
        triggerMode = place.category != nil && place.categoryConfidence >= 0.9 ? .similarCategory : .specificPlace
    }

    private func save() {
        guard let place = selectedPlace else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = reminder ?? Reminder(
            title: cleanTitle,
            latitude: place.latitude,
            longitude: place.longitude,
            placeName: place.name
        )

        value.title = cleanTitle
        value.placeName = place.name
        value.placeAddress = place.address
        value.latitude = place.latitude
        value.longitude = place.longitude
        value.placeProvider = place.provider.rawValue
        value.providerPlaceID = place.providerPlaceID
        value.category = place.category
        value.categoryConfidence = place.categoryConfidence
        value.triggerMode = place.category == nil ? .specificPlace : triggerMode
        value.alternativesDisabled = false
        value.radius = radiusMode.radius(customRadius: customRadius)
        value.triggerOnArrival = triggerOnArrival
        value.isOneTime = isOneTime
        value.isEnabled = true
        value.isCompleted = false
        value.isArchived = false
        
        if hasTimeConstraints {
            value.startTime = startTime
            value.endTime = endTime
        } else {
            value.startTime = nil
            value.endTime = nil
        }
        value.weekdayMask = weekdayMask == 0 ? PlanSchedule.weekdaysMask : weekdayMask
        value.chimeName = chime.rawValue
        value.vibrationEnabled = vibrationEnabled
        value.fullScreenOnArrival = fullScreenOnArrival

        if reminder == nil {
            modelContext.insert(value)
            TelemetryService.shared.track(.reminderCreated, properties: ["trigger": value.triggerModeRaw])
        }
        if radiusMode == .custom { settings.customRadius = customRadius }
        try? modelContext.save()
        settings.remember(place)
        Task { await locationService.updateMonitoredRegions() }
        dismiss()
    }
}

private struct ComposerDestinationRow: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(NearNoteStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.vertical, 5)
    }
}

private struct SelectedPlaceRow: View {
    let place: Place

    var body: some View {
        HStack(spacing: 13) {
            PlaceIcon(category: place.category)
            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.headline)
                if !place.address.isEmpty {
                    Text(place.address)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PlaceSearchPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var locationService: LocationService
    @ObservedObject var service: PlaceSearchService
    let onSelect: (Place) -> Void
    @State private var query = ""

    var body: some View {
        List {
            if service.isSearching {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在搜索附近…")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(service.results) { place in
                Button {
                    onSelect(place)
                    dismiss()
                } label: {
                    PlaceResultRow(place: place)
                }
                .buttonStyle(.plain)
            }
            if let error = service.errorMessage, !query.isEmpty {
                ContentUnavailableView("搜索不可用", systemImage: "magnifyingglass", description: Text(error))
            }
        }
        .navigationTitle("搜索地点")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "地点或地址")
        .onChange(of: query) { _, value in
            service.search(query: value, near: locationService.currentLocation?.coordinate)
        }
    }
}

private struct PlaceResultRow: View {
    let place: Place

    var body: some View {
        HStack(spacing: 12) {
            PlaceIcon(category: place.category)
            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.body.weight(.medium))
                if !place.address.isEmpty {
                    Text(place.address)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 5)
    }
}

private struct LinkPlacePickerView: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Place) -> Void
    @StateObject private var resolver = LinkResolverService()
    @State private var link = ""
    @State private var message: String?
    @State private var isResolving = false

    var body: some View {
        Form {
            Section {
                TextField("粘贴地图链接", text: $link, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .lineLimit(3...6)
            } footer: {
                Text("Apple 地图、Google 地图、Waze 的链接都在本机解析。")
            }

            Section {
                Button(action: parse) {
                    if isResolving {
                        HStack { ProgressView(); Text("正在打开链接…") }
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("使用这个链接").frame(maxWidth: .infinity)
                    }
                }
                .fontWeight(.semibold)
                .disabled(isResolving || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("粘贴地图链接")
        .navigationBarTitleDisplayMode(.inline)
        .alert("读不出这个链接", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好", role: .cancel) { }
        } message: {
            Text(message ?? "")
        }
    }

    private func parse() {
        switch LinkParserService().parse(link) {
        case .place(let place):
            onSelect(place)
            dismiss()
        case .needsExpandedLink:
            resolveOnline()
        case .unsupported:
            if LinkResolverService.extractURL(from: link) != nil {
                resolveOnline()
            } else {
                message = "没找到位置。请粘贴有效的 Apple 地图、Google 地图或 Waze 链接。"
            }
        }
    }

    private func resolveOnline() {
        guard let url = LinkResolverService.extractURL(from: link) else {
            message = "链接里没有可用的位置。"
            return
        }
        isResolving = true
        Task {
            defer { isResolving = false }
            do {
                onSelect(try await resolver.resolvePlace(url: url))
                TelemetryService.shared.track(.mapLinkResolved, properties: ["provider": url.host ?? "unknown"])
                dismiss()
            } catch {
                TelemetryService.shared.track(.mapLinkFailed, properties: ["provider": url.host ?? "unknown"])
                message = (error as? LocalizedError)?.errorDescription
                    ?? "打不开这个链接，可以重试，或直接搜索地点。"
            }
        }
    }
}

private struct SavedPlacePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var settings = SettingsStore.shared
    @Query(sort: \SavedPlace.sortOrder) private var storedPlaces: [SavedPlace]
    let onSelect: (Place) -> Void

    private var places: [(label: String, place: Place)] {
        var values: [(label: String, place: Place)] = storedPlaces
            .filter { $0.type != .recent }
            .map { (label: $0.displayLabel, place: $0.asPlace) }
        if let home = settings.homePlace, !values.contains(where: { $0.label.caseInsensitiveCompare("Home") == .orderedSame }) {
            values.insert(("家", home), at: 0)
        }
        if let work = settings.workPlace, !values.contains(where: { $0.label.caseInsensitiveCompare("Work") == .orderedSame }) {
            values.insert(("公司", work), at: min(1, values.count))
        }
        values.append(contentsOf: settings.recentPlaces.map { ($0.name, $0) })
        return values
    }

    var body: some View {
        List {
            if places.isEmpty {
                ContentUnavailableView(
                    "还没有收藏地点",
                    systemImage: "mappin.slash",
                    description: Text("用过的地点会出现在这里。")
                )
            } else {
                ForEach(Array(places.enumerated()), id: \.offset) { _, item in
                    Button {
                        onSelect(item.place)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            PlaceIcon(category: item.place.category)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.label).font(.body.weight(.medium))
                                if item.label != item.place.name {
                                    Text(item.place.name)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("收藏地点")
        .navigationBarTitleDisplayMode(.inline)
    }
}
