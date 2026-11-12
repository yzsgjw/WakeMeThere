import SwiftUI
import CoreLocation
import SwiftData

struct SettingsView: View {
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var notificationService: NotificationService
    @StateObject private var settings = SettingsStore.shared
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedPlace.sortOrder) private var allSavedPlaces: [SavedPlace]
    @State private var showPermissions = false
    @State private var showAddSavedPlace = false
    @State private var editingSavedPlace: SavedPlace?
    @State private var showAllSavedPlaces = false

    private var savedPlaces: [SavedPlace] {
        allSavedPlaces.filter { $0.type != .recent }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showPermissions = true } label: {
                        SettingsRow(
                            symbol: "bell.badge.fill",
                            title: "定位与通知",
                            value: permissionSummary
                        )
                    }
                    .foregroundStyle(.primary)

                    Picker("默认提醒距离", selection: Binding(
                        get: { settings.radiusMode },
                        set: { settings.radiusMode = $0 }
                    )) {
                        ForEach(RadiusMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    if settings.radiusMode == .custom {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("自定义距离", value: customRadiusLabel)
                            Slider(value: $settings.customRadius, in: 50...2_000, step: 50)
                        }
                        .padding(.vertical, 6)
                    }
                } header: {
                    Text("提醒")
                } footer: {
                    Text("新建提醒时使用这个默认距离，保存前每一站还能单独改。")
                }

                Section {
                    Toggle("勿扰时段", isOn: $settings.quietHoursEnabled)
                    if settings.quietHoursEnabled {
                        DatePicker("从", selection: timeBinding(for: true), displayedComponents: .hourAndMinute)
                        DatePicker("到", selection: timeBinding(for: false), displayedComponents: .hourAndMinute)
                    }
                    Picker("重复提醒", selection: $settings.cooldownMinutes) {
                        Text("15 分钟后").tag(15)
                        Text("30 分钟后").tag(30)
                        Text("1 小时后").tag(60)
                    }
                } header: {
                    Text("通知")
                }

                Section("收藏地点") {
                    ForEach(Array(savedPlaces.prefix(2))) { place in
                        savedPlaceRow(place)
                    }

                    if savedPlaces.count > 2 {
                        DisclosureGroup(isExpanded: $showAllSavedPlaces) {
                            ForEach(Array(savedPlaces.dropFirst(2))) { place in
                                savedPlaceRow(place)
                            }
                        } label: {
                            Text(showAllSavedPlaces ? "收起" : "再看 \(savedPlaces.count - 2) 个")
                                .font(.subheadline.weight(.medium))
                        }
                    }

                    Button { showAddSavedPlace = true } label: {
                        Label("添加收藏地点", systemImage: "plus.circle.fill")
                    }
                }

                Section {
                    Toggle("分享匿名使用数据", isOn: $settings.shareAnonymousUsage)
                        .disabled(!TelemetryService.shared.isConfigured)
                    if !TelemetryService.shared.isConfigured {
                        Label("本版本未配置用量收集。", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        PrivacyView()
                    } label: {
                        SettingsRow(
                            symbol: "lock.shield.fill",
                            title: "隐私",
                            value: "纯本地"
                        )
                    }
                    if let privacyURL = AppConfiguration.privacyPolicyURL {
                        Link(destination: privacyURL) {
                            SettingsRow(symbol: "safari.fill", title: "隐私政策", value: "网页")
                        }
                    }
                } header: {
                    Text("隐私与诊断")
                } footer: {
                    Text("用量数据里不会包含提醒文字、收藏地点或坐标；本版本没有配置任何上报端点，数据不会外发。")
                }

                Section("支持") {
                    NavigationLink {
                        FeedbackView()
                    } label: {
                        SettingsRow(symbol: "exclamationmark.bubble.fill", title: "反馈问题", value: "")
                    }
                    if let supportURL = AppConfiguration.supportURL {
                        Link(destination: supportURL) {
                            SettingsRow(symbol: "questionmark.circle.fill", title: "支持网站", value: "网页")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listRowBackground(NearNoteStyle.surface)
            .listRowSeparatorTint(NearNoteStyle.hairline)
            .background(NearNoteBackground())
            .tint(NearNoteStyle.accent)
            .navigationTitle("设置")
            .sheet(isPresented: $showPermissions) { PermissionEducationView() }
            .sheet(isPresented: $showAddSavedPlace) {
                SavedPlaceEditor(existing: nil, nextSortOrder: savedPlaces.count)
            }
            .sheet(item: $editingSavedPlace) {
                SavedPlaceEditor(existing: $0, nextSortOrder: savedPlaces.count)
            }
            .task { migrateLegacySavedPlacesIfNeeded() }
        }
    }

    private func migrateLegacySavedPlacesIfNeeded() {
        let labels = Set(savedPlaces.map { $0.displayLabel.lowercased() })
        if let home = settings.homePlace, !labels.contains("home") {
            modelContext.insert(SavedPlace(
                name: home.name,
                address: home.address,
                latitude: home.latitude,
                longitude: home.longitude,
                type: .custom,
                label: "家",
                symbolName: "house.fill",
                sortOrder: savedPlaces.count
            ))
        }
        if let work = settings.workPlace, !labels.contains("work") {
            modelContext.insert(SavedPlace(
                name: work.name,
                address: work.address,
                latitude: work.latitude,
                longitude: work.longitude,
                type: .custom,
                label: "公司",
                symbolName: "briefcase.fill",
                sortOrder: savedPlaces.count + 1
            ))
        }
        try? modelContext.save()
    }

    private func savedPlaceRow(_ place: SavedPlace) -> some View {
        Button { editingSavedPlace = place } label: {
            SettingsRow(symbol: place.symbolName, title: place.displayLabel, value: place.name)
        }
        .foregroundStyle(.primary)
        .swipeActions {
            Button("删除", systemImage: "trash", role: .destructive) {
                modelContext.delete(place)
                try? modelContext.save()
            }
        }
    }

    private var permissionSummary: String {
        notificationService.isAuthorized && locationService.authorizationStatus == .authorizedAlways ? "已就绪" : "待检查"
    }

    private var customRadiusLabel: String {
        settings.customRadius >= 1_000
            ? String(format: "%.1f km", settings.customRadius / 1_000)
            : "\(Int(settings.customRadius))m"
    }

    private func timeBinding(for start: Bool) -> Binding<Date> {
        Binding {
            let minutes = start ? settings.quietHoursStartMinutes : settings.quietHoursEndMinutes
            return Calendar.current.date(
                bySettingHour: minutes / 60,
                minute: minutes % 60,
                second: 0,
                of: Date()
            ) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let value = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            if start {
                settings.quietHoursStartMinutes = value
            } else {
                settings.quietHoursEndMinutes = value
            }
        }
    }
}

private struct SettingsRow: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NearNoteStyle.accent)
                .frame(width: 24)
            Text(title)
                .font(NearNoteStyle.Typeface.body)
                .foregroundStyle(NearNoteStyle.textPrimary)
            Spacer(minLength: 8)
            Text(value)
                .font(NearNoteStyle.Typeface.label)
                .foregroundStyle(NearNoteStyle.textSecondary)
                .lineLimit(1)
        }
    }
}

private struct PrivacyView: View {
    private let promises = [
        ("location.slash.fill", "不留位置历史", "不会把你走过的地方拼成一条轨迹。"),
        ("internaldrive.fill", "纯本地存储", "提醒和收藏地点只存在这台手机上，不上传任何服务器，这一版也已移除 iCloud 同步。"),
        ("bell.badge.fill", "到站才唤醒", "用系统的区域围栏判断进站，不做持续定位，也不会一直在后台跑。"),
        ("hand.raised.fill", "诊断默认关闭", "用量分享默认关闭，且永远不会包含提醒文字、地点或坐标。")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.top, 34)
                Text("你的地点只属于你")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
                Text("到站提醒不需要注册账号，也没有任何服务器。所有数据留在本机。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .padding(.horizontal, 12)

                VStack(spacing: 24) {
                    ForEach(promises, id: \.1) { promise in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: promise.0)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(promise.1)
                                    .font(.headline)
                                Text(promise.2)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.top, 38)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .background(NearNoteBackground())
        .navigationTitle("隐私")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SavedPlaceEditor: View {
    let existing: SavedPlace?
    let nextSortOrder: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var locationService: LocationService
    @StateObject private var service = PlaceSearchService()
    @StateObject private var linkResolver = LinkResolverService()
    @State private var label: String
    @State private var icon: SavedPlaceIcon
    @State private var selectedPlace: Place?
    @State private var query: String = ""
    @State private var isResolvingLink = false
    @State private var linkError: String?
    @State private var resolveTask: Task<Void, Never>?

    init(existing: SavedPlace?, nextSortOrder: Int) {
        self.existing = existing
        self.nextSortOrder = nextSortOrder
        _label = State(initialValue: existing?.displayLabel ?? "")
        _icon = State(initialValue: SavedPlaceIcon(rawValue: existing?.symbolName ?? "") ?? .pin)
        _selectedPlace = State(initialValue: existing?.asPlace)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("标签") {
                    TextField("Home, Gym, Parents…", text: $label)
                    Picker("图标", selection: $icon) {
                        ForEach(SavedPlaceIcon.allCases) { option in
                            Label(option.title, systemImage: option.rawValue).tag(option)
                        }
                    }
                }

                Section {
                    if let selectedPlace {
                        PlaceResultRowForSettings(place: selectedPlace)
                        Button("换个地点") {
                            self.selectedPlace = nil
                            query = ""
                            linkError = nil
                        }
                    } else {
                        TextField("搜索，或粘贴地图链接", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if isResolvingLink {
                            ProgressView("Opening map link…")
                        } else if service.isSearching {
                            ProgressView("Searching…")
                        }
                        if let linkError {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("打不开这个链接", systemImage: "exclamationmark.triangle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(NearNoteStyle.textSecondary)
                                Text(linkError)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        } else if !isResolvingLink {
                            ForEach(service.results) { place in
                                Button { selectedPlace = place } label: {
                                    PlaceResultRowForSettings(place: place)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } header: {
                    Text("地点")
                } footer: {
                    Text("可以直接搜，也可以粘贴完整或缩短过的 Apple 地图、Google 地图、Waze 链接。")
                }
            }
            .scrollContentBackground(.hidden)
            .listRowBackground(NearNoteStyle.surface)
            .listRowSeparatorTint(NearNoteStyle.hairline)
            .background(NearNoteBackground())
            .navigationTitle(existing == nil ? "添加收藏地点" : "编辑收藏地点")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: query) { _, value in
                handleQuery(value)
            }
            .onDisappear { resolveTask?.cancel() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .fontWeight(.semibold)
                        .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedPlace == nil)
                }
            }
        }
    }

    private func handleQuery(_ value: String) {
        resolveTask?.cancel()
        linkError = nil
        guard let url = LinkResolverService.extractURL(from: value) else {
            isResolvingLink = false
            service.search(query: value, near: locationService.currentLocation?.coordinate)
            return
        }

        isResolvingLink = true
        service.search(query: "", near: nil)
        resolveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let place = try await linkResolver.resolvePlace(url: url)
                try Task.checkCancellation()
                selectedPlace = place
                isResolvingLink = false
                TelemetryService.shared.track(.mapLinkResolved, properties: ["provider": url.host ?? "unknown"])
            } catch is CancellationError {
                return
            } catch {
                isResolvingLink = false
                linkError = (error as? LocalizedError)?.errorDescription
                    ?? "可以重试，或直接搜索这个地点。"
                TelemetryService.shared.track(.mapLinkFailed, properties: ["provider": url.host ?? "unknown"])
            }
        }
    }

    private func save() {
        guard let selectedPlace else { return }
        let value = existing ?? SavedPlace(
            name: selectedPlace.name,
            address: selectedPlace.address,
            latitude: selectedPlace.latitude,
            longitude: selectedPlace.longitude,
            type: .custom,
            label: label,
            symbolName: icon.rawValue,
            sortOrder: nextSortOrder
        )
        value.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        value.name = selectedPlace.name
        value.address = selectedPlace.address
        value.latitude = selectedPlace.latitude
        value.longitude = selectedPlace.longitude
        value.type = .custom
        value.symbolName = icon.rawValue
        if existing == nil { modelContext.insert(value) }
        try? modelContext.save()
        dismiss()
    }
}

private enum SavedPlaceIcon: String, CaseIterable, Identifiable {
    case home = "house.fill"
    case work = "briefcase.fill"
    case gym = "dumbbell.fill"
    case school = "graduationcap.fill"
    case family = "person.2.fill"
    case favorite = "heart.fill"
    case pin = "mappin.circle.fill"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "家"
        case .work: "公司"
        case .gym: "Gym"
        case .school: "学校"
        case .family: "家人"
        case .favorite: "常去"
        case .pin: "地点"
        }
    }
}

private struct PlaceResultRowForSettings: View {
    let place: Place

    var body: some View {
        HStack(spacing: 12) {
            PlaceIcon(category: place.category)
            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.body.weight(.medium))
                Text(place.address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct FeedbackView: View {
    @StateObject private var settings = SettingsStore.shared
    @State private var message = ""
    @State private var contactEmail = ""
    @State private var isSubmitting = false
    @State private var submitted = false
    @State private var errorMessage: String?
    private let service = FeedbackService()

    var body: some View {
        Form {
            Section {
                TextField("What isn’t working properly?", text: $message, axis: .vertical)
                    .lineLimit(5...10)
                TextField("Email for a reply (optional)", text: $contactEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
            } header: {
                Text("问题描述")
            } footer: {
                Text("不要填写密码或其他敏感信息。")
            }

            Section("报告内容") {
                Toggle("附上诊断信息", isOn: $settings.includeDiagnosticsInReports)
                if settings.includeDiagnosticsInReports {
                    Text("包含 App 版本号、构建号、系统版本和机型，不包含提醒、地点或坐标。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if service.isConfigured {
                    Button(action: submit) {
                        if isSubmitting { ProgressView().frame(maxWidth: .infinity) }
                        else { Text("发送报告").frame(maxWidth: .infinity) }
                    }
                    .disabled(isSubmitting || cleanMessage.isEmpty)
                }

                ShareLink(item: service.shareText(
                    message: cleanMessage,
                    contactEmail: contactEmail,
                    includeDiagnostics: settings.includeDiagnosticsInReports
                )) {
                    Label(service.isConfigured ? "分享一份" : "分享报告", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .disabled(cleanMessage.isEmpty)
            } footer: {
                if !service.isConfigured {
                    Text("没有配置直接上报，iOS 会让你用邮件或其他 App 把报告发出去。")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(NearNoteBackground())
        .navigationTitle("反馈问题")
        .navigationBarTitleDisplayMode(.inline)
        .alert("报告已发送", isPresented: $submitted) {
            Button("好") { message = "" }
        } message: {
            Text("谢谢反馈。报告里没有带提醒或位置数据。")
        }
        .alert("报告没有发出去", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "可以改成分享一份报告。")
        }
    }

    private var cleanMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func submit() {
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                try await service.submit(
                    message: cleanMessage,
                    contactEmail: contactEmail.isEmpty ? nil : contactEmail,
                    includeDiagnostics: settings.includeDiagnosticsInReports
                )
                TelemetryService.shared.track(.feedbackSubmitted)
                submitted = true
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "可以改成分享一份报告。"
            }
        }
    }
}
