import Foundation
import Observation

/// Where every icon sits, and the only thing that gets to say so.
///
/// A page is a fixed grid of slots, most of which may be empty: an icon holds
/// the slot it was dropped on rather than being packed in after its neighbours.
/// That is the whole difference between "arrange your home screen" and "sort a
/// list", and it is why pages are `[HomeItem?]` and not `[HomeItem]`.
///
/// The dock is the exception and stays dense, the way iOS packs it.
///
/// Everything is saved as ids, so a layout survives both a relaunch and the app
/// gaining new built-ins: anything in the defaults that the saved layout has
/// never seen is given a slot rather than dropped.
@MainActor
@Observable
final class HomeLayoutStore {
    static let shared = HomeLayoutStore()

    struct Folder: Identifiable, Hashable {
        let id: UUID
        var name: String
        var items: [HomeItem]
    }

    struct GridSpan: Hashable {
        let columns: Int
        let rows: Int
    }

    /// The standard WidgetKit families that map cleanly onto the SpringBoard icon
    /// lattice. A small widget occupies a 2x2 icon region; a medium widget is
    /// four columns wide (or the full width of a narrower grid) and two rows;
    /// a large widget uses that width and four rows.
    enum WidgetSize: String, CaseIterable, Identifiable, Hashable {
        case small
        case medium
        case large

        var id: String { rawValue }
        var title: String {
            switch self {
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            }
        }
        var widgetFamily: Int64 {
            switch self {
            case .small: 0
            case .medium: 1
            case .large: 2
            }
        }

        func span(columns: Int) -> GridSpan {
            switch self {
            case .small: GridSpan(columns: min(2, max(1, columns)), rows: 2)
            case .medium: GridSpan(columns: min(4, max(1, columns)), rows: 2)
            case .large: GridSpan(columns: min(4, max(1, columns)), rows: 4)
            }
        }
    }

    /// Metadata is stored separately from the page's lightweight HomeItem id.
    /// That keeps old icon-only layouts readable and lets one extension be
    /// placed more than once, at different sizes.
    struct WidgetPlacement: Identifiable, Hashable {
        let id: UUID
        let descriptorID: String
        var size: WidgetSize
    }

    private(set) var pages: [[HomeItem?]]
    private(set) var dock: [HomeItem]
    private(set) var folders: [UUID: Folder] = [:]
    private(set) var widgets: [UUID: WidgetPlacement] = [:]

    private let pagesKey = "home.layout.pages"
    private let dockKey = "home.layout.dock"
    private let knownKey = "home.layout.known"
    private let foldersKey = "home.layout.folders"
    private let widgetsKey = "home.layout.widgets"
    private let widgetMigrationKey = "home.layout.widgets.migratedToGrid"
    private let builtinSetVersionKey = "home.layout.builtinSetVersion"
    private static let builtinSetVersion = 1

    /// Built-ins already placed once. A built-in missing from this list is new
    /// to the install and gets a slot; one that is in it was deliberately
    /// removed and stays gone.
    private var known: Set<String>

    /// Rows per page — uniform now that the first page has no widgets sitting
    /// on top of it. `normalize(columns:)` grows the saved pages to match.
    static let rows = 6

    /// The iPhone dock is independent of the configurable page grid and always
    /// has four positions.
    static let dockSlots = 4

    private init() {
        let defaults = UserDefaults.standard
        known = Set(defaults.stringArray(forKey: knownKey) ?? [])

        // Built up locally: nothing may touch `self` until every stored
        // property has a value.
        var restored: [UUID: Folder] = [:]
        if let raw = defaults.array(forKey: foldersKey) as? [[String: Any]] {
            for entry in raw {
                guard let idString = entry["id"] as? String,
                      let id = UUID(uuidString: idString),
                      let name = entry["name"] as? String,
                      let items = entry["items"] as? [String] else { continue }
                restored[id] = Folder(id: id, name: name, items: items.compactMap(HomeItem.init(id:)))
            }
        }

        var restoredWidgets: [UUID: WidgetPlacement] = [:]
        if let raw = defaults.array(forKey: widgetsKey) as? [[String: Any]] {
            for entry in raw {
                guard let idString = entry["id"] as? String,
                      let id = UUID(uuidString: idString),
                      let descriptorID = entry["descriptor"] as? String,
                      !descriptorID.isEmpty,
                      let sizeName = entry["size"] as? String,
                      let size = WidgetSize(rawValue: sizeName) else { continue }
                restoredWidgets[id] = WidgetPlacement(
                    id: id,
                    descriptorID: descriptorID,
                    size: size
                )
            }
        }

        if let savedPages = defaults.array(forKey: pagesKey) as? [[String]],
           let savedDock = defaults.array(forKey: dockKey) as? [String] {
            pages = savedPages.map { $0.map { $0.isEmpty ? nil : HomeItem(id: $0) } }
            dock = savedDock.compactMap(HomeItem.init(id:))
        } else {
            pages = HomeLayout.pages.map { $0.map { HomeItem.builtin($0) } }
            dock = HomeLayout.dock.map(HomeItem.builtin)
        }

        folders = restored
        widgets = restoredWidgets
        if pages.isEmpty { pages = [[]] }
        migrateInstalledBuiltinsIfNeeded(defaults)
        adoptNewBuiltins()
        if fillDockFromPages() { persist() }
    }

    // MARK: - Shape

    func capacity(ofPage index: Int, columns: Int) -> Int {
        columns * Self.rows
    }

    func dockCapacity(columns _: Int) -> Int { Self.dockSlots }

    /// Pads every page out to its slot count and repairs collisions after an
    /// icon-column change. Widgets are laid down first so their complete span
    /// stays reserved; any icon that was under a newly-shaped footprint is
    /// moved to the next genuine free cell instead of being lost.
    func normalize(columns: Int) {
        guard columns > 0 else { return }
        let dockLimit = dockCapacity(columns: columns)
        let oldPages = pages.isEmpty ? [[]] : pages
        pages = oldPages.indices.map { index in
            Array(repeating: nil, count: capacity(ofPage: index, columns: columns))
        }

        var reserved = Array(repeating: Set<Int>(), count: pages.count)
        var displacedWidgets: [HomeItem] = []
        var displacedIcons: [HomeItem] = []
        var seen: Set<HomeItem> = []

        // Preserve widget anchors where their new span still fits. Missing
        // metadata means the saved id is corrupt and can safely be ignored.
        for (pageIndex, oldPage) in oldPages.enumerated() {
            for (anchor, item) in oldPage.enumerated() {
                guard let item, item.isWidget, widget(for: item) != nil,
                      seen.insert(item).inserted else { continue }
                guard pages[pageIndex].indices.contains(anchor),
                      let footprint = footprintIndices(for: item, anchor: anchor, columns: columns),
                      footprint.allSatisfy({ !reserved[pageIndex].contains($0) }) else {
                    displacedWidgets.append(item)
                    continue
                }
                pages[pageIndex][anchor] = item
                reserved[pageIndex].formUnion(footprint)
            }
        }

        // Then retain every ordinary icon that is still in a usable cell.
        for (pageIndex, oldPage) in oldPages.enumerated() {
            for (index, item) in oldPage.enumerated() {
                guard let item, !item.isWidget, seen.insert(item).inserted else { continue }
                guard pages[pageIndex].indices.contains(index),
                      pages[pageIndex][index] == nil,
                      !reserved[pageIndex].contains(index) else {
                    displacedIcons.append(item)
                    continue
                }
                pages[pageIndex][index] = item
            }
        }

        // Widgets are not legal dock residents. Older/corrupt state is healed
        // by returning them to a page before applying the dense dock limit.
        let oldDock = dock
        dock = []
        for item in oldDock where seen.insert(item).inserted {
            if item.isWidget {
                displacedWidgets.append(item)
            } else if dock.count < dockLimit {
                dock.append(item)
            } else {
                displacedIcons.append(item)
            }
        }

        for item in displacedWidgets {
            placeInFirstFreeSlot(item, preferring: 0, columns: columns)
        }
        for item in displacedIcons {
            placeInFirstFreeSlot(item, preferring: 0, columns: columns)
        }

        let liveWidgetIDs = Set(pages.flatMap { $0 }.compactMap { $0?.widgetID })
        widgets = widgets.filter { liveWidgetIDs.contains($0.key) }
        persist()
    }

    // MARK: - Reading

    var allItems: [HomeItem] {
        pages.flatMap { $0 }.compactMap { $0 } + dock
    }

    /// Everything on the home screen *and* inside folders.
    var allApps: [HomeItem] {
        allItems.flatMap { item -> [HomeItem] in
            if item.isWidget { return [] }
            guard let id = item.folderID, let folder = folders[id] else { return [item] }
            return folder.items.filter { !$0.isWidget }
        }
    }

    func folder(_ id: UUID) -> Folder? { folders[id] }
    func widget(_ id: UUID) -> WidgetPlacement? { widgets[id] }
    func widget(for item: HomeItem) -> WidgetPlacement? {
        item.widgetID.flatMap { widgets[$0] }
    }

    func placedWidgetCount(descriptorID: String) -> Int {
        widgets.values.filter { $0.descriptorID == descriptorID }.count
    }

    func span(for item: HomeItem, columns: Int) -> GridSpan {
        widget(for: item)?.size.span(columns: columns) ?? GridSpan(columns: 1, rows: 1)
    }

    /// Where an icon currently is. `page == nil` means the dock.
    struct Slot: Equatable {
        var page: Int?
        var index: Int
    }

    func slot(of item: HomeItem) -> Slot? {
        if let index = dock.firstIndex(of: item) { return Slot(page: nil, index: index) }
        for (pageIndex, page) in pages.enumerated() {
            if let index = page.firstIndex(of: item) { return Slot(page: pageIndex, index: index) }
        }
        return nil
    }

    func item(at slot: Slot) -> HomeItem? {
        if let page = slot.page {
            guard pages.indices.contains(page), pages[page].indices.contains(slot.index) else { return nil }
            return pages[page][slot.index]
        }
        guard dock.indices.contains(slot.index) else { return nil }
        return dock[slot.index]
    }

    /// Returns the item occupying a cell, including a widget whose anchor is
    /// in an earlier cell. Page storage intentionally keeps those covered
    /// cells nil so icon-only layouts remain backward compatible.
    func itemCovering(_ slot: Slot, columns: Int) -> HomeItem? {
        guard let pageIndex = slot.page else { return item(at: slot) }
        guard pages.indices.contains(pageIndex),
              pages[pageIndex].indices.contains(slot.index) else { return nil }

        if let direct = pages[pageIndex][slot.index] { return direct }
        for (anchor, candidate) in pages[pageIndex].enumerated() {
            guard let candidate, candidate.isWidget,
                  footprintIndices(for: candidate, anchor: anchor, columns: columns)?.contains(slot.index) == true
            else { continue }
            return candidate
        }
        return nil
    }

    func footprint(of item: HomeItem, columns: Int) -> [Slot] {
        guard let origin = slot(of: item) else { return [] }
        guard let page = origin.page else { return [origin] }
        return (footprintIndices(for: item, anchor: origin.index, columns: columns) ?? [])
            .map { Slot(page: page, index: $0) }
    }

    /// Whether a carried item can use this destination. Icons may swap with
    /// another icon, but never with one cell of a multi-cell widget. Widgets
    /// are page-only and require their complete footprint to be clear.
    func canMove(_ item: HomeItem, to destination: Slot, columns: Int) -> Bool {
        if item.isWidget {
            guard let page = destination.page,
                  pages.indices.contains(page),
                  let footprint = footprintIndices(
                    for: item,
                    anchor: destination.index,
                    columns: columns
                  ) else { return false }

            for index in footprint {
                let slot = Slot(page: page, index: index)
                if let occupant = itemCovering(slot, columns: columns), occupant != item {
                    return false
                }
            }
            return true
        }

        if destination.page == nil { return true }
        guard let occupant = itemCovering(destination, columns: columns) else { return true }
        return !occupant.isWidget
    }

    private func footprintIndices(for item: HomeItem, anchor: Int, columns: Int) -> [Int]? {
        guard columns > 0 else { return nil }
        return footprintIndices(
            span: span(for: item, columns: columns),
            anchor: anchor,
            columns: columns
        )
    }

    private func footprintIndices(span: GridSpan, anchor: Int, columns: Int) -> [Int]? {
        guard columns > 0 else { return nil }
        let row = anchor / columns
        let column = anchor % columns
        guard column + span.columns <= columns,
              row + span.rows <= Self.rows else { return nil }

        return (0..<span.rows).flatMap { rowOffset in
            (0..<span.columns).map { columnOffset in
                (row + rowOffset) * columns + column + columnOffset
            }
        }
    }

    // MARK: - Moving

    /// Drops an icon on a slot: into the gap if it is empty, otherwise trading
    /// places with whatever is already there. The dock is dense, so moving
    /// within it inserts at the requested position and shifts its neighbours
    /// instead of performing a surprising two-icon swap.
    ///
    /// Returns false only when the move cannot happen at all — a full dock with
    /// nothing to trade against.
    @discardableResult
    func move(_ item: HomeItem, to destination: Slot, columns: Int) -> Bool {
        guard let origin = slot(of: item) else { return false }
        guard origin != destination else { return true }
        guard canMove(item, to: destination, columns: columns) else { return false }

        if item.isWidget {
            guard let originPage = origin.page,
                  let destinationPage = destination.page,
                  pages.indices.contains(originPage),
                  pages.indices.contains(destinationPage),
                  pages[originPage].indices.contains(origin.index),
                  pages[destinationPage].indices.contains(destination.index) else { return false }
            pages[originPage][origin.index] = nil
            pages[destinationPage][destination.index] = item
            persist()
            return true
        }

        let occupant = self.item(at: destination)   // `item` is the parameter

        if let page = destination.page {
            guard pages.indices.contains(page),
                  pages[page].indices.contains(destination.index) else { return false }
            pages[page][destination.index] = item
            vacate(origin, replacingWith: occupant)
        } else if origin.page == nil {
            // `destination.index` is calculated against the other dock icons,
            // with the carried icon omitted. Remove first so that index has the
            // same meaning here as it did under the finger.
            guard let originIndex = dock.firstIndex(of: item) else { return false }
            dock.remove(at: originIndex)
            dock.insert(item, at: min(max(0, destination.index), dock.count))
        } else {
            let capacity = dockCapacity(columns: columns)
            if dock.count < capacity {
                // A non-full dock behaves like an insertion strip. Existing
                // icons slide aside and the now-empty page slot stays empty.
                dock.insert(item, at: min(max(0, destination.index), dock.count))
                vacate(origin, replacingWith: nil)
            } else {
                // There is nowhere to shift a full dock. Swap with the nearest
                // edge icon so no app is lost when the finger is just beyond
                // the first or last icon.
                guard !dock.isEmpty else { return false }
                let index = min(max(0, destination.index), dock.count - 1)
                let displaced = dock[index]
                dock[index] = item
                vacate(origin, replacingWith: displaced)
            }
        }

        persist()
        return true
    }

    /// Clears the slot an icon has left, handing it whatever it displaced.
    private func vacate(_ slot: Slot, replacingWith replacement: HomeItem?) {
        if let page = slot.page {
            guard pages.indices.contains(page), pages[page].indices.contains(slot.index) else { return }
            pages[page][slot.index] = replacement
        } else {
            guard dock.indices.contains(slot.index) else { return }
            if let replacement {
                dock[slot.index] = replacement
            } else {
                dock.remove(at: slot.index)
            }
        }
    }

    // MARK: - Folders

    /// Drops one icon onto another and gets a folder holding both.
    ///
    /// Dropping onto a folder just adds to it. The new folder takes the slot of
    /// the icon that was landed on, which is where the eye expects it.
    @discardableResult
    func combine(_ dragged: HomeItem, onto target: HomeItem) -> UUID? {
        guard dragged != target, !dragged.isWidget, !target.isWidget,
              let targetSlot = slot(of: target) else { return nil }

        // Never nest a folder inside another.
        if dragged.folderID != nil { return nil }

        if let existing = target.folderID {
            addToFolder(existing, item: dragged)
            return existing
        }

        let id = UUID()
        folders[id] = Folder(id: id, name: suggestedName(for: [target, dragged]), items: [target, dragged])
        let draggedSlot = slot(of: dragged)
        var resolvedTarget = targetSlot

        // Removing an earlier icon compacts the dock. Resolve the target's new
        // index before writing the folder so a dock-to-dock merge cannot miss
        // its slot or overwrite the icon that followed it.
        if let draggedSlot,
           draggedSlot.page == nil,
           targetSlot.page == nil,
           draggedSlot.index < targetSlot.index {
            resolvedTarget.index -= 1
        }

        if let draggedSlot { vacate(draggedSlot, replacingWith: nil) }
        put(.folder(id), at: resolvedTarget)
        persist()
        return id
    }

    func addToFolder(_ id: UUID, item: HomeItem) {
        guard !item.isWidget, var folder = folders[id], !folder.items.contains(item) else { return }
        if let itemSlot = slot(of: item) { vacate(itemSlot, replacingWith: nil) }
        folder.items.append(item)
        folders[id] = folder
        persist()
    }

    /// Moves an app from an open folder to an exact page or dock destination.
    /// An occupied destination swaps its app back into the source folder, which
    /// keeps free-placement deterministic without dropping either item.
    @discardableResult
    func move(_ item: HomeItem, fromFolder id: UUID, to destination: Slot, columns: Int) -> Bool {
        guard !item.isWidget, var folder = folders[id],
              let sourceIndex = folder.items.firstIndex(of: item) else { return false }

        guard canMove(item, to: destination, columns: columns) else { return false }

        let occupant = self.item(at: destination)
        // Folders cannot be nested. Dropping on a folder is handled by
        // `move(_:fromFolder:toFolder:)` instead.
        guard occupant?.isFolder != true else { return false }

        var replacementForFolder: HomeItem?
        if let page = destination.page {
            guard pages.indices.contains(page),
                  pages[page].indices.contains(destination.index) else { return false }
            pages[page][destination.index] = item
            replacementForFolder = occupant
        } else if dock.count < dockCapacity(columns: columns) {
            dock.insert(item, at: min(max(0, destination.index), dock.count))
        } else {
            guard !dock.isEmpty else { return false }
            let index = min(max(0, destination.index), dock.count - 1)
            let displaced = dock[index]
            guard !displaced.isFolder else { return false }
            dock[index] = item
            replacementForFolder = displaced
        }

        folder.items.remove(at: sourceIndex)
        if let replacementForFolder { folder.items.append(replacementForFolder) }
        folders[id] = folder
        dissolveIfEmpty(id, columns: columns)
        persist()
        return true
    }

    /// Transfers an app directly between two open-folder locations.
    @discardableResult
    func move(_ item: HomeItem, fromFolder sourceID: UUID, toFolder destinationID: UUID,
              columns: Int) -> Bool {
        guard sourceID != destinationID,
              var source = folders[sourceID],
              var destination = folders[destinationID],
              let index = source.items.firstIndex(of: item),
              !destination.items.contains(item),
              !item.isFolder,
              !item.isWidget else { return false }

        source.items.remove(at: index)
        destination.items.append(item)
        folders[sourceID] = source
        folders[destinationID] = destination
        dissolveIfEmpty(sourceID, columns: columns)
        persist()
        return true
    }

    /// Takes an app back out of a folder and onto the page the folder sits on.
    @discardableResult
    func moveOutOfFolder(_ item: HomeItem, from id: UUID, columns: Int) -> Bool {
        guard !item.isWidget, var folder = folders[id],
              let index = folder.items.firstIndex(of: item) else { return false }
        let folderSlot = slot(of: .folder(id))

        folder.items.remove(at: index)
        folders[id] = folder

        let landed = placeInFirstFreeSlot(item, preferring: folderSlot?.page ?? 0, columns: columns)
        dissolveIfEmpty(id, columns: columns)
        persist()
        return landed
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard var folder = folders[id] else { return }
        folder.name = name.isEmpty ? "Folder" : name
        folders[id] = folder
        persist()
    }

    /// An empty folder is nothing but a hole in the grid, so it goes.
    private func dissolveIfEmpty(_ id: UUID, columns: Int) {
        guard let folder = folders[id], folder.items.isEmpty else { return }
        if let folderSlot = slot(of: .folder(id)) { vacate(folderSlot, replacingWith: nil) }
        folders[id] = nil
    }

    /// Folder names come from what is in them, the way iOS guesses one.
    private func suggestedName(for items: [HomeItem]) -> String {
        if items.allSatisfy({ $0.guestBundle != nil }) { return "Sideloaded" }
        return "Folder"
    }

    // MARK: - Widgets

    /// Adds another instance of a discovered extension to the icon lattice.
    /// The caller gets the concrete item so it can page to or animate the new
    /// placement if desired.
    @discardableResult
    func addWidget(
        descriptorID: String,
        size: WidgetSize,
        preferring page: Int,
        columns: Int
    ) -> HomeItem? {
        guard !descriptorID.isEmpty else { return nil }
        let id = UUID()
        let item = HomeItem.widget(id)
        widgets[id] = WidgetPlacement(id: id, descriptorID: descriptorID, size: size)
        guard placeInFirstFreeSlot(item, preferring: page, columns: columns) else {
            widgets[id] = nil
            return nil
        }
        persist()
        return item
    }

    /// Earlier builds kept enabled widgets only in the left-side feed. Move
    /// one instance of each existing choice onto the real page grid exactly
    /// once; deleting it afterward remains the user's decision.
    func migrateLegacyWidgets(_ descriptorIDs: [String], columns: Int) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: widgetMigrationKey), !descriptorIDs.isEmpty else { return }
        for descriptorID in descriptorIDs where placedWidgetCount(descriptorID: descriptorID) == 0 {
            _ = addWidget(
                descriptorID: descriptorID,
                size: .medium,
                preferring: 0,
                columns: columns
            )
        }
        defaults.set(true, forKey: widgetMigrationKey)
    }

    /// Resizing is transactional: the old footprint remains in place if the
    /// requested family would collide or run off the current page.
    func canResizeWidget(_ item: HomeItem, to size: WidgetSize, columns: Int) -> Bool {
        guard item.isWidget,
              widget(for: item) != nil,
              let origin = slot(of: item),
              let page = origin.page,
              pages.indices.contains(page),
              let footprint = footprintIndices(
                span: size.span(columns: columns),
                anchor: origin.index,
                columns: columns
              ) else { return false }

        return footprint.allSatisfy { index in
            let occupant = itemCovering(
                Slot(page: page, index: index),
                columns: columns
            )
            return occupant == nil || occupant == item
        }
    }

    @discardableResult
    func resizeWidget(_ item: HomeItem, to size: WidgetSize, columns: Int) -> Bool {
        guard let id = item.widgetID,
              var placement = widgets[id] else { return false }
        guard placement.size != size else { return true }
        guard canResizeWidget(item, to: size, columns: columns) else { return false }
        placement.size = size
        widgets[id] = placement
        persist()
        return true
    }

    // MARK: - Membership

    func remove(_ item: HomeItem, columns: Int = 4, persisting: Bool = true) {
        for index in pages.indices {
            for slot in pages[index].indices where pages[index][slot] == item {
                pages[index][slot] = nil
            }
        }
        dock.removeAll { $0 == item }

        // Work from a stable key snapshot. `dissolveIfEmpty` mutates the
        // folder dictionary, which must never happen while its live iterator
        // is being enumerated.
        for id in Array(folders.keys) {
            guard var folder = folders[id], folder.items.contains(item) else { continue }
            folder.items.removeAll { $0 == item }
            folders[id] = folder
            if folder.items.isEmpty { dissolveIfEmpty(id, columns: columns) }
        }

        // Removing a folder icon puts everything it held back on the page.
        if let id = item.folderID, let folder = folders[id] {
            for app in folder.items { placeInFirstFreeSlot(app, preferring: 0, columns: columns) }
            folders[id] = nil
        }

        if let id = item.widgetID { widgets[id] = nil }

        if persisting { persist() }
    }

    /// Removes every placement owned by a container before that container's
    /// payload disappears. Returning the descriptor IDs lets teardown callers
    /// invalidate renderer sessions even when discovery had already lost a
    /// temporarily unavailable extension.
    @discardableResult
    func removeWidgets(
        ownedBy bundleIdentifier: String,
        columns: Int = 4
    ) -> Set<String> {
        let removedPlacements = widgets.values.filter { placement in
            guard let separator = placement.descriptorID.range(of: "::") else {
                return false
            }
            let owner = String(placement.descriptorID[..<separator.lowerBound])
            return owner == bundleIdentifier
        }
        guard !removedPlacements.isEmpty else { return [] }

        for placement in removedPlacements {
            remove(.widget(placement.id), columns: columns, persisting: false)
        }
        persist()
        return Set(removedPlacements.map(\.descriptorID))
    }

    /// Keeps the layout in step with the installed set, so a GET in Packages
    /// drops an icon here and an uninstall takes it away.
    func syncGuests(installed: [String], columns: Int) {
        let present = Set(installed)

        func stale(_ item: HomeItem?) -> Bool {
            guard let bundle = item?.guestBundle else { return false }
            return !present.contains(bundle)
        }

        for index in pages.indices {
            for slot in pages[index].indices where stale(pages[index][slot]) {
                pages[index][slot] = nil
            }
        }
        dock.removeAll { stale($0) }
        for id in Array(folders.keys) {
            guard var folder = folders[id] else { continue }
            folder.items.removeAll { stale($0) }
            folders[id] = folder
            dissolveIfEmpty(id, columns: columns)
        }

        // Widget placement follows its owning container. Keep it through a
        // payload refresh, but remove it once the package itself is gone.
        let staleWidgetIDs = widgets.values.compactMap { placement -> UUID? in
            guard let separator = placement.descriptorID.range(of: "::") else {
                return placement.id
            }
            let owner = String(placement.descriptorID[..<separator.lowerBound])
            return present.contains(owner) ? nil : placement.id
        }
        for id in staleWidgetIDs {
            remove(.widget(id), columns: columns, persisting: false)
        }

        let placed = Set(allApps.compactMap(\.guestBundle))
        for bundle in installed where !placed.contains(bundle) {
            placeInFirstFreeSlot(.guest(bundle), preferring: 0, columns: columns)
        }
        fillDockFromPages()
        persist()
    }

    /// Fills the four-position dock from real apps already visible on pages.
    /// Existing dock choices keep their order, folders stay intact, and no
    /// placeholder apps are invented merely to occupy an otherwise empty slot.
    @discardableResult
    private func fillDockFromPages() -> Bool {
        guard dock.count < Self.dockSlots else { return false }
        var changed = false

        for pageIndex in pages.indices {
            for slotIndex in pages[pageIndex].indices {
                guard dock.count < Self.dockSlots else { return changed }
                guard let item = pages[pageIndex][slotIndex],
                      !item.isFolder,
                      !item.isWidget,
                      !dock.contains(item) else { continue }
                pages[pageIndex][slotIndex] = nil
                dock.append(item)
                changed = true
            }
        }
        return changed
    }

    /// Drops an item into the first free slot, adding a page if it has to.
    @discardableResult
    func placeInFirstFreeSlot(_ item: HomeItem, preferring page: Int, columns: Int) -> Bool {
        let order = [page] + pages.indices.filter { $0 != page }
        for index in order where pages.indices.contains(index) {
            if let free = firstFreeAnchor(for: item, onPage: index, columns: columns) {
                pages[index][free] = item
                return true
            }
        }
        let size = capacity(ofPage: pages.count, columns: columns)
        pages.append(Array(repeating: nil, count: size))
        guard let free = firstFreeAnchor(for: item, onPage: pages.count - 1, columns: columns) else {
            pages.removeLast()
            return false
        }
        pages[pages.count - 1][free] = item
        return true
    }

    private func firstFreeAnchor(for item: HomeItem, onPage page: Int, columns: Int) -> Int? {
        guard pages.indices.contains(page) else { return nil }
        for index in pages[page].indices {
            guard let footprint = footprintIndices(for: item, anchor: index, columns: columns) else {
                continue
            }
            let clear = footprint.allSatisfy { candidate in
                itemCovering(Slot(page: page, index: candidate), columns: columns) == nil
            }
            if clear { return index }
        }
        return nil
    }

    private func put(_ item: HomeItem, at slot: Slot) {
        if let page = slot.page {
            guard pages.indices.contains(page), pages[page].indices.contains(slot.index) else { return }
            pages[page][slot.index] = item
        } else {
            guard dock.indices.contains(slot.index) else { return }
            dock[slot.index] = item
        }
    }

    /// Trailing empty pages are noise once their icons have moved away — the
    /// first page always stays.
    func pruneEmptyPages() {
        while pages.count > 1, pages.last?.allSatisfy({ $0 == nil }) == true {
            pages.removeLast()
        }
        persist()
    }

    /// One spare page to drag onto, the way iOS always keeps a page to the
    /// right of the last one while you are rearranging.
    func ensureSparePage(columns: Int) {
        guard pages.last?.contains(where: { $0 != nil }) == true else { return }
        let size = capacity(ofPage: pages.count, columns: columns)
        pages.append(Array(repeating: nil, count: size))
    }

    // MARK: - Defaults

    /// Version 1 changes the product from a showcase containing every mock app
    /// to a clean device containing only Settings. Apply that definition to
    /// saved layouts too, while leaving user-installed guest apps and their
    /// folders untouched.
    private func migrateInstalledBuiltinsIfNeeded(_ defaults: UserDefaults) {
        guard defaults.integer(forKey: builtinSetVersionKey) < Self.builtinSetVersion else { return }

        let installed = Set(HomeLayout.builtins)
        func isRetiredBuiltin(_ item: HomeItem?) -> Bool {
            guard let app = item?.builtinApp else { return false }
            return !installed.contains(app)
        }

        for pageIndex in pages.indices {
            for slotIndex in pages[pageIndex].indices
            where isRetiredBuiltin(pages[pageIndex][slotIndex]) {
                pages[pageIndex][slotIndex] = nil
            }
        }
        dock.removeAll { isRetiredBuiltin($0) }

        // A folder can contain built-ins as well. Empty folders disappear;
        // folders that still contain sideloaded apps retain their name and
        // position.
        for id in Array(folders.keys) {
            guard var folder = folders[id] else { continue }
            folder.items.removeAll { isRetiredBuiltin($0) }
            if folder.items.isEmpty {
                if let folderSlot = slot(of: .folder(id)) {
                    vacate(folderSlot, replacingWith: nil)
                }
                folders[id] = nil
            } else {
                folders[id] = folder
            }
        }

        while pages.count > 1, pages.last?.allSatisfy({ $0 == nil }) == true {
            pages.removeLast()
        }

        // Settings is the one app this configuration guarantees. Restore it
        // if an older layout had removed it before this migration ran.
        let settings = HomeItem.builtin(.settings)
        if !allApps.contains(settings) {
            placeInFirstFreeSlot(settings, preferring: 0, columns: 4)
        }

        known = Set(HomeLayout.builtins.map(\.rawValue))
        defaults.set(Self.builtinSetVersion, forKey: builtinSetVersionKey)
        persist()
    }

    private func adoptNewBuiltins() {
        let placed = Set(allApps.compactMap { $0.builtinApp?.rawValue })
        var appeared = false

        for app in HomeLayout.dock
        where !placed.contains(app.rawValue) && !known.contains(app.rawValue) {
            let item = HomeItem.builtin(app)
            if dock.count < Self.dockSlots {
                dock.append(item)
            } else {
                placeInFirstFreeSlot(item, preferring: 0, columns: 4)
            }
            appeared = true
        }
        for app in HomeLayout.pages.flatMap({ $0 })
        where !placed.contains(app.rawValue) && !known.contains(app.rawValue) {
            placeInFirstFreeSlot(.builtin(app), preferring: 0, columns: 4)
            appeared = true
        }

        known.formUnion(HomeLayout.builtins.map(\.rawValue))
        if appeared { persist() } else { UserDefaults.standard.set(Array(known), forKey: knownKey) }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(pages.map { $0.map { $0?.id ?? "" } }, forKey: pagesKey)
        defaults.set(dock.map(\.id), forKey: dockKey)
        defaults.set(Array(known), forKey: knownKey)
        defaults.set(folders.values.map { folder in
            ["id": folder.id.uuidString,
             "name": folder.name,
             "items": folder.items.map(\.id)] as [String: Any]
        }, forKey: foldersKey)
        defaults.set(widgets.values.map { placement in
            ["id": placement.id.uuidString,
             "descriptor": placement.descriptorID,
             "size": placement.size.rawValue]
        }, forKey: widgetsKey)
    }
}

extension HomeItem {
    /// Rebuilds an item from the id used to save it.
    init?(id: String) {
        if let raw = id.dropPrefixIfPresent("builtin."), let app = AppID(rawValue: raw) {
            self = .builtin(app)
        } else if let raw = id.dropPrefixIfPresent("folder."), let uuid = UUID(uuidString: raw) {
            self = .folder(uuid)
        } else if let raw = id.dropPrefixIfPresent("widget."), let uuid = UUID(uuidString: raw) {
            self = .widget(uuid)
        } else if let bundle = id.dropPrefixIfPresent("guest.") {
            self = .guest(bundle)
        } else {
            return nil
        }
    }
}

private extension String {
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
