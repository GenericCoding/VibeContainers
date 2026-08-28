import SwiftUI
import UniformTypeIdentifiers

/// Settings → ★ Tweaks.
///
/// Three tabs, because the job splits three ways: what is in the library and
/// how widely it applies (Tweaks), getting dylibs in and out and repairing
/// what they wrote (Manage), and what any one app is actually loading (Apps).
struct TweaksView: View {
    var onBack: () -> Void

    @State private var store = TweakStore.shared
    @State private var packages = PackageStore.shared
    @State private var tab = 0
    @State private var openApp: String?
    @State private var importing = false
    @State private var notice: Notice?

    @Environment(\.deviceSafeArea) private var safeArea

    private static let tabs = [
        TabItem(title: "Tweaks", symbol: "wrench.and.screwdriver.fill"),
        TabItem(title: "Manage", symbol: "tray.and.arrow.down.fill"),
        TabItem(title: "Apps", symbol: "square.stack.3d.up.fill")
    ]

    struct Notice: Identifiable {
        let message: String
        var good = false
        var id: String { message }
    }

    private var installed: [PackageStore.InstalledApp] { packages.installedList }

    var body: some View {
        ZStack(alignment: .top) {
            SysColor.groupedBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    if let notice {
                        NoticeCard(notice: notice) { self.notice = nil }
                    }
                    content
                }
                .padding(.top, safeArea.top + 60)
                .padding(.bottom, safeArea.bottom + 96)
            }

            InlineNavBar(title: title, backTitle: backTitle, onBack: back)

            AppTabBar(items: Self.tabs, selection: tabBinding)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [UTType(filenameExtension: "dylib") ?? .data, .framework],
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
        .task {
            store.refresh()
            let adopted = store.adoptLooseFiles()
            if !adopted.isEmpty {
                notice = Notice(message: "Adopted \(adopted.joined(separator: ", ")) from the Documents folder.", good: true)
            }
            for app in installed { store.refreshInjections(for: app.bundleIdentifier) }
        }
    }

    private var tabBinding: Binding<Int> {
        Binding(get: { tab }, set: { newValue in
            Haptics.selection()
            withAnimation(.easeOut(duration: 0.15)) {
                openApp = nil
                tab = newValue
            }
        })
    }

    private var title: String {
        if let bundle = openApp { return packages.installed[bundle]?.name ?? "App" }
        return tab == 0 ? "★ Tweaks" : Self.tabs[tab].title
    }

    private var backTitle: String { openApp == nil ? "Settings" : "Apps" }

    private func back() {
        if openApp == nil {
            onBack()
        } else {
            withAnimation(.appClose) { openApp = nil }
        }
    }

    @ViewBuilder private var content: some View {
        if let bundle = openApp, let app = packages.installed[bundle] {
            appPage(app)
        } else {
            switch tab {
            case 1: manageTab
            case 2: appsTab
            default: libraryTab
            }
        }
    }

    // MARK: - Library

    private var libraryTab: some View {
        VStack(spacing: 0) {
            if store.library.isEmpty {
                EmptyTweakNotice(
                    symbol: "wrench.and.screwdriver",
                    title: "No tweaks yet",
                    detail: "Add a .dylib in Manage. HelloDyld.dylib ships with VibeContainers as a sample."
                )
                .padding(.top, 30)
            } else {
                ListSection(
                    header: "Library",
                    footer: "A global tweak is written into every app's executable. Leave it off to pick apps one at a time in the Apps tab."
                ) {
                    ForEach(Array(store.library.enumerated()), id: \.element.id) { index, tweak in
                        ListRow(showsSeparator: index != store.library.count - 1, separatorInset: 16) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(tweak.name)
                                        .font(.system(size: 17))
                                        .foregroundStyle(tweak.isLoadable ? SysColor.label : SysColor.orange)
                                        .lineLimit(1)
                                    if tweak.isSample {
                                        TagPill(text: "SAMPLE", tint: SysColor.blue)
                                    }
                                }
                                Text(tweak.detail)
                                    .font(.system(size: 13))
                                    .foregroundStyle(SysColor.secondaryLabel)
                                    .lineLimit(1)
                                Text(scopeLine(tweak))
                                    .font(.system(size: 12))
                                    .foregroundStyle(SysColor.secondaryLabel.opacity(0.85))
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 6)
                        } trailing: {
                            VStack(spacing: 2) {
                                Toggle("", isOn: globalBinding(tweak))
                                    .labelsHidden()
                                    .tint(SysColor.green)
                                    .disabled(!tweak.isLoadable)
                                Text("Global")
                                    .font(.system(size: 11))
                                    .foregroundStyle(SysColor.secondaryLabel)
                            }
                        }
                    }
                }

                ListSection(footer: "Tweaks live in Documents/Tweaks — LiveContainer's global tweak folder. A guest resolves @loader_path/../../Tweaks to it.") {
                    InfoLine(title: "Tweaks", value: "\(store.library.count)")
                    InfoLine(title: "Global", value: "\(store.globals.count)")
                    InfoLine(title: "Apps patched", value: "\(patchedAppCount)", last: true)
                }
            }
        }
    }

    private var patchedAppCount: Int {
        installed.filter { store.enabledCount(for: $0.bundleIdentifier) > 0 }.count
    }

    private func scopeLine(_ tweak: TweakStore.Tweak) -> String {
        guard tweak.isLoadable else { return "dyld would refuse this one" }
        if store.isGlobal(tweak) {
            let blocked = installed.filter { store.isBlocked(tweak, in: $0.bundleIdentifier) }.count
            return blocked == 0
                ? "Global · every app"
                : "Global · blocked in \(blocked) app\(blocked == 1 ? "" : "s")"
        }
        let count = installed.filter { store.isEnabled(tweak, in: $0.bundleIdentifier) }.count
        return count == 0 ? "Not loaded anywhere" : "Loaded in \(count) app\(count == 1 ? "" : "s")"
    }

    // MARK: - Manage

    private var manageTab: some View {
        VStack(spacing: 0) {
            ListSection(
                header: "Add",
                footer: "Or drop a .dylib into the VibeContainers folder in Files — anything left loose in Documents is adopted into the tweak folder when this screen opens."
            ) {
                ListRow(separatorInset: 16, action: {
                    Haptics.tap(.light)
                    importing = true
                }) {
                    Label("Add Tweak…", systemImage: "plus.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(SysColor.blue)
                        .padding(.vertical, 2)
                }
                ListRow(showsSeparator: false, separatorInset: 16, action: {
                    Haptics.tap(.light)
                    let adopted = store.adoptLooseFiles()
                    notice = adopted.isEmpty
                        ? Notice(message: "No loose dylibs in the Documents folder.")
                        : Notice(message: "Adopted \(adopted.joined(separator: ", ")).", good: true)
                }) {
                    Label("Scan Documents Folder", systemImage: "folder.badge.gearshape")
                        .font(.system(size: 17))
                        .foregroundStyle(SysColor.blue)
                        .padding(.vertical, 2)
                }
            }

            ListSection(header: "Installed Tweaks",
                        footer: "Deleting a tweak first parks its load command in every app, so nothing is left naming a dylib that has gone.") {
                if store.library.isEmpty {
                    ListRow(showsSeparator: false, separatorInset: 16) {
                        Text("Nothing in the library")
                            .font(.system(size: 17))
                            .foregroundStyle(SysColor.secondaryLabel)
                    }
                }
                ForEach(Array(store.library.enumerated()), id: \.element.id) { index, tweak in
                    ListRow(showsSeparator: index != store.library.count - 1, separatorInset: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tweak.name)
                                .font(.system(size: 17))
                                .foregroundStyle(SysColor.label)
                                .lineLimit(1)
                            Text(tweak.loadPath)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(SysColor.secondaryLabel)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .padding(.vertical, 5)
                    } trailing: {
                        Button {
                            Haptics.tap(.rigid)
                            withAnimation(.snappy) { store.delete(tweak) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 16))
                                .foregroundStyle(SysColor.red)
                                .frame(width: 40, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ListSection(header: "Repair",
                        footer: "Re-writes every installed app's load commands from the library. Use it after re-downloading an app: a fresh executable arrives with no tweaks in it.") {
                ListRow(showsSeparator: false, separatorInset: 16, action: {
                    Haptics.tap(.medium)
                    run { try store.resyncAll() }
                    if notice == nil {
                        notice = Notice(message: "All installed apps re-synced.", good: true)
                    }
                }) {
                    Label("Re-sync All Apps", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 17))
                        .foregroundStyle(SysColor.blue)
                        .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Apps

    private var appsTab: some View {
        VStack(spacing: 0) {
            if installed.isEmpty {
                EmptyTweakNotice(
                    symbol: "square.stack.3d.up",
                    title: "Nothing installed",
                    detail: "Install an app from ★ Applications, then come back to choose its tweaks."
                )
                .padding(.top, 30)
            } else {
                ListSection(
                    header: "Installed Apps",
                    footer: "Switching a tweak on adds an LC_LOAD_DYLIB command to that app's executable, so dyld loads it before the app's own code. It takes effect the next time the app launches."
                ) {
                    ForEach(Array(installed.enumerated()), id: \.element.id) { index, app in
                        ListRow(
                            showsSeparator: index != installed.count - 1,
                            separatorInset: 68,
                            action: { withAnimation(.appLaunch) { openApp = app.bundleIdentifier } }
                        ) {
                            HStack(spacing: 12) {
                                PackageIcon(url: app.iconURL, tint: nil)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                        .font(.system(size: 17))
                                        .foregroundStyle(SysColor.label)
                                        .lineLimit(1)
                                    Text(subtitle(for: app))
                                        .font(.system(size: 13))
                                        .foregroundStyle(SysColor.secondaryLabel)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 6)
                        } trailing: {
                            Chevron()
                        }
                    }
                }
            }
        }
    }

    private func subtitle(for app: PackageStore.InstalledApp) -> String {
        guard store.isReady(app.bundleIdentifier) else { return "No payload — download it again" }
        let count = store.enabledCount(for: app.bundleIdentifier)
        let globals = store.library.filter {
            store.isGlobal($0) && store.isEnabled($0, in: app.bundleIdentifier)
        }.count
        switch count {
        case 0: return "No tweaks"
        default: return "\(count) loading · \(globals) global"
        }
    }

    // MARK: - One app

    @ViewBuilder
    private func appPage(_ app: PackageStore.InstalledApp) -> some View {
        let bundle = app.bundleIdentifier

        VStack(spacing: 0) {
            VStack(spacing: 10) {
                PackageIcon(url: app.iconURL, tint: nil, size: 64)
                Text(app.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(SysColor.label)
                Text(bundle)
                    .font(.system(size: 13))
                    .foregroundStyle(SysColor.secondaryLabel)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)

            if !store.isReady(bundle) {
                ListSection(footer: "There is no unpacked executable in this container, so there is nothing to write a load command into. Choices made here are applied once it is downloaded.") {
                    ListRow(showsSeparator: false, separatorInset: 16) {
                        Label("No payload", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 17))
                            .foregroundStyle(SysColor.orange)
                    }
                }
            }

            AppTweakSections(bundleIdentifier: bundle) { message in
                notice = Notice(message: message)
            }

            loadCommands(for: bundle)
        }
    }

    /// What the executable actually says, orphans included — the switches above
    /// can only speak for tweaks that are still in the library.
    @ViewBuilder
    private func loadCommands(for bundle: String) -> some View {
        let injected = store.injectedPaths(for: bundle).sorted { $0.key < $1.key }
        let known = Set(store.library.map(\.loadPath))

        if !injected.isEmpty {
            ListSection(
                header: "Load Commands",
                footer: "Read back from the executable's Mach-O header after every change."
            ) {
                ForEach(Array(injected.enumerated()), id: \.element.key) { index, entry in
                    let orphaned = !known.contains(entry.key)
                    ListRow(showsSeparator: index != injected.count - 1, separatorInset: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.value ? "LC_LOAD_DYLIB" : "parked (0x114514)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(entry.value ? SysColor.green : SysColor.secondaryLabel)
                            Text(entry.key)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(SysColor.secondaryLabel)
                                .lineLimit(1)
                                .truncationMode(.head)
                            if orphaned && entry.value {
                                Text("This file is no longer in the library — the app will not launch until it is switched off.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(SysColor.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 5)
                    } trailing: {
                        if orphaned && entry.value {
                            Button("Park") {
                                Haptics.tap(.rigid)
                                run { try store.disable(loadPath: entry.key, in: bundle) }
                            }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(SysColor.blue)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Plumbing

    private func globalBinding(_ tweak: TweakStore.Tweak) -> Binding<Bool> {
        Binding(
            get: { store.isGlobal(tweak) },
            set: { isOn in
                Haptics.selection()
                run { try store.setGlobal(isOn, tweak: tweak) }
            }
        )
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var failures: [String] = []
            var added: [String] = []
            for url in urls {
                do {
                    added.append(try store.importTweak(from: url).name)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            if failures.isEmpty {
                Haptics.tap(.medium)
                notice = Notice(message: "Added \(added.joined(separator: ", ")).", good: true)
            } else {
                notice = Notice(message: failures.joined(separator: "\n"))
            }
        case .failure(let error):
            notice = Notice(message: error.localizedDescription)
        }
    }

    private func run(_ work: () throws -> Void) {
        do {
            try work()
            notice = nil
        } catch {
            Haptics.tap(.rigid)
            notice = Notice(message: error.localizedDescription)
        }
    }
}

// MARK: - Per-app sections

/// The global/per-app switches for one app. Settings shows them on the app's
/// page; the container's pre-launch screen shows the same state in its own
/// card, both driven by `TweakStore`.
struct AppTweakSections: View {
    let bundleIdentifier: String
    var onError: (String) -> Void

    @State private var store = TweakStore.shared

    private var globals: [TweakStore.Tweak] { store.library.filter(store.isGlobal) }
    private var perApp: [TweakStore.Tweak] { store.library.filter { !store.isGlobal($0) } }

    var body: some View {
        VStack(spacing: 0) {
            if !globals.isEmpty {
                ListSection(
                    header: "Global Tweaks",
                    footer: "These are on for every app. Switching one off here blacklists it for \(bundleIdentifier) only; the tweak stays global everywhere else."
                ) {
                    ForEach(Array(globals.enumerated()), id: \.element.id) { index, tweak in
                        row(tweak, last: index == globals.count - 1)
                    }
                }
            }

            if perApp.isEmpty {
                if globals.isEmpty {
                    ListSection(footer: "Import a dylib in Manage first.") {
                        ListRow(showsSeparator: false, separatorInset: 16) {
                            Text("No tweaks in the library")
                                .font(.system(size: 17))
                                .foregroundStyle(SysColor.secondaryLabel)
                        }
                    }
                }
            } else {
                ListSection(
                    header: "App Tweaks",
                    footer: "Loaded into this app alone. Each switch adds or parks one load command; a parked command keeps its slot, so turning a tweak back on never needs more room in the binary."
                ) {
                    ForEach(Array(perApp.enumerated()), id: \.element.id) { index, tweak in
                        row(tweak, last: index == perApp.count - 1)
                    }
                }
            }
        }
    }

    private func row(_ tweak: TweakStore.Tweak, last: Bool) -> some View {
        ListRow(showsSeparator: !last, separatorInset: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tweak.name)
                        .font(.system(size: 17))
                        .foregroundStyle(tweak.isLoadable ? SysColor.label : SysColor.orange)
                        .lineLimit(1)
                    if tweak.isSample { TagPill(text: "SAMPLE", tint: SysColor.blue) }
                }
                Text(caption(tweak))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(captionTint(tweak))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.vertical, 5)
        } trailing: {
            Toggle("", isOn: binding(tweak))
                .labelsHidden()
                .tint(SysColor.green)
                .disabled(!tweak.isLoadable)
        }
    }

    private func caption(_ tweak: TweakStore.Tweak) -> String {
        guard tweak.isLoadable else { return tweak.detail }
        switch store.reason(for: tweak, in: bundleIdentifier) {
        case .blocked: return "blacklisted for this app"
        case .global, .app: return tweak.loadPath
        case .off: return "not injected"
        }
    }

    private func captionTint(_ tweak: TweakStore.Tweak) -> Color {
        switch store.reason(for: tweak, in: bundleIdentifier) {
        case .blocked: return SysColor.orange
        case .global, .app: return SysColor.secondaryLabel
        case .off: return SysColor.secondaryLabel.opacity(0.8)
        }
    }

    private func binding(_ tweak: TweakStore.Tweak) -> Binding<Bool> {
        Binding(
            get: { store.isEnabled(tweak, in: bundleIdentifier) },
            set: { isOn in
                Haptics.selection()
                do {
                    try store.setEnabled(isOn, tweak: tweak, in: bundleIdentifier)
                } catch {
                    Haptics.tap(.rigid)
                    onError(error.localizedDescription)
                }
            }
        )
    }
}

// MARK: - Small pieces

struct TagPill: View {
    let text: String
    var tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.16)))
    }
}

private struct InfoLine: View {
    let title: String
    let value: String
    var last = false

    var body: some View {
        ListRow(showsSeparator: !last, separatorInset: 16) {
            Text(title).font(.system(size: 17)).foregroundStyle(SysColor.label)
        } trailing: {
            Text(value).font(.system(size: 17)).foregroundStyle(SysColor.secondaryLabel)
        }
    }
}

private struct EmptyTweakNotice: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(SysColor.secondaryLabel)
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(SysColor.label)
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(SysColor.secondaryLabel)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }
}

/// An inline strip. The simulator draws its own chrome, so a UIKit alert would
/// arrive from outside the illusion.
private struct NoticeCard: View {
    let notice: TweaksView.Notice
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(notice.good ? SysColor.green : SysColor.orange)
            Text(notice.message)
                .font(.system(size: 13))
                .foregroundStyle(SysColor.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SysColor.secondaryLabel)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(SysColor.secondaryGrouped)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder((notice.good ? SysColor.green : SysColor.orange).opacity(0.35), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
    }
}
