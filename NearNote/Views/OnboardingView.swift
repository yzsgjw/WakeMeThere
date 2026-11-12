import SwiftUI

struct OnboardingView: View {
    @Binding var hasSeenOnboarding: Bool
    @State private var page = 0

    private let pages = [
        OnboardingPage(
            image: "onboarding_welcome",
            title: "把提醒放在\n真正重要的地方。",
            emphasizedPhrase: "真正重要的地方。",
            detail: "走进范围才提醒你，而不是到点就响的闹钟。"
        ),
        OnboardingPage(
            image: "onboarding_location",
            title: "选一个具体地点，\n或者附近任意同类地点。",
            emphasizedPhrase: "附近任意同类地点。",
            detail: "多久提醒、提醒多远，全部由你决定。"
        ),
        OnboardingPage(
            image: "onboarding_time",
            title: "纯本地。\n省电。\n不用注册。",
            emphasizedPhrase: "",
            detail: "数据只存在这台手机上，不上传，也不留位置历史。"
        )
    ]

    var body: some View {
        ZStack {
            NearNoteBackground()
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { index in
                        OnboardingPageView(item: pages[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 9) {
                    ForEach(pages.indices, id: \.self) { index in
                        Circle()
                            .fill(page == index ? NearNoteStyle.accent : .white.opacity(0.18))
                            .frame(width: 7, height: 7)
                    }
                }
                .padding(.vertical, 20)

                Button(page == pages.count - 1 ? "开始使用" : "继续") {
                    if page == pages.count - 1 {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation { hasSeenOnboarding = true }
                    } else {
                        withAnimation(.snappy) { page += 1 }
                    }
                }
                .font(.headline)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.bottom, 22)
            }
        }
        .tint(NearNoteStyle.accent)
    }
}

private struct OnboardingPageView: View {
    let item: OnboardingPage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(item.image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.top, 14)

            highlightedTitle
                .font(.system(size: 31, weight: .bold, design: .default))
                .tracking(-0.6)
                .lineSpacing(1)
                .padding(.top, 14)

            Text(item.detail)
                .font(.body)
                .foregroundStyle(NearNoteStyle.secondaryText)
                .lineSpacing(3)
                .padding(.top, 12)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 26)
    }

    private var highlightedTitle: Text {
        guard !item.emphasizedPhrase.isEmpty,
              let range = item.title.range(of: item.emphasizedPhrase) else {
            return Text(item.title)
        }
        let before = String(item.title[..<range.lowerBound])
        let emphasized = String(item.title[range])
        let after = String(item.title[range.upperBound...])
        return Text(before) + Text(emphasized).foregroundColor(NearNoteStyle.accent) + Text(after)
    }
}

private struct OnboardingPage {
    let image: String
    let title: String
    let emphasizedPhrase: String
    let detail: String
}

#Preview { OnboardingView(hasSeenOnboarding: .constant(false)) }
