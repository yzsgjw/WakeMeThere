import SwiftUI
import CoreLocation
import UIKit

struct PermissionEducationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var notificationService: NotificationService

    var body: some View {
        NavigationStack {
        List {
                Section {
                    VStack(spacing: 12) {
                        Image("pebble_idle")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 132, height: 132)
                            .accessibilityHidden(true)
                        Text("到站才响，不耗电")
                            .font(.title.bold())
                            .multilineTextAlignment(.center)
                        Text("只申请必要的权限：在你到站的那一刻把提醒送到。")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 22, trailing: 20))
                }

                Section("权限") {
                    PermissionRow(
                        symbol: "bell.fill",
                        title: "通知",
                        detail: "到站时弹出提醒，可以直接「已完成」「稍后」「导航」。",
                        isReady: notificationService.isAuthorized,
                        actionTitle: "允许通知"
                    ) {
                        notificationService.requestPermission()
                    }

                    PermissionRow(
                        symbol: "location.fill",
                        title: "使用期间的定位",
                        detail: "用来判断离站点还有多远，也帮你在地图上选点。",
                        isReady: hasForegroundLocation,
                        actionTitle: "允许定位"
                    ) {
                        locationService.requestWhenInUsePermission()
                    }

                    PermissionRow(
                        symbol: "location.badge.checkmark",
                        title: "后台提醒",
                        detail: "App 退到后台或没开着，系统也能判断你是否进站，不需要一直定位。",
                        isReady: locationService.authorizationStatus == .authorizedAlways,
                        actionTitle: "开启后台提醒"
                    ) {
                        locationService.requestAlwaysPermission()
                    }
                }

                if locationService.authorizationStatus == .denied {
                    Section {
                        Button("打开系统设置", systemImage: "gear") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        }
                    } footer: {
                        Text("定位之前被拒绝过，需要到系统设置里改。")
                    }
                }

                Section {
                    Label("位置只在这台设备上处理，不会攒成历史轨迹。", systemImage: "lock.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("定位与提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(NearNoteBackground())
        .tint(NearNoteStyle.accent)
    }

    private var hasForegroundLocation: Bool {
        locationService.authorizationStatus == .authorizedWhenInUse ||
        locationService.authorizationStatus == .authorizedAlways
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let isReady: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: isReady ? "checkmark.circle.fill" : symbol)
                .font(.title3)
                .foregroundStyle(isReady ? NearNoteStyle.accent : NearNoteStyle.textSecondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !isReady {
                    Button(actionTitle, action: action)
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 5)
                }
            }
        }
        .padding(.vertical, 7)
    }
}
