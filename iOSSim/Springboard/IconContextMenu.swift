import SwiftUI

/// The long-press menu, built the way iOS builds it: the home screen falls
/// behind a full-screen material, the pressed icon is redrawn on top of that
/// blur so it stays sharp and lifted, and the panel springs out from the icon's
/// nearest corner.
struct IconContextMenu: View {
    let item: HomeItem
    /// The icon's frame in global coordinates.
    let iconFrame: CGRect
    let screen: CGSize
    var onEditHomeScreen: () -> Void
    var onRemove: () -> Void
    var onDismiss: () -> Void
    /// Opens the app on the screen the action names.
    var onQuickAction: (AppIntent) -> Void = { _ in }
    /// Guest-only: wipe the container, or open its LiveContainer page.
    var onGuestAction: (GuestAction) -> Void = { _ in }
    var onShare: () -> Void = {}

    enum GuestAction { case reset, info, addToHomeScreen }
    enum FolderAction { case open, rename }

    var onFolderAction: (FolderAction) -> Void = { _ in }

    @State private var presented = false
    @State private var backdropVisible = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private let panelWidth: CGFloat = 254
    private let rowHeight: CGFloat = 44

    private var reducesMotion: Bool {
        accessibilityReduceMotion || Appearance.shared.reduceMotion
    }

    /// Built-ins contribute their own shortcuts; a guest gets the two that
    /// mean something for a container.
    private var appRows: [MenuItem] {
        if item.isFolder {
            return [
                MenuItem(title: "Open Folder", symbol: "folder", kind: .folder(.open)),
                MenuItem(title: "Rename", symbol: "pencil", kind: .folder(.rename))
            ]
        }
        if let app = item.builtinApp {
            return app.quickActions.map {
                MenuItem(title: $0.title, symbol: $0.symbol, kind: .intent($0.intent))
            }
        }
        return [
            MenuItem(title: "Add to iOS Home Screen", symbol: "plus.square", kind: .guest(.addToHomeScreen)),
            MenuItem(title: "Reset Container", symbol: "arrow.counterclockwise", kind: .guest(.reset)),
            MenuItem(title: "App Info", symbol: "info.circle", kind: .guest(.info))
        ]
    }

    private var removeTitle: String {
        if item.isFolder { return "Delete Folder" }
        return item.builtinApp == nil ? "Uninstall" : "Remove App"
    }

    private var items: [MenuItem] {
        var rows = appRows
        rows.append(MenuItem(title: "Edit Home Screen", symbol: "square.grid.2x2", kind: .edit))
        // Nothing to share about a folder.
        if !item.isFolder {
            rows.append(MenuItem(title: "Share App", symbol: "square.and.arrow.up", kind: .share))
        }
        rows.append(MenuItem(title: removeTitle, symbol: "trash", kind: .destructive))
        return rows
    }

    private var panelHeight: CGFloat { CGFloat(items.count) * rowHeight }

    /// Below the icon when there is room, otherwise above it — dock icons and
    /// the bottom row always flip.
    private var opensDownward: Bool {
        iconFrame.maxY + 12 + panelHeight < screen.height - 40
    }

    private var panelOrigin: CGPoint {
        let x: CGFloat
        if iconFrame.midX < screen.width / 2 {
            x = max(14, iconFrame.minX - 6)
        } else {
            x = min(screen.width - panelWidth - 14, iconFrame.maxX + 6 - panelWidth)
        }
        let y = opensDownward ? iconFrame.maxY + 12 : iconFrame.minY - 12 - panelHeight
        return CGPoint(x: x, y: y)
    }

    private var growthAnchor: UnitPoint {
        let horizontal = iconFrame.midX < screen.width / 2 ? 0.15 : 0.85
        return UnitPoint(x: horizontal, y: opensDownward ? 0 : 1)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .opacity(backdropVisible ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            // The icon itself, lifted clear of the blur.
            Group {
                if let app = item.builtinApp {
                    IconArtwork(app: app, size: iconFrame.width)
                } else if let id = item.folderID,
                          let folder = HomeLayoutStore.shared.folder(id) {
                    FolderIcon(folder: folder, size: iconFrame.width)
                } else if let bundle = item.guestBundle {
                    PackageIcon(url: PackageStore.shared.installed[bundle]?.iconURL,
                                tint: nil, size: iconFrame.width)
                }
            }
                .scaleEffect(reducesMotion ? 1 : (presented ? 1.06 : 0.98))
                .shadow(color: .black.opacity(0.34), radius: 16, y: 8)
                .frame(width: iconFrame.width, height: iconFrame.height)
                .offset(x: iconFrame.minX, y: iconFrame.minY)
                .opacity(backdropVisible ? 1 : 0)

            panel
                .frame(width: panelWidth)
                .offset(
                    x: panelOrigin.x,
                    y: panelOrigin.y + revealOffset
                )
                .scaleEffect(
                    reducesMotion ? 1 : (presented ? 1 : 0.94),
                    anchor: growthAnchor
                )
                .opacity(backdropVisible ? 1 : 0)
        }
        .onAppear {
            Haptics.tap(.medium)
            withAnimation(motionAnimation(.easeOut(duration: 0.16))) {
                backdropVisible = true
            }
            withAnimation(motionAnimation(.interfaceSpring)) {
                presented = true
            }
        }
    }

    private var revealOffset: CGFloat {
        guard !reducesMotion, !presented else { return 0 }
        return opensDownward ? -8 : 8
    }

    private var panel: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button {
                    perform(item)
                } label: {
                    HStack {
                        Text(item.title)
                            .font(.system(size: 17))
                        Spacer(minLength: 12)
                        Image(systemName: item.symbol)
                            .font(.system(size: 17))
                    }
                    .foregroundStyle(item.isDestructive ? SysColor.red : SysColor.label)
                    .padding(.horizontal, 16)
                    .frame(height: rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuRowStyle())

                if index != items.count - 1 {
                    Rectangle()
                        .fill(SysColor.separator)
                        .frame(height: 0.5)
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.36), radius: 24, y: 10)
    }

    private func perform(_ item: MenuItem) {
        Haptics.tap(.light)
        switch item.kind {
        case .edit:
            dismiss(then: onEditHomeScreen)
        case .destructive:
            dismiss(then: onRemove)
        case .share:
            dismiss(then: onShare)
        case .intent(let intent):
            dismiss { onQuickAction(intent) }
        case .guest(let action):
            dismiss { onGuestAction(action) }
        case .folder(let action):
            dismiss { onFolderAction(action) }
        }
    }

    private func dismiss(then action: (() -> Void)? = nil) {
        guard presented || backdropVisible else { return }
        withAnimation(
            motionAnimation(.easeOut(duration: 0.16)),
            completionCriteria: .logicallyComplete
        ) {
            presented = false
            backdropVisible = false
        } completion: {
            onDismiss()
            action?()
        }
    }

    private func motionAnimation(_ animation: Animation) -> Animation {
        if accessibilityReduceMotion {
            .easeOut(duration: 0.16)
        } else {
            Appearance.shared.animation(animation)
        }
    }

    // MARK: - Items

    private struct MenuItem: Identifiable {
        let title: String
        let symbol: String
        let kind: Kind

        // `items` is derived whenever the view updates. A semantic identifier
        // keeps SwiftUI from tearing down and rebuilding every row mid-spring.
        var id: String { "\(title)|\(symbol)" }

        var isDestructive: Bool {
            if case .destructive = kind { return true }
            return false
        }

        enum Kind {
            case intent(AppIntent)
            case guest(GuestAction)
            case folder(FolderAction)
            case edit, share, destructive
        }
    }
}

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? SysColor.tertiary : .clear)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
