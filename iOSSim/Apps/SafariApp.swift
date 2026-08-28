import SwiftUI

struct SafariApp: View {
    @Environment(\.deviceSafeArea) private var safeArea
    @FocusState private var addressFocused: Bool

    @State private var address = ""
    @State private var keyboard: CGFloat = 0
    @State private var loadingPage: String?
    @State private var loadProgress: CGFloat = 0
    @State private var scrollTo: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            SysColor.groupedBackground.ignoresSafeArea()

            if let page = loadingPage {
                article(page)
            } else {
                startPage
            }

            addressBar
                .offset(y: -keyboard)
        }
        .keyboardHeight($keyboard)
        .onAppIntent(.safari) { intent in
            loadingPage = nil
            address = ""
            switch intent {
            case .safariNewTab: addressFocused = true
            case .safariReadingList: scrollTo = "readingList"
            default: break
            }
        }
    }

    // MARK: - Start page

    private var startPage: some View {
        ScrollViewReader { proxy in
            startPageContent
                .onChange(of: scrollTo) { _, target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    scrollTo = nil
                }
                .onAppear {
                    guard let target = scrollTo else { return }
                    proxy.scrollTo(target, anchor: .top)
                    scrollTo = nil
                }
        }
    }

    private var startPageContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Favorites")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SysColor.label)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4),
                          spacing: 20) {
                    ForEach(SafariData.favorites) { favorite in
                        Button {
                            Haptics.tap(.light)
                            open(favorite.title)
                        } label: {
                            VStack(spacing: 7) {
                                Image(systemName: favorite.symbol)
                                    .font(.system(size: 22))
                                    .foregroundStyle(SysColor.label)
                                    .frame(width: 60, height: 60)
                                    .background(
                                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                                            .fill(favorite.color)
                                    )
                                Text(favorite.title)
                                    .font(.system(size: 12))
                                    .foregroundStyle(SysColor.label)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Reading List")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SysColor.label)
                    .id("readingList")

                VStack(spacing: 0) {
                    ForEach(Array(SafariData.readingList.enumerated()), id: \.offset) { index, item in
                        Button {
                            open(item.0)
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(LinearGradient(colors: [SysColor.blue.opacity(0.7), SysColor.indigo],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 44, height: 44)
                                    .overlay(
                                        Image(systemName: "doc.richtext")
                                            .foregroundStyle(SysColor.label)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.0)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(SysColor.label)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text(item.1)
                                        .font(.system(size: 13))
                                        .foregroundStyle(SysColor.secondaryLabel)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .overlay(alignment: .bottom) {
                                if index != SafariData.readingList.count - 1 {
                                    Rectangle().fill(SysColor.separator).frame(height: 0.5).padding(.leading, 56)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .background(SysColor.secondaryGrouped)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal, 20)
            .padding(.top, safeArea.top + 24)
            .padding(.bottom, 130)
        }
    }

    // MARK: - Rendered "page"

    private func article(_ title: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: "8FAFC6"), Color(hex: "A78CB4")],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 180)
                    .overlay(
                        Image(systemName: "safari.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(SysColor.label.opacity(0.85))
                    )

                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(SysColor.label)

                Text("Published today · 4 min read")
                    .font(.system(size: 13))
                    .foregroundStyle(SysColor.secondaryLabel)

                ForEach(0..<4, id: \.self) { index in
                    Text(Self.paragraphs[index])
                        .font(.system(size: 17))
                        .foregroundStyle(SysColor.label.opacity(0.9))
                        .lineSpacing(5)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, safeArea.top + 20)
            .padding(.bottom, 130)
        }
    }

    private static let paragraphs = [
        "A launch animation has one job: to make the wait feel intentional. The best ones borrow from physics rather than from clocks, so the motion reads as a system waking up instead of a progress bar counting down.",
        "The springboard grid is deceptively simple. Four columns, a 22-point gutter, and icons whose corner curve is exactly 0.2237 of their width. Get any of those wrong and the whole page feels slightly off, even to people who could never tell you why.",
        "Opening an app is where the illusion lives or dies. The window has to grow out of the icon it came from, matching the corner radius the entire way, while the home screen falls back and blurs behind it.",
        "None of this requires new frameworks. Interpolate two rectangles, interpolate two radii, and let a spring carry the value between them."
    ]

    // MARK: - Chrome

    private var addressBar: some View {
        VStack(spacing: 0) {
            if loadProgress > 0 && loadProgress < 1 {
                GeometryReader { geo in
                    Rectangle()
                        .fill(SysColor.blue)
                        .frame(width: geo.size.width * loadProgress, height: 2)
                }
                .frame(height: 2)
            }

            HStack(spacing: 10) {
                Image(systemName: "textformat.size")
                    .font(.system(size: 15))
                    .foregroundStyle(SysColor.blue)

                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(SysColor.secondaryLabel)
                    TextField("Search or enter website name", text: $address)
                        .focused($addressFocused)
                        .font(.system(size: 15))
                        .foregroundStyle(SysColor.label)
                        .tint(SysColor.blue)
                        .multilineTextAlignment(address.isEmpty ? .center : .leading)
                        .submitLabel(.go)
                        .onSubmit {
                            guard !address.isEmpty else { return }
                            open(address)
                        }
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .frame(maxWidth: .infinity)
                .background(SysColor.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15))
                    .foregroundStyle(SysColor.blue)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            HStack {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        loadingPage = nil
                        address = ""
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(loadingPage == nil ? SysColor.secondaryLabel.opacity(0.5) : SysColor.blue)
                }
                .disabled(loadingPage == nil)

                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(SysColor.secondaryLabel.opacity(0.5))
                Spacer()
                Image(systemName: "square.and.arrow.up").foregroundStyle(SysColor.blue)
                Spacer()
                Image(systemName: "book").foregroundStyle(SysColor.blue)
                Spacer()
                Image(systemName: "square.on.square").foregroundStyle(SysColor.blue)
            }
            .font(.system(size: 20))
            .padding(.horizontal, 26)
            .padding(.bottom, keyboard > 0 ? 6 : max(safeArea.bottom, 10))
            .padding(.top, 2)
        }
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Rectangle().fill(SysColor.separator).frame(height: 0.5)
                }
                .ignoresSafeArea()
        }
    }

    private func open(_ title: String) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        address = title.lowercased().replacingOccurrences(of: " ", with: "") + ".com"
        loadProgress = 0
        withAnimation(.easeOut(duration: 0.15)) { loadProgress = 0.4 }
        withAnimation(.easeInOut(duration: 0.5).delay(0.15)) { loadProgress = 1 }
        withAnimation(.easeOut(duration: 0.25).delay(0.2)) { loadingPage = title }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { loadProgress = 0 }
    }
}
