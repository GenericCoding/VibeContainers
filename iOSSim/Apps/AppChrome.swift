import SwiftUI

// MARK: - Scroll offset plumbing

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A scroll view that reports how far it has scrolled, so the nav bar can
/// collapse the way UIKit's large titles do.
struct TrackingScrollView<Content: View>: View {
    var showsIndicators = true
    var onOffset: (CGFloat) -> Void
    @ViewBuilder var content: Content

    /// A process-wide coordinate-space name lets two visible app surfaces
    /// report into one another while a window transition is in flight. Give
    /// every scroll view its own identity so its chrome only follows its own
    /// content.
    @Namespace private var scrollSpace

    var body: some View {
        ScrollView(showsIndicators: showsIndicators) {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollOffsetKey.self,
                        value: -geo.frame(in: .named(scrollSpace)).minY
                    )
                }
                .frame(height: 0)

                content
            }
        }
        .coordinateSpace(name: scrollSpace)
        .scrollDismissesKeyboard(.interactively)
        .onPreferenceChange(ScrollOffsetKey.self, perform: onOffset)
    }
}

// MARK: - Large-title screen

/// The standard iOS "large title that shrinks into a blurred bar" screen.
struct AppScaffold<Content: View, Trailing: View>: View {
    let title: String
    var background: AnyShapeStyle = AnyShapeStyle(SysColor.groupedBackground)
    var barTint: Color = SysColor.label
    var searchable = false
    var searchPlaceholder = "Search"
    @Binding var searchText: String
    var searchFocus: Binding<Bool>?
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    @Environment(\.deviceSafeArea) private var safeArea
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    /// Only the threshold crossing is stored, so scrolling doesn't write state
    /// on every frame.
    @State private var collapsed = false

    init(
        title: String,
        background: AnyShapeStyle = AnyShapeStyle(SysColor.groupedBackground),
        barTint: Color = SysColor.label,
        searchable: Bool = false,
        searchPlaceholder: String = "Search",
        searchText: Binding<String> = .constant(""),
        searchFocus: Binding<Bool>? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.background = background
        self.barTint = barTint
        self.searchable = searchable
        self.searchPlaceholder = searchPlaceholder
        self._searchText = searchText
        self.searchFocus = searchFocus
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(background).ignoresSafeArea()

            TrackingScrollView(onOffset: updateChrome) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(barTint)
                        .padding(.horizontal, 20)
                        .padding(.bottom, searchable ? 8 : 10)
                        .opacity(collapsed ? 0 : 1)
                        .offset(y: collapsed ? -5 : 0)

                    if searchable {
                        SearchField(text: $searchText,
                                    placeholder: searchPlaceholder,
                                    requestFocus: searchFocus)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }

                    content
                }
                .padding(.top, safeArea.top + 46)
                .padding(.bottom, safeArea.bottom + 24)
            }

            // Collapsed bar
            VStack(spacing: 0) {
                HStack {
                    Spacer(minLength: 0)
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(barTint)
                        .opacity(collapsed ? 1 : 0)
                    Spacer(minLength: 0)
                }
                .frame(height: 44)
                .overlay(alignment: .trailing) { trailing.padding(.trailing, 18) }
                .padding(.top, safeArea.top)
                .background {
                    // Keep the material mounted. Rebuilding a blur exactly at
                    // the collapse threshold causes a visible one-frame flash
                    // on older devices and while another app is animating.
                    ChromeBar()
                        .opacity(collapsed ? 1 : 0)
                        .allowsHitTesting(false)
                }
                Spacer(minLength: 0)
            }
            .animation(chromeAnimation, value: collapsed)

        }
    }

    /// Separate enter/exit thresholds stop the bar rapidly flipping states
    /// when a decelerating scroll view settles on the title boundary.
    private func updateChrome(_ offset: CGFloat) {
        guard offset.isFinite else { return }
        let shouldCollapse = collapsed ? offset > 22 : offset > 34
        guard shouldCollapse != collapsed else { return }
        withAnimation(chromeAnimation) { collapsed = shouldCollapse }
    }

    private var chromeAnimation: Animation {
        accessibilityReduceMotion
            ? .linear(duration: 0.01)
            : .easeOut(duration: 0.18)
    }
}

// MARK: - Pushed screen chrome

/// Inline nav bar with a back chevron, for detail screens.
struct InlineNavBar<Trailing: View>: View {
    let title: String
    var backTitle: String = "Back"
    var tint: Color = SysColor.blue
    var onBack: () -> Void
    @ViewBuilder var trailing: Trailing

    @Environment(\.deviceSafeArea) private var safeArea

    init(title: String,
         backTitle: String = "Back",
         tint: Color = SysColor.blue,
         onBack: @escaping () -> Void,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.backTitle = backTitle
        self.tint = tint
        self.onBack = onBack
        self.trailing = trailing()
    }

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SysColor.label)
                .lineLimit(1)
                .padding(.horizontal, 80)

            HStack {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                        Text(backTitle)
                            .font(.system(size: 17))
                            .lineLimit(1)
                    }
                    .foregroundStyle(tint)
                    .contentShape(Rectangle())
                }
                .buttonStyle(NavigationButtonStyle())
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 44)
        .padding(.top, safeArea.top)
        .background { ChromeBar() }
    }
}

// MARK: - Tab bar

struct TabItem: Identifiable {
    let title: String
    let symbol: String

    /// Several apps construct their tab array directly in `body`. A fresh UUID
    /// made every render discard SwiftUI's tab subtree (including press state)
    /// and was the source of intermittent icon flicker.
    var id: String { "\(symbol)|\(title)" }
}

struct AppTabBar: View {
    let items: [TabItem]
    @Binding var selection: Int
    var tint: Color = SysColor.blue

    @Environment(\.deviceSafeArea) private var safeArea
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button {
                    guard index != selection else { return }
                    Haptics.selection()
                    withAnimation(tabAnimation) { selection = index }
                } label: {
                    VStack(spacing: 3) {
                        ZStack {
                            Capsule()
                                .fill(tint.opacity(index == selection ? 0.13 : 0))
                                .frame(width: 38, height: 25)

                            Image(systemName: item.symbol)
                                .font(.system(size: 20, weight: index == selection ? .semibold : .regular))
                                .scaleEffect(index == selection ? 1.04 : 0.96)
                        }
                        .frame(height: 25)
                        Text(item.title)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(index == selection ? tint : SysColor.secondaryLabel)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TabButtonStyle())
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(index == selection ? .isSelected : [])
            }
        }
        .padding(.top, 8)
        .padding(.bottom, max(safeArea.bottom, 10))
        .background { ChromeBar(edge: .top) }
    }

    private var tabAnimation: Animation {
        accessibilityReduceMotion
            ? .linear(duration: 0.01)
            : .spring(response: 0.30, dampingFraction: 0.88)
    }
}

private struct NavigationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

private struct TabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

/// Native material bar with the same subtle separator UIKit uses.
struct ChromeBar: View {
    var edge: VerticalEdge = .bottom

    var body: some View {
        Rectangle()
            .fill(.regularMaterial)
            .overlay(alignment: edge == .bottom ? .bottom : .top) {
                Rectangle()
                    .fill(SysColor.separator)
                    .frame(height: 0.5)
            }
            .ignoresSafeArea()
    }
}

// MARK: - Inset grouped list

struct ListSection<Content: View>: View {
    var header: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let header {
                Text(header.uppercased())
                    .font(.system(size: 13))
                    .foregroundStyle(SysColor.secondaryLabel)
                    .padding(.horizontal, 32)
            }

            // Repository sections can contain thousands of rows. Keeping the
            // section lazy prevents off-screen rows (and their remote icons)
            // from being constructed until scrolling brings them into view.
            LazyVStack(spacing: 0) {
                content
            }
            .background(SysColor.secondaryGrouped)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)

            if let footer {
                Text(footer)
                    .font(.system(size: 13))
                    .foregroundStyle(SysColor.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
            }
        }
        .padding(.bottom, 26)
    }
}

/// One row of an inset grouped list, with the hairline separator inset to
/// match the leading content the way UIKit does it.
struct ListRow<Leading: View, Trailing: View>: View {
    var showsSeparator = true
    var separatorInset: CGFloat = 16
    var action: (() -> Void)?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(showsSeparator: Bool = true,
         separatorInset: CGFloat = 16,
         action: (() -> Void)? = nil,
         @ViewBuilder leading: () -> Leading,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.showsSeparator = showsSeparator
        self.separatorInset = separatorInset
        self.action = action
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        let row = HStack(spacing: 12) {
            leading
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if showsSeparator {
                Rectangle()
                    .fill(SysColor.separator)
                    .frame(height: 0.5)
                    .padding(.leading, separatorInset)
            }
        }

        if let action {
            Button(action: action) { row }
                .buttonStyle(RowButtonStyle())
        } else {
            row
        }
    }
}

private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? SysColor.tertiary : .clear)
            .opacity(configuration.isPressed ? 0.90 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(SysColor.secondaryLabel.opacity(0.8))
    }
}

// MARK: - Search field

struct SearchField: View {
    @Binding var text: String
    var placeholder = "Search"
    /// Set true to put the caret in the field. The field clears it once it has
    /// taken focus, so the request cannot fire twice.
    var requestFocus: Binding<Bool>?

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(SysColor.secondaryLabel)
            TextField(placeholder, text: $text)
                .font(.system(size: 17))
                .foregroundStyle(SysColor.label)
                .tint(SysColor.blue)
                .focused($focused)
            Button {
                withAnimation(.easeOut(duration: 0.14)) { text = "" }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(SysColor.secondaryLabel)
                    .frame(width: 22, height: 28)
            }
            .buttonStyle(.plain)
            .opacity(text.isEmpty ? 0 : 1)
            .scaleEffect(text.isEmpty ? 0.82 : 1)
            .allowsHitTesting(!text.isEmpty)
            .accessibilityHidden(text.isEmpty)
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(SysColor.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(SysColor.blue.opacity(focused ? 0.42 : 0), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.14), value: focused)
        .animation(.easeOut(duration: 0.14), value: text.isEmpty)
        .onAppear(perform: takeRequestedFocus)
        .onChange(of: requestFocus?.wrappedValue ?? false) { _, _ in takeRequestedFocus() }
    }

    private func takeRequestedFocus() {
        guard requestFocus?.wrappedValue == true else { return }
        // Off this update: the request usually arrives from the same pass that
        // is still building the field.
        DispatchQueue.main.async {
            focused = true
            requestFocus?.wrappedValue = false
        }
    }
}

// MARK: - Avatars

struct Avatar: View {
    let initials: String
    var tint: Color = SysColor.blue
    var size: CGFloat = 44

    var body: some View {
        Circle()
            .fill(
                LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
            )
            .frame(width: size, height: size)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(SysColor.label)
            )
    }
}
