import SwiftUI

/// What a guest app launches into: LiveContainer's container screen.
///
/// The real work lives behind the buttons. Download fetches the actual `.ipa`
/// from the version's `downloadURL`, unpacks `Payload/<App>.app` into the
/// container and patches the executable with LiveContainer's upstream patcher.
/// Launch uses LiveContainer's signed or JIT/dyld bootstrap and guest-main handoff.
struct GuestContainerView: View {
    let bundleIdentifier: String
    var onClose: (() -> Void)? = nil

    @State private var containers = GuestContainerStore.shared
    @State private var store = PackageStore.shared
    @State private var installer = GuestInstaller.shared
    @State private var usage = GuestContainerStore.Usage(files: 0, bytes: 0)
    @State private var report: GuestInstaller.LaunchOutcome?
    @State private var binaryInfo: MachO.Info?
    @State private var tweaks = TweakStore.shared
    @State private var tweakError: String?

    @Environment(\.deviceSafeArea) private var safeArea
    @Environment(\.dismissApp) private var dismissApp

    private var record: PackageStore.InstalledApp? { store.installed[bundleIdentifier] }
    private var container: GuestContainerStore.Container? { containers.container(for: bundleIdentifier) }
    private var phase: GuestInstaller.Phase { installer.phase(for: bundleIdentifier) }

    private var installed: Bool {
        guard let container else { return false }
        return containers.hasPayload(container)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.surface, Palette.ink],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    header
                    primaryButton
                    if let report { reportCard(report) }
                    tweaksCard
                    if binaryInfo != nil { binaryCard }
                    containerCard
                    Spacer(minLength: 0)
                }
                .padding(.top, safeArea.top + 26)
                .padding(.bottom, safeArea.bottom + 40)
            }
        }
        .onAppear {
            refreshUsage()
            refreshBinary()
            tweaks.refresh()
            tweaks.refreshInjections(for: bundleIdentifier)
            if let launchError = installer.consumeLaunchError(for: bundleIdentifier) {
                report = launchError
            }
        }
        .onChange(of: phase) { _, new in
            if new == .ready {
                refreshUsage()
                refreshBinary()
                // The download replaced the executable, so the load commands
                // went with it. Write this app's tweaks back into the new one.
                syncTweaks()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            PackageIcon(url: record?.iconURL, tint: nil, size: 92)
                .shadow(color: Palette.ink.opacity(0.5), radius: 14, y: 6)

            Text(record?.name ?? bundleIdentifier)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(SysColor.label)

            Text(subtitleLine)
                .font(.system(size: 14))
                .foregroundStyle(SysColor.secondaryLabel)

            if let source = record?.sourceName {
                Text(source)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SysColor.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(SysColor.blue.opacity(0.15)))
            }
        }
        .padding(.horizontal, 20)
    }

    private var subtitleLine: String {
        var parts: [String] = []
        if let developer = record?.developer { parts.append(developer) }
        if let version = record?.version { parts.append("Version \(version)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Primary button

    @ViewBuilder private var primaryButton: some View {
        switch phase {
        case .downloading(let progress):
            progressButton("Downloading \(Int(progress * 100))%", progress: progress)
        case .unpacking:
            progressButton("Unpacking IPA…", progress: nil)
        case .preparing:
            progressButton("Preparing LiveContainer…", progress: nil)
        default:
            Button(action: primaryAction) {
                HStack(spacing: 8) {
                    Image(systemName: installed ? "play.fill" : "arrow.down.circle.fill")
                    Text(installed ? "Launch in Container" : "Download & Install")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule().fill(SysColor.blue))
                .padding(.horizontal, 20)
            }
            .buttonStyle(.plain)
        }
    }

    private func progressButton(_ label: String, progress: Double?) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().tint(Palette.ink)
                Text(label).font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Capsule().fill(SysColor.blue.opacity(0.85)))

            if let progress {
                ProgressView(value: progress).tint(SysColor.blue)
            }
        }
        .padding(.horizontal, 20)
    }

    private func primaryAction() {
        if installed {
            report = GuestInstaller.LaunchOutcome(
                ok: true,
                headline: JITLessSigner.isAvailableForLaunch ? "Signing for device" : "Preparing launch",
                detail: JITLessSigner.isAvailableForLaunch
                    ? "ZSign is applying VibeContainers' signing identity to the guest and its tweaks."
                    : "Checking the LiveContainer launch path."
            )
            Task {
                report = await installer.launch(container!)
                Haptics.tap(report?.ok == true ? .medium : .rigid)
            }
        } else {
            guard let container, let app = appFromCatalog() else {
                report = GuestInstaller.LaunchOutcome(
                    ok: false, headline: "Not in a loaded source",
                    detail: "Refresh the source this app came from, or install its .ipa again from ★ Applications."
                )
                return
            }
            report = nil
            Task { await installer.install(app, into: container) }
        }
    }

    /// The live `AltApp` for this bundle, needed for its download URL.
    private func appFromCatalog() -> AltApp? {
        store.entry(bundleIdentifier: bundleIdentifier)?.app
    }

    // MARK: - Report

    private func reportCard(_ report: GuestInstaller.LaunchOutcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(report.headline,
                  systemImage: report.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(report.ok ? SysColor.green : SysColor.orange)

            Text(report.detail)
                .font(.system(size: 14))
                .foregroundStyle(SysColor.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SysColor.secondaryGrouped)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
        .transition(.opacity)
    }

    // MARK: - Tweaks

    /// What dyld will load into this app, right where the launch button is.
    ///
    /// The switches write the executable's load commands immediately, which is
    /// why they belong on the pre-launch screen: whatever is on here is what
    /// the next launch gets.
    private var tweaksCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tweaks")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(SysColor.label)
                Spacer()
                Text(tweakSummary)
                    .font(.system(size: 13))
                    .foregroundStyle(SysColor.secondaryLabel)
            }
            .padding(.bottom, 10)

            if tweaks.library.isEmpty {
                Text("No dylibs in the library. Settings → ★ Tweaks → Manage to add one.")
                    .font(.system(size: 13))
                    .foregroundStyle(SysColor.secondaryLabel)
            } else {
                ForEach(Array(tweaks.library.enumerated()), id: \.element.id) { index, tweak in
                    tweakRow(tweak, last: index == tweaks.library.count - 1)
                }

                if let tweakError {
                    Text(tweakError)
                        .font(.system(size: 12))
                        .foregroundStyle(SysColor.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }

                Text(installed
                     ? "Each switch writes an LC_LOAD_DYLIB command into this app's executable now; dyld loads it at the next launch."
                     : "Nothing is written until the app has a payload — download it and these come with it.")
                    .font(.system(size: 12))
                    .foregroundStyle(SysColor.secondaryLabel.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SysColor.secondaryGrouped)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
    }

    private var tweakSummary: String {
        let loading = tweaks.enabledCount(for: bundleIdentifier)
        return loading == 0 ? "None loading" : "\(loading) loading"
    }

    private func tweakRow(_ tweak: TweakStore.Tweak, last: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tweak.name)
                            .font(.system(size: 15))
                            .foregroundStyle(tweak.isLoadable ? SysColor.label : SysColor.orange)
                            .lineLimit(1)
                        if tweaks.isGlobal(tweak) {
                            TagPill(text: "GLOBAL", tint: SysColor.blue)
                        }
                    }
                    Text(tweakCaption(tweak))
                        .font(.system(size: 12))
                        .foregroundStyle(tweaks.reason(for: tweak, in: bundleIdentifier) == .blocked
                                         ? SysColor.orange : SysColor.secondaryLabel)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: tweakBinding(tweak))
                    .labelsHidden()
                    .tint(SysColor.green)
                    .disabled(!tweak.isLoadable)
            }
            .padding(.vertical, 8)

            if !last { Rectangle().fill(SysColor.separator).frame(height: 0.5) }
        }
    }

    private func tweakCaption(_ tweak: TweakStore.Tweak) -> String {
        guard tweak.isLoadable else { return tweak.detail }
        switch tweaks.reason(for: tweak, in: bundleIdentifier) {
        case .global: return "Loaded — global"
        case .app: return "Loaded — this app only"
        case .blocked: return "Blocked here, global elsewhere"
        case .off: return "Not loaded"
        }
    }

    private func tweakBinding(_ tweak: TweakStore.Tweak) -> Binding<Bool> {
        Binding(
            get: { tweaks.isEnabled(tweak, in: bundleIdentifier) },
            set: { isOn in
                Haptics.selection()
                do {
                    try tweaks.setEnabled(isOn, tweak: tweak, in: bundleIdentifier)
                    tweakError = nil
                } catch {
                    Haptics.tap(.rigid)
                    tweakError = error.localizedDescription
                }
            }
        )
    }

    // MARK: - Binary

    private var binaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Guest Binary")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(SysColor.label)
                .padding(.bottom, 10)

            if let info = binaryInfo {
                Line("Architecture", info.arch)
                Line("Platform", info.platform?.label ?? "unknown")
                Line("Dyld routing", HostPlatform.isSimulator
                     ? "iOS → Simulator"
                     : (JITLessSigner.isAvailableForLaunch ? "Native iOS · host-signed" : "Native iOS + JIT"))
                Line("LiveContainer",
                     info.isLoadableDylib ? "Executable patched" : "Not patched",
                     last: true)

                Text(info.isLoadableDylib
                     ? (HostPlatform.isSimulator
                        ? "The executable keeps its iOS platform. LiveContainer's simulator hook routes dyld/libSystem loading, then calls the guest's own entry point."
                        : (JITLessSigner.isAvailableForLaunch
                           ? "The executable keeps its native iOS platform. ZSign gives every Mach-O VibeContainers' signing identifier, so LiveContainer can load it without JIT."
                           : "The executable keeps its native iOS platform. LiveContainer's device bootstrap bypasses library validation in the JIT-enabled process, then calls the guest's own entry point."))
                     : "The executable has not yet been converted to LiveContainer's loadable-dylib form.")
                    .font(.system(size: 12))
                    .foregroundStyle(SysColor.secondaryLabel.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
        .padding(14)
        .background(SysColor.secondaryGrouped)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
    }

    // MARK: - Container

    private var containerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Data Container")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(SysColor.label)
                .padding(.bottom, 10)

            if let container {
                Line("Bundle ID", container.bundleIdentifier)
                Line("Container", String(container.uuid.uuidString.prefix(8)) + "…")
                Line("Payload", installed ? "Installed" : "Not downloaded")
                Line("Files", "\(usage.files)")
                Line("On disk", usage.sizeText, last: true)

                HStack(spacing: 10) {
                    Button {
                        Haptics.tap(.rigid)
                        containers.reset(bundleIdentifier)
                        refreshUsage()
                        refreshBinary()
                        report = nil
                    } label: {
                        actionLabel("Reset", tint: SysColor.red, fill: SysColor.red.opacity(0.15))
                    }
                    .buttonStyle(.plain)

                    Button {
                        Haptics.tap(.light)
                        if let onClose { onClose() } else { dismissApp() }
                    } label: {
                        actionLabel("Close", tint: SysColor.blue, fill: SysColor.fill)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 14)
            }
        }
        .padding(14)
        .background(SysColor.secondaryGrouped)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
    }

    private func actionLabel(_ title: String, tint: Color, fill: Color) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Capsule().fill(fill))
    }

    private func Line(_ label: String, _ value: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(SysColor.secondaryLabel)
                Spacer(minLength: 12)
                Text(value)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(SysColor.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, 8)
            if !last { Rectangle().fill(SysColor.separator).frame(height: 0.5) }
        }
    }

    // MARK: - Refresh

    private func syncTweaks() {
        do {
            try tweaks.sync(bundleIdentifier)
            tweakError = nil
        } catch {
            tweakError = error.localizedDescription
        }
    }

    private func refreshUsage() {
        guard let container else { return }
        usage = containers.usage(of: container)
    }

    private func refreshBinary() {
        guard let container,
              let appDir = GuestInstaller.dotApp(in: containers.url(for: container)
                .appendingPathComponent("Payload", isDirectory: true)),
              let binary = GuestInstaller.executable(in: appDir) else {
            binaryInfo = nil
            return
        }
        binaryInfo = MachO.inspect(binary)
    }
}
