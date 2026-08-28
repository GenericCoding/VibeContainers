import SwiftUI
import UIKit

struct SpringboardView: View {
    /// Flips true once the boot animation hands off; drives the icon entrance.
    var active: Bool

    @State private var layout = HomeLayoutStore.shared
    @State private var store = PackageStore.shared
    @State private var containerWidgets = ContainerWidgetStore.shared
    @State private var runningContainers = RunningContainerStore.shared
    /// Index into the pager, where 0 is the News page and the icon pages start
    /// at 1 — the same slot iOS gives the Today View.
    @State private var page = 1
    @State private var jiggling = false

    /// Rearranging. The carried icon is drawn by the springboard, not by the
    /// grid, so it can cross into the dock or onto another page.
    @State private var dragItem: HomeItem?
    @State private var dragPoint: CGPoint = .zero
    @State private var dragGrabOffset: CGPoint = .zero
    /// Where the drop would land. Nothing moves until the finger lifts: with
    /// free placement there is no queue to shuffle, so the grid stays still and
    /// the target slot is simply highlighted.
    @State private var dragTarget: HomeLayoutStore.Slot?
    /// The icon the drag has been hovering over long enough to merge into a
    /// folder, and when that hover started.
    @State private var mergeTarget: HomeLayoutStore.Slot?
    @State private var hoverSlot: HomeLayoutStore.Slot?
    @State private var mergeHoverToken = UUID()
    /// -1 is the left edge, 1 the right edge, and 0 means no edge hover.
    @State private var edgeDirection = 0
    @State private var edgeHoverToken = UUID()
    @State private var openFolder: UUID?
    @State private var folderFrame = IconFrameBox()
    @State private var dragSourceFolder: UUID?
    @State private var folderDropTarget = false
    @State private var folderDraggingOutside = false
    @State private var folderOpenedForDrag = false
    @State private var searching = false
    @State private var managingWidgets = false
    /// Disarms interactive page content after the pager commits to a
    /// horizontal swipe, so a WidgetKit tap cannot fire on touch-up.
    @State private var pageSwipeActive = false
    /// Plain boxes: written during layout, read from gestures. See IconFrameBox.
    @State private var frames = IconFrameRegistry()
    @State private var dockFrame = IconFrameBox()
    @State private var screenFrame = IconFrameBox()
    /// The host is edge-to-edge, so its environment inset may be sampled before
    /// the key window finishes layout. This observer follows the native window
    /// and is used only for home-screen geometry.
    @State private var springboardSafeArea: EdgeInsets?

    private var pages: [[HomeItem?]] { layout.pages }
    private var dock: [HomeItem] {
        Array(layout.dock.prefix(HomeLayoutStore.dockSlots))
    }

    /// Pager index → index into `pages`. Nil while the News page is showing.
    private var iconPage: Int? { page > 0 ? page - 1 : nil }
    private func pagerIndex(forIcon index: Int) -> Int { index + 1 }

    @State private var openApp: HomeItem?
    @State private var sourceFrame: CGRect = .zero
    @State private var openProgress: CGFloat = 0     // 0 = icon, 1 = fullscreen
    /// Animated separately from `openProgress` so the cross-fade can be short
    /// while the window's geometry takes the full spring.
    @State private var openRevealed = false
    /// Interactive retreat driven by AppWindow's bottom-edge home gesture.
    @State private var interactiveDismissal: CGFloat = 0
    /// Removes AppWindow's circular mask once the reveal has fully settled.
    @State private var appTransitionActive = false
    @State private var isClosingApp = false

    @State private var appeared = false

    @State private var menuApp: HomeItem?
    @State private var menuFrame: CGRect = .zero
    /// Brief confirmation for actions that have nowhere else to show a result.
    @State private var toast: String?
    /// Prevents a double tap on a Today-view widget from launching the same
    /// container twice while signing/bootstrap is still in progress.
    @State private var widgetLaunches: Set<String> = []

    @Environment(\.deviceSafeArea) private var safeArea
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    private var appearance: Appearance { Appearance.shared }
    private var homeSafeArea: EdgeInsets { springboardSafeArea ?? safeArea }
    private var motionDisabled: Bool {
        accessibilityReduceMotion || appearance.reduceMotion
    }

    private func transitionAnimation(_ animation: Animation) -> Animation {
        motionDisabled ? .reducedMotionFade : animation
    }

    var body: some View {
        GeometryReader { geo in
            let screen = geo.size
            let dismissalRetreat = motionDisabled ? 0 : interactiveDismissal
            let homeTransitionProgress = openProgress * (1 - dismissalRetreat * 0.16)

            ZStack {
                Wallpaper(size: screen)
                    .scaleEffect(motionDisabled ? 1 : 1 + homeTransitionProgress * 0.045)
                    .opacity(1 - homeTransitionProgress * 0.18)

                home(screen: screen)
                    // Spotlight opens on a downward swipe, so the gesture is
                    // simultaneous: the pager keeps its horizontal swipe and
                    // this only claims a drag that is clearly vertical.
                    .simultaneousGesture(searchGesture)
                    .simultaneousGesture(appSwitcherGesture(screenHeight: screen.height))
                    .scaleEffect(motionDisabled ? 1 : 1 + homeTransitionProgress * 0.05)
                    // Rides the cross-fade rather than the spring: the icons
                    // used to still be showing through the app's first frames.
                    .opacity(openRevealed ? dismissalRetreat * 0.72 : 1)
                    .allowsHitTesting(
                        openApp == nil && menuApp == nil && !runningContainers.isSwitcherPresented
                    )

                if let item = menuApp {
                    IconContextMenu(
                        item: item,
                        iconFrame: menuFrame,
                        screen: screen,
                        onEditHomeScreen: { beginEditing() },
                        onRemove: { remove(item) },
                        onDismiss: { menuApp = nil },
                        onQuickAction: { intent in run(intent, for: item) },
                        onGuestAction: { action in run(action, for: item) },
                        onShare: { share(item) },
                        onFolderAction: { action in run(action, for: item) }
                    )
                    .zIndex(1)
                }

                if searching {
                    SpringboardSearch(
                        onLaunch: { item in
                            launch(item, from: frames.rect(for: item) ?? .zero)
                        },
                        onOpenFolder: { id in openFolder = id },
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.2)) { searching = false }
                        }
                    )
                    .transition(.opacity.combined(with: .offset(y: -20)))
                    .zIndex(1.6)
                }

                if let id = openFolder, let folder = layout.folder(id) {
                    FolderView(
                        folder: folder,
                        columns: appearance.columns,
                        jiggling: jiggling,
                        carriedItem: dragItem,
                        dropHighlighted: folderDropTarget,
                        draggingOutside: folderDraggingOutside,
                        registry: frames,
                        frameBox: folderFrame,
                        onOpen: { item, rect in
                            openFolder = nil
                            launch(item, from: rect)
                        },
                        onEject: { item in
                            withAnimation(appearance.animation(.snappy)) {
                                layout.moveOutOfFolder(item, from: id, columns: appearance.columns)
                                if layout.folder(id) == nil { openFolder = nil }
                            }
                        },
                        onPickUp: { item, point in
                            pickUp(item, at: point, fromFolder: id)
                        },
                        onDragChange: { point in dragMoved(to: point) },
                        onDrop: { endDrag() },
                        onRename: { layout.renameFolder(id, to: $0) },
                        onDismiss: {
                            guard dragItem == nil else { return }
                            openFolder = nil
                        }
                    )
                    .zIndex(1.4)
                }

                if let item = dragItem {
                    dragGhost(item)
                        .zIndex(1.5)
                }

                if let toast {
                    Text(toast)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(SysColor.label)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .position(x: screen.width / 2, y: screen.height - safeArea.bottom - 96)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .zIndex(1.8)
                }

                if let item = openApp {
                    AppWindow(
                        item: item,
                        source: sourceFrame,
                        screen: screen,
                        progress: openProgress,
                        revealed: openRevealed,
                        dismissalProgress: $interactiveDismissal,
                        transitionActive: appTransitionActive,
                        onClose: close
                    )
                    .environment(\.dismissApp, close)
                    .zIndex(2)
                }

                if runningContainers.isSwitcherPresented {
                    ContainerSwitcherView(
                        entries: runningContainers.visibleEntries,
                        onFocus: focusContainer,
                        onTerminate: terminateContainer,
                        onRetry: retryContainer,
                        onHome: dismissContainerSwitcher
                    )
                    .zIndex(4)
                }
            }
            .frame(width: screen.width, height: screen.height)
            .background {
                SpringboardSafeAreaReader(insets: $springboardSafeArea)
                    .allowsHitTesting(false)
            }
            .recordGlobalFrame { screenFrame.rect = $0 }
        }
        .ignoresSafeArea()
        .onAppear {
            layout.normalize(columns: appearance.columns)
            syncGuests()
            refreshContainerWidgets()
#if DEBUG
            captureWidgetVerificationIfRequested()
#endif
        }
        .onChange(of: appearance.columns) { _, columns in
            // The grid under the icons just changed shape.
            withAnimation(appearance.animation(.snappy)) { layout.normalize(columns: columns) }
        }
        .onChange(of: store.installedList.map(\.bundleIdentifier)) { _, _ in
            syncGuests()
            refreshContainerWidgets()
        }
        .onChange(of: active) { _, isActive in
            guard isActive else { return }
            withAnimation(appearance.animation(.spring(response: 0.75, dampingFraction: 0.78))) { appeared = true }
        }
        .sheet(isPresented: $managingWidgets) {
            ContainerWidgetGallery(
                preferredPage: iconPage ?? 0,
                onPlaced: { item in
                    guard let destination = layout.slot(of: item)?.page else { return }
                    withAnimation(appearance.animation(.snappy)) {
                        page = pagerIndex(forIcon: destination)
                    }
                }
            )
        }
    }

#if DEBUG
    /// Device-console verification hook. It is completely inert in normal
    /// launches and absent from Release builds; Xcode can opt in when its
    /// external screenshot service is unavailable over a network pairing.
    @MainActor
    private func captureWidgetVerificationIfRequested() {
        guard ProcessInfo.processInfo.environment["VIBE_CAPTURE_WIDGET_RENDER"] == "1"
        else { return }
        if pages.count > 1 { page = 2 }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) else {
                NSLog("[WidgetRuntime] Visual verification could not find the key window.")
                return
            }
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = window.screen.scale
            let image = UIGraphicsImageRenderer(
                bounds: window.bounds,
                format: format
            ).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            guard let data = image.pngData(),
                  let documents = FileManager.default.urls(
                    for: .documentDirectory,
                    in: .userDomainMask
                  ).first else {
                NSLog("[WidgetRuntime] Visual verification could not encode the window.")
                return
            }
            let url = documents.appendingPathComponent(
                "vibe-widget-render-verification.png"
            )
            do {
                try data.write(to: url, options: .atomic)
                NSLog("[WidgetRuntime] Wrote visual verification to %@.", url.path)
            } catch {
                NSLog(
                    "[WidgetRuntime] Visual verification write failed: %@.",
                    error.localizedDescription
                )
            }
        }
    }
#endif

    // MARK: - Home screen

    private func home(screen: CGSize) -> some View {
        VStack(spacing: 0) {
            GeometryReader { area in
                PageSwitcher(
                    count: pages.count + 1,
                    index: $page,
                    style: appearance.pageTransition,
                    size: area.size,
                    pagingEnabled: !jiggling,
                    keepsPagesInteractive: dragItem != nil,
                    onHorizontalSwipeChanged: { pageSwipeActive = $0 }
                ) { index in
                    index == 0
                        // Pinned identity: the pages go through `AnyView`, and
                        // without this the News page is a fresh view on every
                        // springboard re-render — its scroll position, its open
                        // article and its in-flight refresh all reset.
                        ? AnyView(NewsPage(
                            topInset: homeSafeArea.top + 6,
                            bottomInset: 20,
                            interactionSuppressed: $pageSwipeActive,
                            onLaunchWidget: launchContainerWidget
                        ).id("news"))
                        : pageBody(index - 1)
                }
            }

            springboardIndicator
                .padding(.bottom, 14)
                .opacity(appeared ? 1 : 0)

            // Keep the dock present even when it has no icons. Besides matching
            // SpringBoard, its frame is the drop target that lets the first app
            // be dragged into an empty dock.
            dockBar
                // Keep the iPhone dock wide while preventing it from becoming
                // a full-width shelf on iPad and other multitasking canvases.
                .padding(.horizontal, max(12, (screen.width - 600) / 2))
                .padding(.bottom, max(homeSafeArea.bottom, 16))
                .offset(y: appeared ? 0 : 60)
                .opacity(appeared ? 1 : 0)
        }
        .frame(width: screen.width, height: screen.height)
        .overlay(alignment: .top) {
            if jiggling {
                HStack {
                    Button {
                        Haptics.tap(.light)
                        managingWidgets = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add widget")

                    Spacer()

                    Button("Done") { endEditing() }
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(Capsule().fill(.ultraThinMaterial))
                }
                .foregroundStyle(SysColor.label)
                .padding(.horizontal, 16)
                .padding(.top, homeSafeArea.top + 4)
            }
        }
    }

    /// Every page is the same thing: a grid of slots.
    private func pageBody(_ index: Int) -> AnyView {
        AnyView(
            GeometryReader { pageGeometry in
                let topPadding = homeSafeArea.top + (jiggling ? 46 : 26)
                let cellHeight: CGFloat = 80
                let preferredRowSpacing: CGFloat = 28
                let minimumRowSpacing: CGFloat = 9
                let rowCount = CGFloat(HomeLayoutStore.rows)
                let gapCount = CGFloat(max(1, HomeLayoutStore.rows - 1))
                let availableGridHeight = max(0, pageGeometry.size.height - topPadding)
                let rowSpacing = min(
                    preferredRowSpacing,
                    max(
                        minimumRowSpacing,
                        (availableGridHeight - cellHeight * rowCount) / gapCount
                    )
                )

                VStack(spacing: 0) {
                    iconGrid(
                        index,
                        startDelay: 0,
                        cellHeight: cellHeight,
                        rowSpacing: rowSpacing
                    )
                    Spacer(minLength: 0)
                }
                // Keep the first row comfortably below the native status bar.
                // Compact and Display Zoom canvases retain the requested row
                // separation instead of collapsing all six rows together. The
                // grid itself is raised while the indicator and dock stay put.
                .padding(.top, topPadding)
            }
        )
    }

    /// The grid draws a cell for every slot, occupied or not. An empty cell is
    /// still a drop target — that is what lets an icon be put anywhere on the
    /// page instead of only next to another one.
    private func iconGrid(
        _ pageIndex: Int,
        startDelay: Int,
        cellHeight: CGFloat,
        rowSpacing: CGFloat
    ) -> some View {
        let slots = pages.indices.contains(pageIndex) ? pages[pageIndex] : []
        let widgetAnchors = slots.enumerated().compactMap { index, item -> HomeWidgetAnchor? in
            guard let item, item.isWidget else { return nil }
            return HomeWidgetAnchor(index: index, item: item)
        }
        let totalHeight = cellHeight * CGFloat(HomeLayoutStore.rows)
            + rowSpacing * CGFloat(HomeLayoutStore.rows - 1)

        return GeometryReader { proxy in
            let horizontalInset: CGFloat = 20
            let contentWidth = max(1, proxy.size.width - horizontalInset * 2)
            let cellWidth = contentWidth / CGFloat(max(1, appearance.columns))
            let rowStride = cellHeight + rowSpacing

            ZStack(alignment: .topLeading) {
                ForEach(Array(slots.enumerated()), id: \.offset) { index, item in
                    let column = index % appearance.columns
                    let row = index / appearance.columns
                    slotCell(
                        page: pageIndex,
                        index: index,
                        item: item,
                        delay: index + startDelay
                    )
                    .frame(width: cellWidth, height: cellHeight)
                    .offset(
                        x: horizontalInset + CGFloat(column) * cellWidth,
                        y: CGFloat(row) * rowStride
                    )
                }

                ForEach(widgetAnchors) { placement in
                    let anchor = placement.index
                    let item = placement.item
                    let span = layout.span(for: item, columns: appearance.columns)
                    let column = anchor % appearance.columns
                    let row = anchor / appearance.columns
                    let width = cellWidth * CGFloat(span.columns) - 8
                    let height = cellHeight * CGFloat(span.rows)
                        + rowSpacing * CGFloat(span.rows - 1) - 4

                    placedWidget(
                        item,
                        size: CGSize(width: width, height: height)
                    )
                    .frame(width: width, height: height)
                    .offset(
                        x: horizontalInset + CGFloat(column) * cellWidth + 4,
                        y: CGFloat(row) * rowStride + 2
                    )
                }
            }
        }
        .frame(height: totalHeight)
    }

    @ViewBuilder
    private func slotCell(page pageIndex: Int, index: Int, item: HomeItem?, delay: Int) -> some View {
        let slot = HomeLayoutStore.Slot(page: pageIndex, index: index)
        let isMerge = mergeTarget == slot

        ZStack {
            if let item, !item.isWidget {
                AppIconView(
                    item: item,
                    showsLabel: appearance.showLabels,
                    jiggling: jiggling,
                    hidden: openApp == item,
                    carried: dragItem == item,
                    registry: frames,
                    onTap: { rect in open(item, from: rect) },
                    onLongPress: { rect in presentMenu(item, at: rect) },
                    onDelete: { remove(item) },
                    onPickUp: { point in pickUp(item, at: point) },
                    onDragChange: { point in dragMoved(to: point) },
                    onDrop: { endDrag() }
                )
                // Swelling under the finger is the folder's only warning that
                // letting go now will merge rather than swap.
                .scaleEffect(isMerge ? 1.18 : 1)
                .overlay {
                    if isMerge {
                        RoundedRectangle(cornerRadius: Metrics.iconCorner(for: 70), style: .continuous)
                            .strokeBorder(Palette.paper.opacity(0.8), lineWidth: 2)
                            .frame(width: 74, height: 74)
                    }
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isMerge)
                .scaleEffect(appeared ? 1 : 0.55)
                .opacity(appeared ? 1 : 0)
                .animation(
                    .spring(response: 0.55, dampingFraction: 0.72)
                        .delay(Double(delay) * 0.025),
                    value: appeared
                )
            } else {
                // Keeps the row height honest whether or not labels are shown.
                Color.clear
                    .frame(width: 60, height: appearance.showLabels ? 60 + 18 : 60)
            }
        }
        .recordGlobalFrame {
            frames.recordSlot($0, page: pageIndex, index: index)
        }
    }

    @ViewBuilder
    private func placedWidget(_ item: HomeItem, size: CGSize) -> some View {
        if let placement = layout.widget(for: item) {
            let descriptor = containerWidgets.discovered.first {
                $0.id == placement.descriptorID
            }
            PlacedContainerWidgetView(
                item: item,
                placement: placement,
                descriptor: descriptor,
                size: size,
                columns: appearance.columns,
                jiggling: jiggling,
                carried: dragItem == item,
                interactionSuppressed: pageSwipeActive,
                registry: frames,
                onOpen: {
                    guard let descriptor else { return }
                    launchContainerWidget(descriptor.ownerBundleIdentifier)
                },
                onBeginEditing: beginEditing,
                onDelete: { remove(item) },
                onPickUp: { point in pickUp(item, at: point) },
                onDragChange: dragMoved,
                onDrop: endDrag,
                canResize: { proposedSize in
                    layout.canResizeWidget(
                        item,
                        to: proposedSize,
                        columns: appearance.columns
                    )
                },
                onResize: { proposedSize in
                    withAnimation(appearance.animation(.snappy)) {
                        layout.resizeWidget(
                            item,
                            to: proposedSize,
                            columns: appearance.columns
                        )
                    }
                }
            )
            .scaleEffect(appeared ? 1 : 0.82)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: appeared)
        }
    }

    private var dockBar: some View {
        HStack(spacing: 0) {
            ForEach(0..<HomeLayoutStore.dockSlots, id: \.self) { index in
                if dock.indices.contains(index) {
                    let item = dock[index]
                    AppIconView(
                        item: item,
                        showsLabel: false,
                        jiggling: jiggling,
                        hidden: openApp == item,
                        carried: dragItem == item,
                        registry: frames,
                        onTap: { rect in open(item, from: rect) },
                        onLongPress: { rect in presentMenu(item, at: rect) },
                        onDelete: { remove(item) },
                        onPickUp: { point in pickUp(item, at: point) },
                        onDragChange: { point in dragMoved(to: point) },
                        onDrop: { endDrag() }
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
            }
        }
        // The dock material must not participate in an icon replacement's
        // intrinsic-size animation. A minimum height still lets a transitioning
        // slot temporarily grow the HStack, which makes the whole dock balloon
        // while an app is moved in, out, or reordered.
        .frame(maxWidth: .infinity)
        .frame(height: 60)
        .padding(.vertical, 11)
        .padding(.horizontal, 8)
        .recordGlobalFrame { dockFrame.rect = $0 }
        .background {
            if !appearance.hideDockBackground {
                GlassSurface(cornerRadius: 34)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .strokeBorder(
                    Palette.paper.opacity(dragItem != nil && dragTarget?.page == nil ? 0.42 : 0),
                    lineWidth: 1.5
                )
        }
    }

    @ViewBuilder
    private var springboardIndicator: some View {
        HStack(spacing: 10) {
            if pages.count == 1, iconPage != nil {
                Button {
                    Haptics.tap(.light)
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { searching = true }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                // The dots count icon pages only; News sits to their left.
                PageDots(count: pages.count, index: iconPage ?? -1, showsLeadingPage: true)
            }

            if runningContainers.activeCount > 0 {
                Button(action: presentContainerSwitcher) {
                    Label(
                        "\(runningContainers.activeCount)",
                        systemImage: "rectangle.3.group.fill"
                    )
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.94))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open container app switcher")
            }
        }
    }

    // MARK: - Search

    /// A pull down anywhere on an icon page opens search.
    ///
    /// Deliberately not available on the News page, whose scroll view owns
    /// vertical drags, nor while rearranging, when a drag means something else
    /// entirely.
    private var searchGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard !searching, !jiggling,
                      openApp == nil, menuApp == nil, openFolder == nil,
                      dragItem == nil, iconPage != nil else { return }

                let vertical = value.translation.height
                guard vertical > 55, vertical > abs(value.translation.width) * 1.5 else { return }

                Haptics.tap(.light)
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { searching = true }
            }
    }

    /// The host-side equivalent of iPhone's home gesture. It is intentionally
    /// restricted to the bottom edge and disabled while icons or folders own a
    /// drag, so it cannot steal Springboard rearrangement or page swipes.
    private func appSwitcherGesture(screenHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .global)
            .onEnded { value in
                guard runningContainers.activeCount > 0,
                      !runningContainers.isSwitcherPresented,
                      !searching, !jiggling,
                      menuApp == nil, openFolder == nil, dragItem == nil,
                      value.startLocation.y > screenHeight - max(86, safeArea.bottom + 54),
                      value.translation.height < -54,
                      abs(value.translation.height) > abs(value.translation.width) * 1.25
                else { return }

                presentContainerSwitcher()
            }
    }

    // MARK: - Rearranging

    /// A tap either opens a folder or launches an app.
    private func open(_ item: HomeItem, from rect: CGRect) {
        guard !item.isWidget else { return }
        if let id = item.folderID {
            guard layout.folder(id) != nil else { return }
            Haptics.tap(.light)
            folderFrame.rect = .zero
            folderOpenedForDrag = false
            openFolder = id
        } else {
            launch(item, from: rect)
        }
    }

    private func beginEditing() {
        searching = false
        withAnimation(appearance.animation(.snappy)) {
            jiggling = true
            // iOS always keeps one empty page to the right while you rearrange,
            // so there is somewhere to drag an icon *to*.
            layout.ensureSparePage(columns: appearance.columns)
        }
    }

    private func endEditing() {
        clearDragState()
        withAnimation(appearance.animation(.snappy)) {
            jiggling = false
            layout.pruneEmptyPages()
            page = min(page, layout.pages.count)
        }
    }

    /// The icon under the finger, drawn by the springboard so it can be carried
    /// past the edges of the grid it came from.
    private func dragGhost(_ item: HomeItem) -> some View {
        Group {
            if let app = item.builtinApp {
                IconArtwork(app: app, size: 60)
            } else if let bundle = item.guestBundle {
                PackageIcon(url: store.installed[bundle]?.iconURL, tint: nil, size: 60)
            } else if let id = item.folderID, let folder = layout.folder(id) {
                FolderIcon(folder: folder, size: 60)
            } else if let placement = layout.widget(for: item) {
                let descriptor = containerWidgets.discovered.first {
                    $0.id == placement.descriptorID
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                    HStack(spacing: 10) {
                        PackageIcon(url: descriptor?.iconURL, tint: nil, size: 42)
                        Text(descriptor?.extensionName ?? "Widget")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SysColor.label)
                            .lineLimit(2)
                    }
                    .padding(12)
                }
                .frame(width: max(120, frames.rect(for: item)?.width ?? 160),
                       height: max(90, frames.rect(for: item)?.height ?? 140))
            }
        }
        .scaleEffect(1.15)
        .shadow(color: Palette.ink.opacity(0.5), radius: 14, y: 8)
        .position(dragGhostPosition(for: item))
        .allowsHitTesting(false)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private func pickUp(_ item: HomeItem, at point: CGPoint, fromFolder folderID: UUID? = nil) {
        guard openApp == nil, menuApp == nil else { return }
        dragSourceFolder = folderID
        folderDropTarget = false
        folderDraggingOutside = false
        folderOpenedForDrag = false
        if item.isWidget, let rect = frames.rect(for: item) {
            dragGrabOffset = CGPoint(x: point.x - rect.minX, y: point.y - rect.minY)
        } else {
            dragGrabOffset = .zero
        }
        dragPoint = point
        withAnimation(.easeOut(duration: 0.12)) { dragItem = item }
    }

    private func dragGhostPosition(for item: HomeItem) -> CGPoint {
        guard item.isWidget, let rect = frames.rect(for: item) else { return dragPoint }
        return CGPoint(
            x: dragPoint.x - dragGrabOffset.x + rect.width / 2,
            y: dragPoint.y - dragGrabOffset.y + rect.height / 2
        )
    }

    /// Tracks the finger and marks where the icon would land.
    ///
    /// Nothing is moved until the drop. With free placement there is no queue to
    /// keep in order, so a live reshuffle would only be churn — and it would
    /// tear the dragged icon's own view (and the touch it is holding) out of the
    /// hierarchy it was created in the moment it crossed into the dock.
    ///
    /// Resting on top of another icon for a beat arms a merge instead of a swap.
    private func dragMoved(to point: CGPoint) {
        guard let item = dragItem else { return }
        dragPoint = point

        if let folderID = openFolder, folderFrame.rect != .zero {
            let isInsideFolder = folderFrame.rect.insetBy(dx: -14, dy: -14).contains(point)

            if dragSourceFolder == folderID {
                folderDropTarget = false
                folderDraggingOutside = !isInsideFolder
                if isInsideFolder {
                    dragTarget = nil
                    clearMergeHover()
                    cancelEdgeHover()
                    return
                }
            } else if !item.isFolder && !item.isWidget {
                folderDropTarget = isInsideFolder
                folderDraggingOutside = !isInsideFolder
                if isInsideFolder {
                    dragTarget = nil
                    clearMergeHover()
                    cancelEdgeHover()
                    return
                }
            }
        }

        if schedulePageFlipIfHoveringEdge(at: point, carrying: item) {
            dragTarget = nil
            clearMergeHover()
            return
        }

        guard let target = dropSlot(at: point, for: item) else {
            dragTarget = nil
            clearMergeHover()
            return
        }
        if target != dragTarget {
            dragTarget = target
            Haptics.selection()
        }
        trackMergeHover(over: target, carrying: item)
    }

    /// A drop onto an occupied slot swaps; a drop onto one the finger has been
    /// resting on makes a folder of the two.
    private func trackMergeHover(over target: HomeLayoutStore.Slot, carrying item: HomeItem) {
        let occupant = layout.itemCovering(target, columns: appearance.columns)
        let mergeable = occupant != nil && occupant != item
            && !item.isFolder && !item.isWidget && occupant?.isWidget != true

        guard mergeable else {
            clearMergeHover()
            return
        }

        if hoverSlot != target {
            hoverSlot = target
            let token = UUID()
            mergeHoverToken = token
            if mergeTarget != nil { withAnimation(.easeOut(duration: 0.15)) { mergeTarget = nil } }

            // DragGesture does not emit updates while a finger is perfectly
            // still. Arm the folder after the dwell time independently so a
            // steady hold is just as reliable as a slightly moving one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard mergeHoverToken == token,
                      dragItem == item,
                      hoverSlot == target,
                      let current = layout.itemCovering(target, columns: appearance.columns),
                      current != item else { return }

                if let folderID = current.folderID, dragSourceFolder == nil {
                    // Open an existing folder under the carried icon without
                    // ending its gesture. The same global drag can now cross
                    // the panel boundary and drop directly into the folder.
                    mergeHoverToken = UUID()
                    hoverSlot = nil
                    mergeTarget = nil
                    dragTarget = nil
                    folderFrame.rect = .zero
                    folderDropTarget = false
                    folderDraggingOutside = false
                    folderOpenedForDrag = true
                    withAnimation(appearance.animation(.snappy)) { openFolder = folderID }
                    Haptics.tap(.medium)
                    return
                }

                withAnimation(.spring(response: 0.25, dampingFraction: 0.76)) {
                    mergeTarget = target
                }
                Haptics.tap(.medium)
            }
            return
        }
    }

    private func endDrag() {
        guard let item = dragItem else { return }
        cancelEdgeHover()
        mergeHoverToken = UUID()
        hoverSlot = nil

        let sourceFolder = dragSourceFolder
        let returnPoint = frames.rect(for: item).map { rect in
            item.isWidget
                ? CGPoint(x: rect.minX + dragGrabOffset.x,
                          y: rect.minY + dragGrabOffset.y)
                : CGPoint(x: rect.midX, y: rect.midY)
        }
        let requestedTarget = dragTarget
        var settledPoint: CGPoint?
        if let requestedTarget {
            settledPoint = landingPoint(for: requestedTarget, carrying: item)
        }

        var landed = true
        var createdFolder: UUID?
        var closeFolderAfterDrop = false

        if folderDropTarget,
           let destinationFolder = openFolder,
           destinationFolder != sourceFolder,
           !item.isFolder,
           !item.isWidget {
            withAnimation(appearance.animation(.spring(response: 0.34, dampingFraction: 0.82))) {
                if let sourceFolder {
                    landed = layout.move(item, fromFolder: sourceFolder,
                                         toFolder: destinationFolder,
                                         columns: appearance.columns)
                } else {
                    layout.addToFolder(destinationFolder, item: item)
                    landed = layout.folder(destinationFolder)?.items.contains(item) == true
                }
            }
            let rect = folderFrame.rect
            settledPoint = rect == .zero ? settledPoint : CGPoint(x: rect.midX, y: rect.midY + 18)
            Haptics.tap(landed ? .medium : .rigid)
        } else if let sourceFolder {
            if let target = dragTarget,
               let destinationFolder = layout.itemCovering(
                    target,
                    columns: appearance.columns
               )?.folderID,
               destinationFolder != sourceFolder {
                withAnimation(appearance.animation(.spring(response: 0.34, dampingFraction: 0.82))) {
                    landed = layout.move(item, fromFolder: sourceFolder,
                                         toFolder: destinationFolder,
                                         columns: appearance.columns)
                }
                closeFolderAfterDrop = landed
            } else if let target = dragTarget {
                withAnimation(appearance.animation(.spring(response: 0.34, dampingFraction: 0.82))) {
                    landed = layout.move(item, fromFolder: sourceFolder,
                                         to: target, columns: appearance.columns)
                }
                closeFolderAfterDrop = landed
            } else {
                settledPoint = returnPoint
            }
            Haptics.tap(landed ? .light : .rigid)
        } else if let merge = mergeTarget,
                  let target = layout.itemCovering(merge, columns: appearance.columns),
                  target != item,
                  !target.isWidget,
                  !item.isWidget {
            withAnimation(appearance.animation(.spring(response: 0.34, dampingFraction: 0.8))) {
                createdFolder = layout.combine(item, onto: target)
            }
            Haptics.tap(.medium)
        } else if let target = dragTarget, layout.slot(of: item) != target {
            withAnimation(appearance.animation(.spring(response: 0.34, dampingFraction: 0.82))) {
                landed = layout.move(item, to: target, columns: appearance.columns)
            }
            Haptics.tap(landed ? .light : .rigid)
        }

        if !landed {
            settledPoint = returnPoint
        }
        if folderOpenedForDrag, !folderDropTarget { closeFolderAfterDrop = true }
        let folderToOpen = createdFolder
        let shouldCloseFolder = closeFolderAfterDrop

        guard let settledPoint else {
            clearDragState()
            if shouldCloseFolder { openFolder = nil }
            if let folderToOpen { openFolder = folderToOpen }
            return
        }

        // Keep the real icon hidden while the carried copy settles into the
        // exact destination. Revealing it in the spring's completion avoids a
        // one-frame duplicate and makes dock/page drops feel continuous.
        withAnimation(appearance.animation(.spring(response: 0.28, dampingFraction: 0.88)),
                      completionCriteria: .logicallyComplete) {
            dragPoint = settledPoint
        } completion: {
            guard dragItem == item else { return }
            clearDragState()
            if shouldCloseFolder {
                withAnimation(appearance.animation(.snappy)) { openFolder = nil }
            }
            if let folderToOpen {
                withAnimation(appearance.animation(.snappy)) { openFolder = folderToOpen }
            }
        }
    }

    private func clearMergeHover() {
        guard hoverSlot != nil || mergeTarget != nil else { return }
        mergeHoverToken = UUID()
        hoverSlot = nil
        if mergeTarget != nil {
            withAnimation(.easeOut(duration: 0.14)) { mergeTarget = nil }
        }
    }

    private func clearDragState() {
        cancelEdgeHover()
        mergeHoverToken = UUID()
        dragItem = nil
        dragTarget = nil
        mergeTarget = nil
        hoverSlot = nil
        dragSourceFolder = nil
        folderDropTarget = false
        folderDraggingOutside = false
        folderOpenedForDrag = false
        dragGrabOffset = .zero
    }

    /// The final centre used by the carried icon's settle animation.
    private func landingPoint(for slot: HomeLayoutStore.Slot, carrying item: HomeItem) -> CGPoint? {
        if let page = slot.page {
            guard let rect = frames.slotRects(page: page).first(where: { $0.index == slot.index })?.rect else {
                return nil
            }
            if item.isWidget {
                return CGPoint(
                    x: rect.minX + dragGrabOffset.x,
                    y: rect.minY + dragGrabOffset.y
                )
            }
            return CGPoint(x: rect.midX, y: rect.midY)
        }

        let rect = dockFrame.rect
        guard rect != .zero else { return nil }
        let slotCount = layout.dockCapacity(columns: appearance.columns)
        guard slotCount > 0 else { return CGPoint(x: rect.midX, y: rect.midY) }

        let index = min(max(0, slot.index), slotCount - 1)
        let contentWidth = max(1, rect.width - 16)
        let cellWidth = contentWidth / CGFloat(slotCount)
        return CGPoint(x: rect.minX + 8 + cellWidth * (CGFloat(index) + 0.5), y: rect.midY)
    }

    /// Where the icon would land if it were dropped now.
    private func dropSlot(at point: CGPoint, for item: HomeItem) -> HomeLayoutStore.Slot? {
        // The dock claims anything below its top edge.
        let dockRect = dockFrame.rect
        if dockRect != .zero, point.y > dockRect.minY {
            guard !item.isWidget else { return nil }
            let others = dock.filter { $0 != item }
            let ahead = others.filter { (frames.rect(for: $0)?.midX ?? .infinity) < point.x }.count
            return HomeLayoutStore.Slot(page: nil, index: ahead)
        }

        guard let iconPage, pages.indices.contains(iconPage) else { return nil }

        // Nearest slot centre wins, empty slots included — that is what makes
        // the gaps real targets.
        let desiredWidgetOrigin = CGPoint(
            x: point.x - dragGrabOffset.x,
            y: point.y - dragGrabOffset.y
        )
        var best: (index: Int, distance: CGFloat)?
        for (index, rect) in frames.slotRects(page: iconPage) {
            let slot = HomeLayoutStore.Slot(page: iconPage, index: index)
            guard layout.canMove(item, to: slot, columns: appearance.columns) else { continue }
            let dx = item.isWidget
                ? rect.minX - desiredWidgetOrigin.x
                : rect.midX - point.x
            let dy = item.isWidget
                ? rect.minY - desiredWidgetOrigin.y
                : rect.midY - point.y
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        guard let best else { return nil }
        return HomeLayoutStore.Slot(page: iconPage, index: best.index)
    }

    /// Holding an icon against the side of the screen turns the page, then
    /// takes the icon with it.
    private func schedulePageFlipIfHoveringEdge(at point: CGPoint, carrying item: HomeItem) -> Bool {
        let screenRect = screenFrame.rect
        let minX = screenRect == .zero ? 0 : screenRect.minX
        let maxX = screenRect == .zero ? 393 : screenRect.maxX
        let margin: CGFloat = 34
        let goingLeft = point.x < minX + margin
        let goingRight = point.x > maxX - margin
        guard goingLeft || goingRight, point.y < (dockFrame.rect.minY == 0 ? .infinity : dockFrame.rect.minY) else {
            cancelEdgeHover()
            return false
        }

        let direction = goingLeft ? -1 : 1
        if edgeDirection != direction {
            edgeDirection = direction
            schedulePageFlip(direction: direction, carrying: item, after: 0.38)
        }
        return true
    }

    private func schedulePageFlip(direction: Int, carrying item: HomeItem, after delay: TimeInterval) {
        let token = UUID()
        edgeHoverToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard edgeHoverToken == token,
                  edgeDirection == direction,
                  dragItem == item,
                  let iconPage else { return }

            // Icon-page space: an icon can never be carried onto the News
            // page. A continued edge hold advances through further icon pages.
            let destination = iconPage + direction
            guard pages.indices.contains(destination) else { return }

            clearMergeHover()
            dragTarget = nil
            // Only the page turns. The icon stays in the page it came from
            // until the drop, so its view — and its touch — survive.
            withAnimation(appearance.animation(.spring(response: 0.38, dampingFraction: 0.88))) {
                page = pagerIndex(forIcon: destination)
            }
            Haptics.tap(.medium)

            // Geometry readers update after the page starts settling. Resolve
            // a destination on the new page even if the user's finger stays
            // perfectly still and lifts without another DragGesture update.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard dragItem == item,
                      edgeDirection == direction,
                      let target = dropSlot(at: dragPoint, for: item) else { return }
                dragTarget = target
                trackMergeHover(over: target, carrying: item)
            }
            schedulePageFlip(direction: direction, carrying: item, after: 0.58)
        }
    }

    private func cancelEdgeHover() {
        guard edgeDirection != 0 else { return }
        edgeDirection = 0
        edgeHoverToken = UUID()
    }

    // MARK: - Context menu

    private func presentMenu(_ item: HomeItem, at rect: CGRect) {
        guard openApp == nil, menuApp == nil else { return }
        menuFrame = rect
        menuApp = item
    }

    /// A quick action opens the app, the same as tapping the icon, and leaves
    /// the intent for it to pick up as it appears.
    private func run(_ intent: AppIntent, for item: HomeItem) {
        IntentRouter.shared.send(intent)
        launch(item, from: frames.rect(for: item) ?? menuFrame)
    }

    private func run(_ action: IconContextMenu.GuestAction, for item: HomeItem) {
        if action == .addToHomeScreen, let bundle = item.guestBundle {
            let name = store.installed[bundle]?.name ?? bundle
            HomeScreenShortcutInstaller.shared.beginInstall(
                bundleIdentifier: bundle,
                displayName: name
            ) { result in
                switch result {
                case .success:
                    showToast("Allow the profile in Safari, then install it in Settings")
                case .failure(let error):
                    showToast(error.localizedDescription)
                }
            }
            return
        }
        if action == .reset, let bundle = item.guestBundle {
            GuestContainerStore.shared.reset(bundle)
            Haptics.tap(.rigid)
        }
        // Both land on the container page: it is the guest's App Info screen,
        // and after a reset it is where the state is visible.
        launch(item, from: frames.rect(for: item) ?? menuFrame)
    }

    private func run(_ action: IconContextMenu.FolderAction, for item: HomeItem) {
        guard let id = item.folderID else { return }
        openFolder = id
        // Renaming is only possible while the home screen is editable, so the
        // menu item puts the screen in that state on the way in.
        if action == .rename { beginEditing() }
    }

    /// iOS opens a share sheet here. There is no App Store link to hand out for
    /// a simulated app, so the nearest honest thing is to put one on the
    /// clipboard and say so.
    private func share(_ item: HomeItem) {
        let name = item.builtinApp?.title
            ?? store.installed[item.guestBundle ?? ""]?.name
            ?? "App"
        let link = item.builtinApp != nil
            ? "iossim://app/\(item.builtinApp!.rawValue)"
            : "iossim://guest/\(item.guestBundle ?? "")"
        UIPasteboard.general.string = link
        Haptics.tap(.medium)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
            toast = "Link to \(name) copied"
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }

    // MARK: - Launch / close

    /// A real WidgetKit tap opens its owning app. Match that interaction for
    /// discovered container widgets instead of detouring through App Info.
    private func launchContainerWidget(_ bundleIdentifier: String) {
        guard !widgetLaunches.contains(bundleIdentifier),
              let container = GuestContainerStore.shared.container(for: bundleIdentifier),
              GuestContainerStore.shared.hasPayload(container) else {
            showToast("That container is not ready to launch")
            return
        }

        widgetLaunches.insert(bundleIdentifier)
        Task {
            let outcome = await GuestInstaller.shared.launch(container)
            widgetLaunches.remove(bundleIdentifier)
            if !outcome.ok { showToast(outcome.headline) }
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard toast == message else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }

    private func focusContainer(_ entry: RunningContainerStore.Entry) {
        // Commit removal of the host overlay before synchronously asking
        // FrontBoard to raise the guest. This prevents the outgoing switcher
        // from flashing over, or intercepting the first touch in, that scene.
        dismissContainerSwitcher()
        Task { @MainActor in
            await Task.yield()
            guard runningContainers.focus(entry) else {
                showToast("That container process is no longer available")
                return
            }
        }
    }

    private func presentContainerSwitcher() {
        guard !runningContainers.isSwitcherPresented else { return }
        Haptics.tap(.light)
        if runningContainers.presentCapturedSwitcher() { return }
        withAnimation(
            appearance.animation(.spring(response: 0.28, dampingFraction: 0.94))
        ) {
            runningContainers.presentSwitcher()
        }
    }

    private func terminateContainer(_ entry: RunningContainerStore.Entry) -> Bool {
        withAnimation(appearance.animation(.easeOut(duration: 0.16))) {
            runningContainers.terminate(entry)
        }
    }

    private func retryContainer(_ entry: RunningContainerStore.Entry) {
        dismissContainerSwitcher()
        guard let container = GuestContainerStore.shared.container(for: entry.bundleIdentifier) else {
            showToast("That container is no longer installed")
            return
        }
        Task {
            let outcome = await GuestInstaller.shared.launch(container)
            if !outcome.ok { showToast(outcome.detail) }
        }
    }

    private func dismissContainerSwitcher() {
        withAnimation(appearance.animation(.easeOut(duration: 0.18))) {
            runningContainers.dismissSwitcher()
        }
    }

    private func launch(_ item: HomeItem, from rect: CGRect) {
        guard openApp == nil else { return }
        let launchedID = item.id
        let localRect = rect.offsetBy(
            dx: -screenFrame.rect.minX,
            dy: -screenFrame.rect.minY
        )
        // Icon views include their label in the frame used for rearranging.
        // Launch from the square artwork at the top of that frame so the app
        // does not begin as a tall tile and visibly correct its aspect ratio.
        if rect == .zero || localRect.isEmpty {
            sourceFrame = .zero
        } else {
            let side = min(localRect.width, localRect.height)
            sourceFrame = CGRect(
                x: localRect.midX - side / 2,
                y: localRect.minY,
                width: side,
                height: side
            )
        }
        openProgress = 0
        openRevealed = false
        interactiveDismissal = 0
        appTransitionActive = true
        isClosingApp = false
        openApp = item

        // Let SwiftUI commit the inserted AppWindow at its icon-sized phase
        // before assigning animated targets. Without this actor turn, insertion
        // and target writes can coalesce and skip the beginning of the reveal.
        Task { @MainActor in
            await Task.yield()
            guard openApp?.id == launchedID, !isClosingApp else { return }

            // Two concurrent transactions, deliberately: geometry takes the
            // spring while the icon/content handoff uses its shorter curve.
            withAnimation(
                transitionAnimation(.windowOpen),
                completionCriteria: .logicallyComplete
            ) {
                openProgress = 1
            } completion: {
                guard openApp?.id == launchedID,
                      openProgress == 1,
                      !isClosingApp else { return }
                appTransitionActive = false
            }
            withAnimation(transitionAnimation(.windowReveal)) {
                openRevealed = true
            }
        }
    }

    private func close() {
        guard let closingApp = openApp, !isClosingApp else { return }
        let closingID = closingApp.id
        isClosingApp = true
        appTransitionActive = true
        Haptics.tap(.light)
        // Tearing the window down on a hard-coded delay meant every retune of
        // the curve risked either a visible pop or a dead frame at the end.
        // The completion is tied to the animation itself instead.
        withAnimation(transitionAnimation(.windowHide)) { openRevealed = false }
        withAnimation(transitionAnimation(.windowClose), completionCriteria: .logicallyComplete) {
            openProgress = 0
        } completion: {
            guard isClosingApp,
                  openApp?.id == closingID,
                  openProgress == 0 else { return }
            openApp = nil
            sourceFrame = .zero
            interactiveDismissal = 0
            appTransitionActive = false
            isClosingApp = false
        }
    }

    /// Removing a guest uninstalls it outright — the icon *is* the install.
    private func remove(_ item: HomeItem) {
        if let bundle = item.guestBundle {
            store.remove(bundle)
        }
        withAnimation(.snappy) { layout.remove(item, columns: appearance.columns) }
    }

    // MARK: - Installed apps

    /// Keeps the home screen in step with the installed set, so a GET in
    /// Packages drops an icon here and an uninstall takes it away.
    private func syncGuests() {
        withAnimation(appearance.animation(.snappy)) {
            layout.syncGuests(installed: store.installedList.map(\.bundleIdentifier),
                              columns: appearance.columns)
        }
    }

    private func refreshContainerWidgets() {
        containerWidgets.refresh()
        layout.migrateLegacyWidgets(
            containerWidgets.enabled.map(\.id),
            columns: appearance.columns
        )
    }
}

private struct HomeWidgetAnchor: Identifiable {
    let index: Int
    let item: HomeItem
    var id: String { item.id }
}

/// A live WidgetKit surface that participates in the same edit gesture as an
/// app icon. The renderer keeps owning ordinary taps; edit mode lays a clear
/// SwiftUI hit target above it so UIKit cannot swallow drag or delete gestures.
private struct PlacedContainerWidgetView: View {
    let item: HomeItem
    let placement: HomeLayoutStore.WidgetPlacement
    let descriptor: ContainerWidgetStore.Descriptor?
    let size: CGSize
    let columns: Int
    let jiggling: Bool
    let carried: Bool
    let interactionSuppressed: Bool
    let registry: IconFrameRegistry
    var onOpen: () -> Void
    var onBeginEditing: () -> Void
    var onDelete: () -> Void
    var onPickUp: (CGPoint) -> Void
    var onDragChange: (CGPoint) -> Void
    var onDrop: () -> Void
    var canResize: (HomeLayoutStore.WidgetSize) -> Bool
    var onResize: (HomeLayoutStore.WidgetSize) -> Bool

    @State private var lifted = false
    @State private var resizing = false
    @State private var resizePreview: HomeLayoutStore.WidgetSize?
    @State private var resizePreviewAllowed = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !jiggling)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let seed = Double(item.id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360)
            let angle = jiggling ? sin(time * 10.8 + seed) * 0.48 : 0

            content
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .rotationEffect(.degrees(angle))
                .opacity(carried ? 0 : 1)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45, maximumDistance: 14)
                        .onEnded { _ in
                            guard !jiggling else { return }
                            Haptics.tap(.medium)
                            onBeginEditing()
                        }
                )
                .gesture(
                    rearrangeGesture,
                    including: jiggling && !resizing ? .all : .subviews
                )
                .onChange(of: jiggling) { _, active in
                    if !active {
                        lifted = false
                        resetResizePreview()
                    }
                }
                .recordGlobalFrame { rect in
                    registry.record(rect, for: item.id)
                }
        }
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let descriptor {
                    ContainerWidgetSurface(
                        widget: descriptor,
                        rendererInstanceIdentifier:
                            "springboard.\(placement.id.uuidString).\(descriptor.id)",
                        family: placement.size.widgetFamily,
                        contentHeight: size.height,
                        showsAppName: false,
                        cornerRadius: 22,
                        onOpen: onOpen
                    )
                } else {
                    unavailablePlaceholder
                }
            }
            .allowsHitTesting(!jiggling && !interactionSuppressed)

            if jiggling {
                Color.clear
                    .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                Button(action: onDelete) {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color(hex: "CFC2B2")))
                        .overlay(Circle().strokeBorder(Palette.ink.opacity(0.2), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .offset(x: -7, y: -7)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) {
            if let resizePreview {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        resizePreviewAllowed ? Color.white : SysColor.red,
                        lineWidth: 2.5
                    )
                    .frame(
                        width: previewWidth(for: resizePreview),
                        height: previewHeight(for: resizePreview)
                    )
                    .shadow(color: .black.opacity(0.24), radius: 4, y: 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if jiggling {
                resizeHandle
                    .offset(x: 10, y: 10)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Palette.ink)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color(hex: "CFC2B2")))
            .overlay(Circle().strokeBorder(Palette.ink.opacity(0.2), lineWidth: 0.5))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .highPriorityGesture(resizeGesture)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Resize widget")
            .accessibilityHint("Drag sideways or vertically to change the widget size")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { resizeUsingAccessibility() }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard jiggling else { return }
                resizing = true
                updateResizePreview(for: value.translation)
            }
            .onEnded { value in
                guard resizing else { return }
                let proposedSize = proposedSize(for: value.translation)
                let allowed = canResize(proposedSize)
                resetResizePreview()

                guard proposedSize != placement.size else { return }
                guard allowed, onResize(proposedSize) else {
                    Haptics.tap(.rigid)
                    return
                }
                Haptics.tap(.medium)
            }
    }

    private func proposedSize(for translation: CGSize) -> HomeLayoutStore.WidgetSize {
        let horizontalThreshold = max(24, gridColumnWidth * 0.45)
        let verticalThreshold = max(24, gridRowHeight * 0.45)
        switch placement.size {
        case .small:
            return translation.width >= horizontalThreshold
                ? HomeLayoutStore.WidgetSize.medium
                : HomeLayoutStore.WidgetSize.small
        case .medium:
            if translation.height >= verticalThreshold { return .large }
            if translation.width <= -horizontalThreshold { return .small }
            return .medium
        case .large:
            return translation.height <= -verticalThreshold ? .medium : .large
        }
    }

    private func updateResizePreview(for translation: CGSize) {
        let proposedSize = proposedSize(for: translation)
        let preview = proposedSize == placement.size ? nil : proposedSize
        let allowed = preview.map(canResize) ?? false

        if preview != resizePreview {
            resizePreview = preview
            resizePreviewAllowed = allowed
            if preview != nil { Haptics.selection() }
        } else if resizePreviewAllowed != allowed {
            resizePreviewAllowed = allowed
        }
    }

    private func resetResizePreview() {
        resizing = false
        resizePreview = nil
        resizePreviewAllowed = false
    }

    private var gridColumnWidth: CGFloat {
        let occupiedColumns = max(1, placement.size.span(columns: columns).columns)
        return (size.width + 8) / CGFloat(occupiedColumns)
    }

    private var gridRowHeight: CGFloat {
        let occupiedRows = max(1, placement.size.span(columns: columns).rows)
        return (size.height + 8) / CGFloat(occupiedRows)
    }

    private func previewWidth(for proposedSize: HomeLayoutStore.WidgetSize) -> CGFloat {
        let proposedColumns = proposedSize.span(columns: columns).columns
        return gridColumnWidth * CGFloat(proposedColumns) - 8
    }

    private func previewHeight(for proposedSize: HomeLayoutStore.WidgetSize) -> CGFloat {
        let proposedRows = proposedSize.span(columns: columns).rows
        return gridRowHeight * CGFloat(proposedRows) - 8
    }

    private func resizeUsingAccessibility() {
        let proposedSize: HomeLayoutStore.WidgetSize
        switch placement.size {
        case .small: proposedSize = .medium
        case .medium: proposedSize = .large
        case .large: proposedSize = .medium
        }
        guard canResize(proposedSize), onResize(proposedSize) else {
            Haptics.tap(.rigid)
            return
        }
        Haptics.tap(.medium)
    }

    private var unavailablePlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
            VStack(spacing: 8) {
                Image(systemName: "widget.small.badge.exclamationmark")
                    .font(.system(size: 30, weight: .medium))
                Text("Widget temporarily unavailable")
                    .font(.system(size: 12, weight: .semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(SysColor.secondaryLabel)
            .padding(12)
        }
    }

    private var rearrangeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                guard jiggling else { return }
                if !lifted {
                    lifted = true
                    Haptics.tap(.light)
                    onPickUp(value.location)
                }
                onDragChange(value.location)
            }
            .onEnded { _ in
                guard lifted else { return }
                lifted = false
                onDrop()
            }
    }
}

struct PageDots: View {
    let count: Int
    let index: Int
    /// Draws a marker for the News page sitting to the left of the dots.
    var showsLeadingPage = false

    var body: some View {
        HStack(spacing: 8) {
            if showsLeadingPage {
                Image(systemName: "newspaper.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.white.opacity(index < 0 ? 0.95 : 0.38))
                    .padding(.trailing, 2)
            }
            ForEach(0..<count, id: \.self) { dot in
                Circle()
                    .fill(Color.white.opacity(dot == index ? 0.95 : 0.32))
                    .frame(width: 7, height: 7)
            }
        }
        .animation(.easeOut(duration: 0.2), value: index)
    }
}
