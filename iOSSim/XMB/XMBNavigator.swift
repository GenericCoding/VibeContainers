import Observation
import SwiftUI
import UIKit

/// The dashboard's state machine.
///
/// Everything the XMB can do arrives here as an `XMBInput` and leaves as a
/// change to `categoryIndex`, `stack` or one of the app's stores. The views
/// render this object and nothing else, which is what keeps the dashboard
/// genuinely controller-only: there is no gesture, no button and no text field
/// anywhere in the XMB that could reach the state by another route.
///
/// Rows read straight through to `PackageStore`, `WebServer` and friends, so a
/// repo that finishes loading, a download that advances or a server that stops
/// shows up immediately. Large package columns are accessed by index: the view
/// only constructs its visible window instead of eagerly materialising every
/// repository row on each SwiftUI update.
@MainActor
@Observable
final class XMBNavigator {
    // MARK: - State

    private(set) var categoryIndex = XMBCategory.allCases.firstIndex(of: .game) ?? 0
    /// Columns pushed on top of the category's own. Empty means the crossbar.
    private(set) var stack: [XMBColumnID] = []
    /// Remembered per column, so backing out and going in again lands where you
    /// left rather than at the top.
    private var selections: [XMBColumnID: Int] = [:]

    /// True only while the information panel was explicitly requested with △.
    /// Resting on a row no longer opens anything automatically.
    private(set) var hovering = false
    /// Opened with △ and closed with △ or ○.
    private(set) var hoverPinned = false

    /// Brief confirmations — an install started, an address copied.
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    var nowPlaying: Song?
    /// Set when the PS button is pressed at the root of the dashboard, or when
    /// a "Return to iOS" row is chosen. The root view watches it and swaps the
    /// springboard back in.
    private(set) var wantsExit = false
    /// The last executable-code probe. Run when the JIT page is opened rather
    /// than while its rows are being built — the probe maps a page, flips it to
    /// executable and calls into it, which is not something a `body` should do.
    private(set) var jitProbe: Int32 = 0

    // MARK: - Derived

    var category: XMBCategory { XMBCategory.allCases[categoryIndex] }
    var column: XMBColumnID { stack.last ?? .category(category) }
    var atRoot: Bool { stack.isEmpty }

    var selection: Int {
        get { min(max(0, selections[column] ?? 0), max(0, itemCount - 1)) }
        set { selections[column] = newValue }
    }

    var itemCount: Int { itemCount(for: column) }

    func item(at index: Int) -> XMBItem? {
        item(at: index, in: column)
    }

    var focused: XMBItem? {
        item(at: selection, in: column, includePackageInfo: true)
    }

    /// The breadcrumb across the top of a pushed column.
    var path: [String] {
        [category.title] + stack.map(title(of:))
    }

    // MARK: - Input

    func handle(_ input: XMBInput) {
        switch input {
        case .up: move(by: -1)
        case .down: move(by: 1)

        case .left:
            if atRoot {
                step(category: -1)
            } else if let adjust = focused?.adjust {
                adjust(-1)
                XMBSound.shared.play(.cursor)
            } else {
                pop()
            }

        case .right:
            if atRoot {
                step(category: 1)
            } else if let adjust = focused?.adjust {
                adjust(1)
                XMBSound.shared.play(.cursor)
            } else {
                activate()
            }

        case .cross:
            activate()

        case .circle:
            if hoverPinned {
                setHover(pinned: false)
                XMBSound.shared.play(.back)
            } else {
                pop()
            }

        case .triangle:
            guard focused?.info != nil else { XMBSound.shared.play(.error); return }
            setHover(pinned: !hoverPinned)
            XMBSound.shared.play(hoverPinned ? .enter : .back)

        case .square:
            guard let secondary = focused?.secondary else { XMBSound.shared.play(.error); return }
            XMBSound.shared.play(.enter)
            ControllerHub.shared.rumble()
            secondary()

        case .l1:
            atRoot ? step(category: -1) : popToRoot()

        case .r1:
            atRoot ? step(category: 1) : activate()

        case .options:
            refreshEverything()

        case .share:
            break

        case .home:
            // Inside a guest this button never reaches here — the guest process
            // claims it first (see IOSSimInstallGuestExitControl) and uses it to
            // tear the container down. On the dashboard it means the same
            // thing one level up: leave.
            requestExit()
        }
    }

    func clearExit() { wantsExit = false }

    /// Leaving the dashboard for the touchscreen.
    func requestExit() {
        XMBSound.shared.play(.back)
        wantsExit = true
    }

    func runJITProbe() { jitProbe = XMBJITProbe.run() }

    // MARK: - Movement

    /// Reads only the column count. In a repository with thousands of entries
    /// this stays O(1), rather than rebuilding thousands of row view-models for
    /// every repeat event from a held direction.
    private func move(by delta: Int) {
        let count = itemCount
        guard count > 0 else { XMBSound.shared.play(.error); return }
        let current = min(max(0, selections[column] ?? 0), count - 1)
        let next = min(max(0, current + delta), count - 1)
        guard next != current else { return }
        selections[column] = next
        XMBSound.shared.play(.cursor)
        dismissInfoPanel()
    }

    private func step(category delta: Int) {
        let count = XMBCategory.allCases.count
        let next = min(max(0, categoryIndex + delta), count - 1)
        guard next != categoryIndex else { return }
        categoryIndex = next
        XMBSound.shared.play(.sweep)
        // The wave and the pad both take the new column's colour.
        ControllerHub.shared.paintAll(category.tint)
        dismissInfoPanel()
    }

    private func activate() {
        guard let action = focused?.activate else { XMBSound.shared.play(.error); return }
        XMBSound.shared.play(.enter)
        ControllerHub.shared.rumble()
        action()
    }

    func push(_ id: XMBColumnID) {
        if id == .jit { runJITProbe() }
        stack.append(id)
        dismissInfoPanel()
    }

    private func pop() {
        guard !stack.isEmpty else { return }
        stack.removeLast()
        XMBSound.shared.play(.back)
        dismissInfoPanel()
    }

    private func popToRoot() {
        guard !stack.isEmpty else { return }
        stack.removeAll()
        XMBSound.shared.play(.back)
        dismissInfoPanel()
    }

    // MARK: - Information panel

    private func dismissInfoPanel() {
        if hovering || hoverPinned {
            hovering = false
            hoverPinned = false
        }
    }

    private func setHover(pinned: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            hoverPinned = pinned
            hovering = pinned
        }
    }

    /// The dashboard has just come up. Information remains closed until △ is
    /// pressed explicitly.
    func begin() {
        ControllerHub.shared.paintAll(category.tint)
        dismissInfoPanel()
    }

    // MARK: - Toast

    func say(_ message: String) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { toast = message }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
    }

    private func refreshEverything() {
        XMBSound.shared.play(.enter)
        say("Refreshing every repository…")
        Task {
            await PackageStore.shared.refreshAll()
            XMBSound.shared.play(.complete)
            say("\(PackageStore.shared.allApps.count) packages across \(PackageStore.shared.sources.count) repositories")
        }
    }
}

// MARK: - Titles

extension XMBNavigator {
    func title(of id: XMBColumnID) -> String {
        switch id {
        case .category(let category): category.title
        case .allPackages: "Install Packages"
        case .source(let uuid): PackageStore.shared.sources.first { $0.id == uuid }?.displayName ?? "Repository"
        case .installed: "Installed Applications"
        case .updates: "Updates"
        case .sources: "Package Sources"
        case .tweaks: "Tweaks"
        case .httpServer: "HTTP Server"
        case .jit: "JIT & Containers"
        case .theme: "Theme & Wave"
        case .sound: "Sound Settings"
        case .controllers: "Controller"
        case .about: "System Information"
        case .connection: "Connection Information"
        case .package(let id): PackageStore.shared.entry(id: id)?.app.name ?? "Package"
        case .guest(let bundle): PackageStore.shared.installed[bundle]?.name ?? bundle
        case .article(let id): FeedStore.shared.articles.first { $0.id == id }?.title ?? "Article"
        }
    }

    /// The banner at the top of a page: what the page is about, drawn from the
    /// same `XMBInfo` the hover panel uses.
    func header(of id: XMBColumnID) -> XMBInfo? {
        switch id {
        case .package(let entryID):
            guard let entry = PackageStore.shared.entry(id: entryID) else { return nil }
            return info(for: entry)
        case .guest(let bundle):
            guard let record = PackageStore.shared.installed[bundle] else { return nil }
            return XMBInfo(
                title: record.name,
                subtitle: "\(record.developer) · Version \(record.version)",
                icon: .package(url: record.iconURL, tint: nil),
                lines: [],
                body: nil,
                footnote: record.sourceName,
                accent: Palette.ice
            )
        case .article(let articleID):
            guard let article = FeedStore.shared.articles.first(where: { $0.id == articleID }) else { return nil }
            return XMBInfo(
                title: article.title,
                subtitle: "\(article.sourceTitle) · \(article.dateText)",
                icon: .symbol("newspaper.fill", Palette.denim),
                body: article.summary,
                accent: Palette.denim
            )
        default:
            return nil
        }
    }
}
