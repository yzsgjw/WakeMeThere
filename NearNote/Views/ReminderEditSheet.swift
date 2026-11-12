import SwiftUI
import SwiftData
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
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("要提醒什么？", text: $title, axis: .vertical)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2...4)
                        .focused($titleFocused)
                        .submitLabel(.next)
                        .padding(.vertical, 8)
                } header: {
                    Text("提醒")
                }

                placeSection

                if let place = selectedPlace {
                    triggerSection(for: place)
                    radiusSection
                    timeSection
                    repeatSection
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(NearNoteBackground())
            .tint(NearNoteStyle.accent)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(reminder == nil ? "新建提醒" : "编辑提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(NearNoteStyle.canvas.opacity(0.94), for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onAppear {
                if reminder == nil { titleFocused = true }
                locationService.startInUseTracking()
            }
            .onDisappear { locationService.stopInUseTracking() }
        }
    }

    @ViewBuilder private var placeSection: some View {
        Section {
            if let place = selectedPlace {
                SelectedPlaceRow(place: place)
                Button("换个地点") {
                    withAnimation { selectedPlace = nil }
                }
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

                NavigationLink {
                    MapPickerView(onSelect: choose, radius: customRadius)
                } label: {
                    ComposerDestinationRow(
                        symbol: "map",
                        title: "在地图上选点",
                        subtitle: "圆圈就是提醒范围，拖到站点上"
                    )
                }

                NavigationLink {
                    LinkPlacePickerView(onSelect: choose)
                } label: {
                    ComposerDestinationRow(
                        symbol: "link",
                        title: "粘贴地图链接",
                        subtitle: "Apple 地图、Google 地图、Waze"
                    )
                }

                NavigationLink {
                    SavedPlacePickerView(onSelect: choose)
                } label: {
                    ComposerDestinationRow(
                        symbol: "clock.arrow.circlepath",
                        title: "最近和收藏的地点",
                        subtitle: "家、公司，以及你用过的地点"
                    )
                }
            }
        } header: {
            Text("地点")
        } footer: {
            if selectedPlace == nil {
                Text("选一个要提醒的地点。")
            }
        }
    }

    private func triggerSection(for place: Place) -> some View {
        Section {
            Picker("时间", selection: $triggerOnArrival) {
                Text("进入范围时").tag(true)
                Text("离开范围时").tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 4)

            Picker("触发方式", selection: $triggerMode) {
                Text("只在这个地点").tag(ReminderTriggerMode.specificPlace)
                if place.category != nil {
                    Text("附近任意同类地点").tag(ReminderTriggerMode.similarCategory)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("触发方式")
        } footer: {
            if triggerMode == .similarCategory, place.category != nil {
                Text("也可以在附近的同类地点提醒你。")
            } else {
                Text("这条提醒只在 \(place.name) 附近出现。")
            }
        }
    }

    private var radiusSection: some View {
        Section {
            Picker("距离", selection: $radiusMode) {
                ForEach(RadiusMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            if radiusMode == .custom {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("自定义距离", value: customRadiusLabel)
                    Slider(value: $customRadius, in: 50...2_000, step: 50)
                        .tint(NearNoteStyle.accent)
                }
                .padding(.vertical, 6)
            }
        } header: {
            Text("到站半径")
        } footer: {
            Text(radiusMode == .automatic
                 ? "自动模式会按这个地点挑一个稳妥的距离，同时尽量省电。"
                 : "用的是系统区域围栏，不做持续定位，耗电低。")
        }
    }

    private var repeatSection: some View {
        Section {
            Picker("重复", selection: $isOneTime) {
                Text("一次性").tag(true)
                Text("可重复").tag(false)
            }
        } footer: {
            Text(isOneTime
                 ? "完成后这条提醒会移到「已完成」。"
                 : "可重复的提醒完成后，可以在「提醒」页把它恢复。")
        }
    }

    private var timeSection: some View {
        Section {
            Toggle("时间限制", isOn: $hasTimeConstraints)
            
            if hasTimeConstraints {
                DatePicker("开始时间", selection: $startTime, displayedComponents: .hourAndMinute)
                DatePicker("结束时间", selection: $endTime, displayedComponents: .hourAndMinute)
            }
        } header: {
            Text("时间窗")
        } footer: {
            Text(hasTimeConstraints ? "只在这个时间段内触发提醒。" : "全天任意时间都可能触发。")
        }
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
