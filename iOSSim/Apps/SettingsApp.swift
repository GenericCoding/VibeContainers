import SwiftUI
import Darwin
import UniformTypeIdentifiers

@_silgen_name("IOSSimProbeJIT")
private func IOSSimProbeJIT() -> Int32

struct SettingsApp: View {
    private enum Page: String, Identifiable {
        case about, controller, customization, jit, multitasking, tweaks, webServer, packages
        var id: String { rawValue }

        var title: String {
            switch self {
            case .about: "About"
            case .controller: "Controller mode"
            case .customization: "Customization"
            case .jit: "JIT & Containers"
            case .multitasking: "Multitasking"
            case .tweaks: "Tweaks"
            case .webServer: "HTTP Server"
            case .packages: "Applications"
            }
        }

        var mark: SettingsMark {
            switch self {
            case .about: .about
            case .controller: .controller
            case .customization: .customization
            case .jit: .jit
            case .multitasking: .multitasking
            case .tweaks: .tweaks
            case .webServer: .webServer
            case .packages: .packages
            }
        }
    }

    @State private var search = ""
    @State private var detail: Page?
    @State private var jitProbe: JITProbeState = .untested
    @State private var importingCertificate = false
    @State private var showingCertificatePassword = false
    @State private var pendingCertificate: Data?
    @State private var certificatePassword = ""
    @State private var certificateBusy = false
    @State private var certificateNotice: String?
    @State private var certificateNoticeIsError = false
    @State private var importingWallpaper = false
    @State private var wallpaperBusy = false
    @State private var wallpaperNotice: String?
    @State private var wallpaperNoticeIsError = false
    @State private var controllers = ControllerHub.shared
    @State private var wallpapers = WallpaperStore.shared
    @AppStorage("IOSSimMultitaskingEnabled") private var multitaskingEnabled = true
    @AppStorage("LCLaunchMultitaskMaximized") private var launchMultitaskMaximized = true
    @AppStorage("LCMultitaskMode", store: MultitaskPreferences.sharedDefaults)
    private var multitaskMode = 0
    @AppStorage("LCMultitaskOverlayMode", store: MultitaskPreferences.sharedDefaults)
    private var multitaskOverlayMode = true
    @AppStorage("LCMultitaskBottomWindowBar", store: MultitaskPreferences.sharedDefaults)
    private var bottomWindowBar = false
    @AppStorage("LCHideCollapsedDock", store: MultitaskPreferences.sharedDefaults)
    private var hideCollapsedDock = false
    @AppStorage("LCMaxOneAppOnStage", store: MultitaskPreferences.sharedDefaults)
    private var oneAppOnStage = false
    @AppStorage("LCDockWidth", store: MultitaskPreferences.sharedDefaults)
    private var multitaskDockWidth = 80.0

    /// The live theme. Everything on the Customization page writes straight
    /// through to this, so changes land on the home screen immediately.
    @Bindable private var appearance = Appearance.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                root
                    .offset(x: detail == nil ? 0 : -geo.size.width * 0.3)
                    .overlay(Color.black.opacity(detail == nil ? 0 : 0.2))
                    .disabled(detail != nil)

                if let page = detail {
                    detailView(page)
                        .transition(.move(edge: .trailing))
                        .zIndex(1)
                }
            }
        }
        .background(SysColor.groupedBackground)
        .onAppear { runJITProbe(haptic: false) }
        .onAppIntent(.settings) { intent in
            detail = intent == .settingsPackages ? .packages : .customization
        }
        .fileImporter(
            isPresented: $importingCertificate,
            allowedContentTypes: [
                UTType(filenameExtension: "p12") ?? .data,
                UTType(filenameExtension: "pfx") ?? .data
            ]
        ) { result in
            selectCertificate(result)
        }
        .fileImporter(
            isPresented: $importingWallpaper,
            allowedContentTypes: WallpaperStore.supportedContentTypes
        ) { result in
            selectWallpaper(result)
        }
        .alert("Certificate Password", isPresented: $showingCertificatePassword) {
            SecureField("Password (may be empty)", text: $certificatePassword)
            Button("Cancel", role: .cancel) { pendingCertificate = nil }
            Button("Import") {
                Task { await finishCertificateImport() }
            }
        } message: {
            Text("Enter the password for the PKCS#12 identity used to sign this installation of VibeContainers.")
        }
    }

    private func push(_ page: Page) { withAnimation(.appLaunch) { detail = page } }
    private func pop() { withAnimation(.appClose) { detail = nil } }

    // MARK: - Root

    private var root: some View {
        AppScaffold(title: "Settings", searchable: true, searchText: $search) {
            VStack(spacing: 0) {
                ForEach(sections) { section in
                    ListSection(header: section.title, footer: section.footer) {
                        ForEach(Array(section.pages.enumerated()), id: \.element.id) { index, page in
                            row(page, last: index == section.pages.count - 1)
                        }
                    }
                }

                if sections.isEmpty {
                    Text("Nothing matches “\(search)”.")
                        .font(.system(size: 15))
                        .foregroundStyle(SysColor.secondaryLabel)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                }
            }
        }
    }

    private func row(_ page: Page, last: Bool) -> some View {
        ListRow(showsSeparator: !last, separatorInset: 57, action: { push(page) }) {
            HStack(spacing: 12) {
                SettingsMarkTile(mark: page.mark)
                Text(page.title)
                    .font(.system(size: 17))
                    .foregroundStyle(SysColor.label)
            }
        } trailing: {
            accessory(for: page)
        }
    }

    /// The status each row carries on its right-hand side.
    @ViewBuilder
    private func accessory(for page: Page) -> some View {
        switch page {
        case .packages where updateCount > 0:
            HStack(spacing: 8) {
                BadgeView(count: updateCount).scaleEffect(0.85)
                Chevron()
            }
        case .webServer:
            HStack(spacing: 8) {
                Circle()
                    .fill(serverRunning ? SysColor.green : SysColor.secondaryLabel.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(serverRunning ? "On" : "Off")
                    .font(.system(size: 15))
                    .foregroundStyle(SysColor.secondaryLabel)
                Chevron()
            }
        case .tweaks where tweakCount > 0:
            HStack(spacing: 8) {
                Text("\(tweakCount)")
                    .font(.system(size: 15))
                    .foregroundStyle(SysColor.secondaryLabel)
                Chevron()
            }
        case .jit:
            HStack(spacing: 8) {
                Image(systemName: JITLessSigner.isAvailableForLaunch ? "checkmark.shield.fill" : jitProbe.statusIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(JITLessSigner.isAvailableForLaunch ? SysColor.green : jitProbe.color)
                Text(JITLessSigner.isAvailableForLaunch ? "JIT-less" : jitProbe.shortLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SysColor.secondaryLabel)
                Chevron()
            }
        case .controller:
            HStack(spacing: 8) {
                Text(controllers.isConnected ? "Connected" : "Landscape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SysColor.secondaryLabel)
                Chevron()
            }
        default:
            Chevron()
        }
    }

    private var updateCount: Int { PackageStore.shared.updates.count }
    private var tweakCount: Int { TweakStore.shared.library.count }
    private var serverRunning: Bool { WebServer.shared.status.isRunning }

    private struct Group: Identifiable {
        let title: String
        let footer: String?
        let pages: [Page]
        var id: String { title }
    }

    /// Grouped by what each page is *for*: the guest-container stack, the
    /// services this device offers, and the simulator's own appearance.
    ///
    /// JIT sits with Containers rather than System because what it actually
    /// reports is whether a container is allowed to launch at all.
    private var sections: [Group] {
        let all = [
            Group(title: "Containers",
                  footer: "Sideloaded apps, the dylibs injected into them, and whether this process may run them.",
                  pages: [.packages, .tweaks, .jit, .multitasking]),
            Group(title: "System",
                  footer: "Services this device offers to the network around it.",
                  pages: [.webServer]),
            Group(title: "Application",
                  footer: nil,
                  pages: [.controller, .customization, .about])
        ]

        guard !search.isEmpty else { return all }
        return all.compactMap { group in
            let matches = group.pages.filter { $0.title.localizedCaseInsensitiveContains(search) }
            guard !matches.isEmpty else { return nil }
            return Group(title: group.title, footer: nil, pages: matches)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private func detailView(_ page: Page) -> some View {
        switch page {
        case .packages:
            // Packages pushes its own screens, so it brings its own chrome.
            PackagesView(onBack: pop)
        case .tweaks:
            // Same again: Tweaks pushes a page per app.
            TweaksView(onBack: pop)
        case .webServer:
            WebServerView(onBack: pop)
        case .about:
            SettingsDetailScaffold(title: page.title, onBack: pop) { aboutPage }
        case .controller:
            SettingsDetailScaffold(title: page.title, onBack: pop) { controllerPage }
        case .customization:
            SettingsDetailScaffold(title: page.title, onBack: pop) { customizationPage }
        case .jit:
            SettingsDetailScaffold(title: page.title, onBack: pop) { jitPage }
        case .multitasking:
            SettingsDetailScaffold(title: page.title, onBack: pop) { multitaskingPage }
        }
    }

    // MARK: Multitasking

    private var multitaskingPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                SettingsMarkTile(mark: .multitasking, size: 64)
                Text("Independent guest windows")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(SysColor.label)
                Text("Container apps run in separate LiveProcess instances on both iPhone and iPad, while VibeContainers stays available behind them.")
                    .font(.system(size: 14))
                    .foregroundStyle(SysColor.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)

            ListSection(
                header: "Launching",
                footer: "On a physical device, independent guests use the JIT-less certificate imported on the JIT & Containers page. Compatibility mode uses the older full-app relaunch."
            ) {
                ToggleRow(title: "Run Apps in Multitasking", isOn: $multitaskingEnabled)
                ToggleRow(title: "Open Maximized", isOn: $launchMultitaskMaximized)
                ToggleRow(title: "Overlay Controls", isOn: $multitaskOverlayMode, last: true)
            }

            ListSection(
                header: "Window Style",
                footer: "Floating windows work on iPhone and iPad. Native system windows use iOS multi-scene presentation when the current device supports it."
            ) {
                ToggleRow(
                    title: "Native System Windows",
                    isOn: Binding(
                        get: { multitaskMode == 1 },
                        set: { multitaskMode = $0 ? 1 : 0 }
                    )
                )
                ToggleRow(title: "Controls at Bottom", isOn: $bottomWindowBar)
                ToggleRow(title: "One Maximized App", isOn: $oneAppOnStage, last: true)
            }

            ListSection(header: "Floating Dock") {
                ToggleRow(title: "Hide When Collapsed", isOn: $hideCollapsedDock)
                ListRow(showsSeparator: false, separatorInset: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Dock Size")
                                .font(.system(size: 17))
                                .foregroundStyle(SysColor.label)
                            Spacer()
                            Text("\(Int(multitaskDockWidth))")
                                .font(.system(size: 15))
                                .foregroundStyle(SysColor.secondaryLabel)
                        }
                        Slider(value: $multitaskDockWidth, in: 56...110, step: 1)
                            .tint(SysColor.blue)
                    }
                    .padding(.vertical, 9)
                }
            }
        }
    }

    // MARK: Controller mode

    private var controllerPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(SysColor.blue.opacity(0.15))
                        .frame(width: 82, height: 82)
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(SysColor.blue)
                }

                Text("Controller mode")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(SysColor.label)
                Text("Open the controller dashboard without pairing a gamepad. VibeContainers switches to landscape and adds touch controls for testing.")
                    .font(.system(size: 14))
                    .foregroundStyle(SysColor.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)

            ListSection(header: "Controller",
                        footer: "Use Exit Controller mode in the dashboard to return to Settings and portrait mode.") {
                InfoRow(title: "Physical controllers",
                        value: controllers.pads.isEmpty ? "None" : "\(controllers.pads.count)")
                InfoRow(title: "Display", value: "Landscape")
                ListRow(showsSeparator: false, action: openControllerMode) {
                    Label("Open Controller mode", systemImage: "rectangle.landscape.rotate")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SysColor.blue)
                } trailing: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SysColor.blue)
                }
            }
        }
    }

    private func openControllerMode() {
        Haptics.tap(.medium)
        controllers.enterControllerUITestMode()
    }

    // MARK: JIT & Containers

    private var jitPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(containerLaunchColor.opacity(0.16))
                        .frame(width: 82, height: 82)
                    Image(systemName: containerLaunchAvailable ? "checkmark" : "bolt.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(containerLaunchColor)
                }

                HStack(spacing: 8) {
                    Image(systemName: JITLessSigner.isAvailableForLaunch
                          ? "checkmark.shield.fill" : jitProbe.statusIcon)
                        .foregroundStyle(containerLaunchColor)
                    Text(JITLessSigner.isAvailableForLaunch ? "JIT-less Launch Ready" : jitProbe.title)
                        .foregroundStyle(SysColor.label)
                }
                .font(.system(size: 22, weight: .semibold))
                Text(JITLessSigner.isAvailableForLaunch
                     ? "Guests are signed on this device with VibeContainers' bundle ID and can launch without enabling JIT."
                     : jitProbe.detail)
                    .font(.system(size: 14))
                    .foregroundStyle(SysColor.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)

            ListSection(
                header: "JIT-less signing",
                footer: "Import the PKCS#12 (.p12/.pfx) development identity used to install VibeContainers. A bundled identity remains extractable from the IPA, and its password is never bundled. ZSign changes the Mach-O signing identifier, not the guest app's own Info.plist bundle ID."
            ) {
                InfoRow(title: "Status", value: JITLessSigner.isConfigured ? "Configured" : "Not configured")
                InfoRow(title: "Signing bundle ID", value: Bundle.main.bundleIdentifier ?? "Unknown")
                if let team = JITLessSigner.teamIdentifier {
                    InfoRow(title: "Team", value: team)
                }
                if let certificateNotice {
                    ListRow(separatorInset: 16) {
                        Label(certificateNotice,
                              systemImage: certificateNoticeIsError
                                ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(certificateNoticeIsError ? SysColor.orange : SysColor.green)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 7)
                    }
                }
                if JITLessSigner.hasBundledCertificate {
                    ListRow(showsSeparator: true,
                            action: certificateBusy ? nil : selectBundledCertificate) {
                        Label("Use Bundled Certificate", systemImage: "shippingbox.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(certificateBusy ? SysColor.secondaryLabel : SysColor.blue)
                    }
                }
                ListRow(showsSeparator: JITLessSigner.isConfigured,
                        action: certificateBusy ? nil : { importingCertificate = true }) {
                    Label(JITLessSigner.isConfigured ? "Replace Certificate" : "Import Certificate",
                          systemImage: "square.and.arrow.down.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(certificateBusy ? SysColor.secondaryLabel : SysColor.blue)
                } trailing: {
                    if certificateBusy { ProgressView() }
                }
                if JITLessSigner.isConfigured {
                    ListRow(showsSeparator: false, action: removeCertificate) {
                        Label("Remove Certificate", systemImage: "trash")
                            .font(.system(size: 17))
                            .foregroundStyle(SysColor.red)
                    }
                }
            }

            ListSection(
                header: "JIT capability",
                footer: "This status check never executes generated code on a physical device. JIT-less signing independently enables ordinary signed guests; apps that generate executable code still need a JIT provider."
            ) {
                InfoRow(title: "Host", value: HostPlatform.isSimulator ? "Simulator" : "Physical device")
                InfoRow(title: "Architecture", value: "arm64")
                InfoRow(title: "Check", value: HostPlatform.isSimulator ? "Host runtime" : "Provider state")
                InfoRow(title: "Container launch",
                        value: containerLaunchAvailable
                            ? (JITLessSigner.isAvailableForLaunch ? "Enabled · signed" : "Enabled · JIT")
                            : "Blocked",
                        last: true)
            }

            ListSection {
                ListRow(showsSeparator: false, action: { runJITProbe() }) {
                    Label("Refresh JIT Status", systemImage: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SysColor.blue)
                } trailing: {
                    if jitProbe.isAvailable {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(SysColor.green)
                    }
                }
            }
        }
        .onAppear { runJITProbe(haptic: false) }
    }

    private func runJITProbe(haptic: Bool = true) {
        let result = IOSSimProbeJIT()
        jitProbe = result == 0 ? .available : .unavailable(result)
        if haptic { Haptics.tap(result == 0 ? .medium : .rigid) }
    }

    private var containerLaunchAvailable: Bool {
        jitProbe.isAvailable || JITLessSigner.isAvailableForLaunch
    }

    private var containerLaunchColor: Color {
        containerLaunchAvailable ? SysColor.green : jitProbe.color
    }

    private func selectCertificate(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let ext = url.pathExtension.lowercased()
        guard ext == "p12" || ext == "pfx" else {
            certificateNotice = "Choose a PKCS#12 .p12 or .pfx identity."
            certificateNoticeIsError = true
            return
        }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            pendingCertificate = try Data(contentsOf: url)
            certificatePassword = ""
            showingCertificatePassword = true
        } catch {
            certificateNotice = "Could not read the certificate: \(error.localizedDescription)"
            certificateNoticeIsError = true
        }
    }

    private func selectBundledCertificate() {
        do {
            pendingCertificate = try JITLessSigner.bundledCertificate()
            certificatePassword = ""
            showingCertificatePassword = true
        } catch {
            certificateNotice = error.localizedDescription
            certificateNoticeIsError = true
        }
    }

    private func finishCertificateImport() async {
        guard let pendingCertificate else { return }
        certificateBusy = true
        defer {
            certificateBusy = false
            self.pendingCertificate = nil
            certificatePassword = ""
        }
        do {
            try await JITLessSigner.configure(
                certificate: pendingCertificate,
                password: certificatePassword
            )
            certificateNotice = "Identity validated. Installed guests will be signed at launch."
            certificateNoticeIsError = false
            Haptics.tap(.medium)
        } catch {
            certificateNotice = error.localizedDescription
            certificateNoticeIsError = true
            Haptics.tap(.rigid)
        }
    }

    private func removeCertificate() {
        JITLessSigner.remove()
        certificateNotice = "The JIT-less signing identity was removed."
        certificateNoticeIsError = false
        Haptics.tap(.rigid)
    }

    // MARK: About

    private var aboutPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                ZStack {
                    if let appIcon = HostAppIcon.image {
                        Image(uiImage: appIcon)
                            .resizable()
                            .scaledToFill()
                    } else {
                        SettingsMarkTile(mark: .about, size: 64)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
                Text("VibeContainers")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(SysColor.label)
                Text("Presented by @GenericCoding")
                    .font(.system(size: 14))
                    .foregroundStyle(SysColor.secondaryLabel)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 26)

            ListSection {
                InfoRow(title: "Version", value: "1.0 (41)")
                InfoRow(title: "Model", value: DeviceIdentity.phoneModelName)
                InfoRow(title: "Capacity", value: "128 GB", last: true)
            }

            ListSection(header: "Acknowledgements") {
                ListRow {
                    Text("Thanks Duy Trans for livecontainers")
                        .font(.system(size: 17))
                        .foregroundStyle(SysColor.label)
                }
                ListRow(showsSeparator: false) {
                    Text("Proudly opensource GNU Affero General Public License v3.0")
                        .font(.system(size: 17))
                        .foregroundStyle(SysColor.label)
                }
            }
        }
    }

    // MARK: Customization

    private var customizationPage: some View {
        VStack(spacing: 0) {
            ListSection(header: "Accent",
                        footer: "Tints buttons, links and controls across every app.") {
                ListRow(showsSeparator: false) {
                    HStack(spacing: 14) {
                        ForEach(Array(AccentChoice.all.enumerated()), id: \.offset) { index, choice in
                            Button {
                                Haptics.selection()
                                withAnimation(appearance.animation(.snappy)) {
                                    appearance.accentIndex = index
                                }
                            } label: {
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 30, height: 30)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(
                                                SysColor.label,
                                                lineWidth: appearance.accentIndex == index ? 2 : 0
                                            )
                                            .padding(-3)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                }
            }

            ListSection(header: "Wallpaper",
                        footer: "Images stay still. GIF, video, and Tendies wallpapers animate unless Reduce Motion is on. Controller mode keeps its own dashboard background.") {
                ForEach(WallpaperStyle.allCases) { style in
                    ListRow(separatorInset: 16, action: {
                        Haptics.selection()
                        withAnimation(.easeInOut(duration: 0.25)) {
                            wallpapers.selectBuiltIn()
                            appearance.wallpaperStyle = style
                        }
                    }) {
                        Label(style.title, systemImage: "circle.hexagongrid.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(SysColor.label)
                    } trailing: {
                        if wallpapers.selected == nil && appearance.wallpaperStyle == style {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(SysColor.blue)
                        }
                    }
                }

                ForEach(wallpapers.items) { item in
                    ListRow(separatorInset: 16, action: {
                        Haptics.selection()
                        withAnimation(.easeInOut(duration: 0.25)) {
                            wallpapers.select(item)
                        }
                    }) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.system(size: 17))
                                    .foregroundStyle(SysColor.label)
                                    .lineLimit(1)
                                Text(item.kind.title)
                                    .font(.system(size: 13))
                                    .foregroundStyle(SysColor.secondaryLabel)
                            }
                        } icon: {
                            Image(systemName: item.kind.symbol)
                                .foregroundStyle(SysColor.blue)
                                .frame(width: 22)
                        }
                    } trailing: {
                        if wallpapers.selectedID == item.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(SysColor.blue)
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            removeWallpaper(item)
                        } label: {
                            Label("Remove Wallpaper", systemImage: "trash")
                        }
                    }
                }

                if let wallpaperNotice {
                    ListRow(separatorInset: 16) {
                        Label(
                            wallpaperNotice,
                            systemImage: wallpaperNoticeIsError
                                ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(wallpaperNoticeIsError ? SysColor.orange : SysColor.green)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                    }
                }

                ListRow(separatorInset: 16, action: wallpaperBusy ? nil : {
                    importingWallpaper = true
                }) {
                    Label("Choose Wallpaper…", systemImage: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(wallpaperBusy ? SysColor.secondaryLabel : SysColor.blue)
                } trailing: {
                    if wallpaperBusy { ProgressView() }
                }

                if let selected = wallpapers.selected {
                    ListRow(separatorInset: 16, action: { removeWallpaper(selected) }) {
                        Label("Remove \(selected.name)", systemImage: "trash")
                            .font(.system(size: 17))
                            .foregroundStyle(SysColor.red)
                            .lineLimit(1)
                    }
                }
                ToggleRow(title: "Reduce Motion", isOn: $appearance.reduceMotion, last: true)
            }

            ListSection(header: "Screen Switch",
                        footer: "Applied while you swipe between home screen pages, not just at the end of one.") {
                ForEach(Array(PageTransition.allCases.enumerated()), id: \.element.id) { index, style in
                    ListRow(
                        showsSeparator: index != PageTransition.allCases.count - 1,
                        separatorInset: 16,
                        action: {
                            Haptics.selection()
                            appearance.pageTransition = style
                        }
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(style.title)
                                .font(.system(size: 17))
                                .foregroundStyle(SysColor.label)
                            Text(style.detail)
                                .font(.system(size: 13))
                                .foregroundStyle(SysColor.secondaryLabel)
                        }
                        .padding(.vertical, 5)
                    } trailing: {
                        if appearance.pageTransition == style {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(SysColor.blue)
                        }
                    }
                }
            }

            ListSection(header: "Home Screen") {
                ListRow(separatorInset: 16) {
                    Text("Icon Layout").font(.system(size: 17)).foregroundStyle(SysColor.label)
                } trailing: {
                    Picker("", selection: $appearance.columns) {
                        Text("4 × 6").tag(4)
                        Text("5 × 6").tag(5)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
                ToggleRow(title: "App Labels", isOn: $appearance.showLabels)
                ToggleRow(title: "Hide Dock Background", isOn: $appearance.hideDockBackground, last: true)
            }
        }
    }

    private func selectWallpaper(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        wallpaperBusy = true
        wallpaperNotice = nil

        Task {
            defer { wallpaperBusy = false }
            do {
                let wallpaper = try await wallpapers.importWallpaper(from: url)
                wallpaperNotice = "\(wallpaper.name) was added and selected."
                wallpaperNoticeIsError = false
                Haptics.tap(.medium)
            } catch {
                wallpaperNotice = error.localizedDescription
                wallpaperNoticeIsError = true
                Haptics.tap(.rigid)
            }
        }
    }

    private func removeWallpaper(_ wallpaper: ImportedWallpaper) {
        do {
            try wallpapers.remove(wallpaper)
            wallpaperNotice = "\(wallpaper.name) was removed."
            wallpaperNoticeIsError = false
            Haptics.tap(.rigid)
        } catch {
            wallpaperNotice = "Could not remove the wallpaper: \(error.localizedDescription)"
            wallpaperNoticeIsError = true
        }
    }
}

private enum JITProbeState: Equatable {
    case untested
    case available
    case unavailable(Int32)

    var isAvailable: Bool { self == .available }

    var shortLabel: String {
        switch self {
        case .untested: "Unknown"
        case .available: "Available"
        case .unavailable: "Unavailable"
        }
    }

    var title: String {
        switch self {
        case .untested: "JIT Status Unknown"
        case .available: "JIT Available"
        case .unavailable: "JIT Unavailable"
        }
    }

    var statusIcon: String {
        switch self {
        case .untested: "questionmark.circle.fill"
        case .available: "checkmark.circle.fill"
        case .unavailable: "xmark.circle.fill"
        }
    }

    var detail: String {
        switch self {
        case .untested:
            "Refresh the safe JIT capability status for this process."
        case .available:
            HostPlatform.isSimulator
                ? "The Simulator host runtime supports container launch."
                : "A debugger or JIT-provider state is active. No generated code was executed by this check."
        case .unavailable(let code):
            "No active JIT provider was detected: \(String(cString: strerror(code))). Enable JIT for VibeContainers or use JIT-less signing."
        }
    }

    var color: Color {
        switch self {
        case .untested: SysColor.orange
        case .available: SysColor.green
        case .unavailable: SysColor.red
        }
    }
}

// MARK: - Supporting rows

private struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var last = false

    var body: some View {
        ListRow(showsSeparator: !last, separatorInset: 16) {
            Text(title).font(.system(size: 17)).foregroundStyle(SysColor.label)
        } trailing: {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(SysColor.green)
        }
    }
}

private struct InfoRow: View {
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

/// Pushed Settings page: inline bar + scrolling grouped content.
private struct SettingsDetailScaffold<Content: View>: View {
    let title: String
    var onBack: () -> Void
    @ViewBuilder var content: Content

    @Environment(\.deviceSafeArea) private var safeArea

    var body: some View {
        ZStack(alignment: .top) {
            SysColor.groupedBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) { content }
                    .padding(.top, safeArea.top + 60)
                    .padding(.bottom, safeArea.bottom + 40)
            }

            InlineNavBar(title: title, backTitle: "Settings", onBack: onBack)
        }
    }
}
