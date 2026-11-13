import SwiftUI
import UIKit

/// 诊断日志页：设置 → 诊断日志。
/// 只做一件事——把到站链路的每一步按时间摊开，方便一眼看出去卡在哪一环。
struct DiagnosticsLogView: View {
    @StateObject private var log = DiagnosticsLog.shared
    @State private var justCopied = false

    var body: some View {
        ZStack {
            NearNoteBackground().ignoresSafeArea()

            if log.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(log.entries.reversed()) { entry in
                            row(entry)
                        }
                    }
                    .padding(.horizontal, NearNoteStyle.gutter)
                    .padding(.vertical, 14)
                }
            }
        }
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = log.plainText
                    justCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { justCopied = false }
                } label: {
                    Text(justCopied ? "已复制" : "复制")
                        .font(NearNoteStyle.Typeface.label)
                }
                .disabled(log.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    log.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(log.isEmpty)
            }
        }
    }

    private func row(_ entry: DiagnosticsLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.time)
                    .foregroundStyle(NearNoteStyle.textTertiary)
                Text(entry.tag)
                    .foregroundStyle(NearNoteStyle.accent)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))

            Text(entry.message)
                .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                .foregroundStyle(NearNoteStyle.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(NearNoteStyle.surface, in: RoundedRectangle(cornerRadius: NearNoteStyle.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NearNoteStyle.controlRadius, style: .continuous)
                .strokeBorder(NearNoteStyle.hairline, lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(NearNoteStyle.textTertiary)
            Text("还没有记录")
                .font(NearNoteStyle.Typeface.rowTitle)
                .foregroundStyle(NearNoteStyle.textPrimary)
            Text("打开追踪、走进圈里走一趟，这里会记下每一步的判定过程。")
                .font(NearNoteStyle.Typeface.micro)
                .foregroundStyle(NearNoteStyle.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }
}
