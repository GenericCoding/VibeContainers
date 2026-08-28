import SwiftUI
import UIKit

/// The page to the left of the home screen: a feed reader, in the slot iOS
/// gives the Today View.
///
/// It lives inside the springboard's pager rather than being an app, so the
/// vertical scroll here has to coexist with the horizontal page swipe — which
/// SwiftUI resolves by axis on its own, as long as this view does not install a
/// competing drag gesture.
struct NewsPage: View {
    var topInset: CGFloat
    var bottomInset: CGFloat
    @Binding var interactionSuppressed: Bool
    var onLaunchWidget: (String) -> Void = { _ in }

    @State private var store = FeedStore.shared
    @State private var reading: FeedStore.Article?
    @State private var managing = false

    var body: some View {
        ZStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    ContainerWidgetsSection { bundleIdentifier in
                        guard !interactionSuppressed else { return }
                        onLaunchWidget(bundleIdentifier)
                    }

                    if store.articles.isEmpty {
                        empty
                    } else {
                        ForEach(store.articles.prefix(40)) { article in
                            ArticleCard(article: article) {
                                guard !interactionSuppressed else { return }
                                Haptics.tap(.light)
                                withAnimation(.appLaunch) { reading = article }
                            }
                        }
                    }

                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, topInset + 8)
                .padding(.bottom, bottomInset + 24)
                .allowsHitTesting(!interactionSuppressed)
            }

            if managing {
                SourcesSheet(store: store) {
                    withAnimation(.easeOut(duration: 0.18)) { managing = false }
                }
                .zIndex(2)
            }

            if let article = reading {
                ArticleReader(article: article) {
                    withAnimation(.appClose) { reading = nil }
                }
                .transition(.move(edge: .trailing))
                .zIndex(3)
            }
        }
        .onAppear {
            // The widgets section may initially be an EmptyView, so start its
            // first metadata scan from the always-present Today page.
            ContainerWidgetStore.shared.refresh()
        }
        .task {
            await store.refreshIfStale()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("News")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(SysColor.label)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(SysColor.secondaryLabel)
            }

            Spacer(minLength: 8)

            Button {
                guard !interactionSuppressed else { return }
                Haptics.tap(.light)
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SysColor.label)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.ultraThinMaterial))
                    .rotationEffect(.degrees(store.refreshing ? 360 : 0))
                    .animation(store.refreshing
                               ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                               : .default,
                               value: store.refreshing)
            }
            .buttonStyle(.plain)
            .disabled(store.refreshing)

            Button {
                guard !interactionSuppressed else { return }
                Haptics.tap(.light)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { managing = true }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SysColor.label)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.ultraThinMaterial))
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 2)
    }

    private var subtitle: String {
        if store.refreshing { return "Refreshing…" }
        if !store.failures.isEmpty {
            let count = store.failures.count
            return "\(count) source\(count == 1 ? "" : "s") failed to load"
        }
        guard let last = store.lastRefreshed else {
            return "\(store.sources.count) source\(store.sources.count == 1 ? "" : "s")"
        }
        return "Updated \(last.formatted(.relative(presentation: .named)))"
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.system(size: 34))
                .foregroundStyle(SysColor.secondaryLabel)
            Text(store.refreshing ? "Loading feeds…" : "Nothing to read yet")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(SysColor.label)
            Text(store.sources.isEmpty
                 ? "Add a feed with the list button above."
                 : "Pull the refresh button if this looks wrong.")
                .font(.system(size: 14))
                .foregroundStyle(SysColor.secondaryLabel)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    @ViewBuilder private var footer: some View {
        if !store.articles.isEmpty {
            Text("\(store.articles.count) articles from \(store.sources.count) source\(store.sources.count == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundStyle(SysColor.secondaryLabel.opacity(0.8))
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }
}

// MARK: - Card

private struct ArticleCard: View {
    let article: FeedStore.Article
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(article.sourceTitle.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SysColor.blue)
                        .lineLimit(1)
                    if !article.dateText.isEmpty {
                        Text("· \(article.dateText)")
                            .font(.system(size: 11))
                            .foregroundStyle(SysColor.secondaryLabel)
                            .lineLimit(1)
                    }
                }

                Text(article.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SysColor.label)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)

                if !article.summary.isEmpty {
                    Text(article.summary)
                        .font(.system(size: 14))
                        .foregroundStyle(SysColor.secondaryLabel)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Palette.paper.opacity(0.10), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reader

private struct ArticleReader: View {
    let article: FeedStore.Article
    var onClose: () -> Void

    @State private var copied = false
    @Environment(\.deviceSafeArea) private var safeArea

    var body: some View {
        ZStack(alignment: .top) {
            SysColor.groupedBackground

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(article.sourceTitle.uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SysColor.blue)

                    Text(article.title)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(SysColor.label)
                        .fixedSize(horizontal: false, vertical: true)

                    if !article.dateText.isEmpty {
                        Text(article.dateText)
                            .font(.system(size: 13))
                            .foregroundStyle(SysColor.secondaryLabel)
                    }

                    Rectangle().fill(SysColor.separator).frame(height: 0.5)

                    Text(article.summary.isEmpty
                         ? "This feed publishes headlines only. Open the link to read the article."
                         : article.summary)
                        .font(.system(size: 16))
                        .foregroundStyle(SysColor.label.opacity(0.92))
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)

                    if !article.link.isEmpty {
                        Button {
                            UIPasteboard.general.string = article.link
                            Haptics.tap(.medium)
                            withAnimation(.snappy) { copied = true }
                            Task {
                                try? await Task.sleep(for: .seconds(1.6))
                                withAnimation(.easeOut(duration: 0.25)) { copied = false }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: copied ? "checkmark" : "link")
                                Text(copied ? "Link copied" : article.link)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .font(.system(size: 14))
                            .foregroundStyle(copied ? SysColor.green : SysColor.blue)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(SysColor.secondaryGrouped)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, safeArea.top + 56)
                .padding(.bottom, 40)
            }

            // Keep the native status bar visible and place this page-local
            // navigation bar immediately beneath its real safe-area inset.
            Button(action: onClose) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                    Text("News").font(.system(size: 17))
                }
                .foregroundStyle(SysColor.blue)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .padding(.top, safeArea.top)
                .background {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(SysColor.separator).frame(height: 0.5)
                        }
                }
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Sources

private struct SourcesSheet: View {
    let store: FeedStore
    var onClose: () -> Void

    @State private var url = ""
    @State private var error: String?
    @State private var working = false
    @State private var shown = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Palette.ink.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture { if !working { onClose() } }

            VStack(spacing: 0) {
                Text("Feeds")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SysColor.label)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                if store.sources.isEmpty {
                    Text("No feeds yet.")
                        .font(.system(size: 14))
                        .foregroundStyle(SysColor.secondaryLabel)
                        .padding(.bottom, 14)
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.sources) { source in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.title)
                                        .font(.system(size: 15))
                                        .foregroundStyle(SysColor.label)
                                        .lineLimit(1)
                                    Text(store.failures[source.id] ?? source.host)
                                        .font(.system(size: 12))
                                        .foregroundStyle(store.failures[source.id] != nil
                                                         ? SysColor.red : SysColor.secondaryLabel)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Button {
                                    Haptics.tap(.rigid)
                                    withAnimation(.snappy) { store.remove(source) }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 17))
                                        .foregroundStyle(SysColor.red)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(SysColor.separator).frame(height: 0.5)
                                    .padding(.leading, 16)
                            }
                        }
                    }
                }

                VStack(spacing: 8) {
                    TextField("https://example.com/feed.xml", text: $url)
                        .font(.system(size: 15))
                        .foregroundStyle(SysColor.label)
                        .tint(SysColor.blue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .onSubmit(submit)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(SysColor.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                    if let error {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(SysColor.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 14)

                Rectangle().fill(SysColor.separator).frame(height: 0.5)

                HStack(spacing: 0) {
                    Button(action: onClose) {
                        Text("Done")
                            .font(.system(size: 17))
                            .foregroundStyle(SysColor.blue)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(working)

                    Rectangle().fill(SysColor.separator).frame(width: 0.5, height: 44)

                    Button(action: submit) {
                        HStack(spacing: 6) {
                            if working { ProgressView().scaleEffect(0.7) }
                            Text(working ? "Checking…" : "Add Feed")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(url.isEmpty ? SysColor.secondaryLabel : SysColor.blue)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(url.isEmpty || working)
                }
            }
            .frame(width: 300)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Palette.paper.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: Palette.ink.opacity(0.5), radius: 30, y: 12)
            .scaleEffect(shown ? 1 : 1.12)
            .opacity(shown ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { shown = true }
        }
    }

    private func submit() {
        guard !url.isEmpty, !working else { return }
        working = true
        error = nil
        Task {
            let result = await store.add(url: url)
            working = false
            switch result {
            case .added:
                Haptics.tap(.medium)
                url = ""
            case .failed(let message):
                error = message
            }
        }
    }
}
