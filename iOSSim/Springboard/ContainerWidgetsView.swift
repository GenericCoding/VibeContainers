import SwiftUI
import UIKit
import Darwin

@_silgen_name("IOSSimCreateContainerWidgetHost")
private func IOSSimCreateContainerWidgetHost(
    _ extensionBundleIdentifier: UnsafePointer<CChar>,
    _ containerBundleIdentifier: UnsafePointer<CChar>,
    _ widgetKind: UnsafePointer<CChar>,
    _ extensionPath: UnsafePointer<CChar>,
    _ family: Int64,
    _ width: Double,
    _ height: Double
) -> UnsafeMutableRawPointer?

@_silgen_name("IOSSimInvalidateContainerWidgetHost")
private func IOSSimInvalidateContainerWidgetHost(_ pointer: UnsafeMutableRawPointer)

@_silgen_name("IOSSimCopyContainerWidgetHostError")
private func IOSSimCopyContainerWidgetHostError() -> UnsafeMutablePointer<CChar>?

private let widgetStatusNotification = Notification.Name("IOSSimContainerWidgetHostStatus")
private let widgetLaunchNotification = Notification.Name("IOSSimContainerWidgetRequestedLaunch")

private enum ContainerWidgetHostPhase: Equatable {
    case preparing
    case loading
    case ready
    case failed(String)
}

/// `UIViewControllerRepresentable` does not recreate its controller when its
/// input values change. Make the inputs the private host actually bakes into
/// its controller explicit so rotation, column changes, and kind edits cannot
/// leave a live surface rendering with stale geometry or configuration.
private struct ContainerWidgetHostIdentity: Hashable {
    let requestIdentifier: String
    let retryID: UUID
    let kind: String
    let family: Int64
    let size: CGSize
}

/// Container widget discovery and actual Chrono/WidgetRenderer hosting.
struct ContainerWidgetsSection: View {
    var onLaunch: (String) -> Void

    @State private var widgets = ContainerWidgetStore.shared
    @State private var packages = PackageStore.shared
    @State private var installer = GuestInstaller.shared
    @State private var managing = false
    @State private var editing = false

    private var readyBundles: Set<String> {
        Set(installer.phases.compactMap { bundle, phase in
            phase == .ready ? bundle : nil
        })
    }

    private var sideloadedBundle: String? {
        if case .installed(let bundle) = installer.sideload { return bundle }
        return nil
    }

    var body: some View {
        Group {
            if !widgets.enabled.isEmpty || !widgets.discovered.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Widgets")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(SysColor.label)

                        Spacer()

                        if !widgets.enabled.isEmpty {
                            Button(editing ? "Done" : "Edit", action: toggleEditing)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(SysColor.blue)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                                .buttonStyle(.plain)
                                .accessibilityHint("Shows controls for removing widgets from the News feed")
                        }

                        Button {
                            Haptics.tap(.light)
                            managing = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(SysColor.label)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(.ultraThinMaterial))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Manage container widgets")
                    }

                    if widgets.enabled.isEmpty {
                        Button {
                            Haptics.tap(.light)
                            managing = true
                        } label: {
                            Label("Add a container widget", systemImage: "rectangle.stack.badge.plus")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(SysColor.label)
                                .frame(maxWidth: .infinity, minHeight: 86)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    } else {
                        ForEach(widgets.enabled) { widget in
                            ZStack(alignment: .topLeading) {
                                ContainerWidgetSurface(
                                    widget: widget,
                                    rendererInstanceIdentifier: "today.\(widget.id)"
                                ) {
                                    Haptics.tap(.light)
                                    onLaunch(widget.ownerBundleIdentifier)
                                }
                                .allowsHitTesting(!editing)

                                if editing {
                                    Button(
                                        "Remove \(widget.appName) from News Feed",
                                        systemImage: "minus.circle.fill"
                                    ) {
                                        removeFromNewsFeed(widget)
                                    }
                                    .labelStyle(.iconOnly)
                                    .font(.system(size: 27, weight: .semibold))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, SysColor.red)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(.ultraThinMaterial).frame(width: 31, height: 31))
                                    .contentShape(Circle())
                                    .buttonStyle(.plain)
                                    .accessibilityHint("Keeps this widget on Home Screen pages")
                                    .offset(x: -8, y: -8)
                                    .zIndex(1)
                                }
                            }
                            .accessibilityAction(named: "Remove from News Feed") {
                                removeFromNewsFeed(widget)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $managing) {
            ContainerWidgetGallery()
        }
        .onAppear { widgets.refresh() }
        .onChange(of: packages.installedList.map(\.bundleIdentifier)) { _, _ in
            widgets.refresh()
        }
        .onChange(of: readyBundles) { _, _ in widgets.refresh() }
        .onChange(of: sideloadedBundle) { _, _ in widgets.refresh() }
    }

    private func toggleEditing() {
        Haptics.tap(.light)
        editing.toggle()
    }

    private func removeFromNewsFeed(_ widget: ContainerWidgetStore.Descriptor) {
        Haptics.tap(.rigid)
        if widgets.enabled.count == 1 {
            editing = false
        }
        widgets.setEnabled(false, for: widget)
    }
}

struct ContainerWidgetSurface: View {
    let widget: ContainerWidgetStore.Descriptor
    /// A placement-scoped identity, not merely the widget descriptor. Two
    /// copies of the same WidgetKit kind must own independent render sessions,
    /// crash fuses, geometry and timelines.
    var rendererInstanceIdentifier: String? = nil
    var family: Int64 = 1
    var contentHeight: CGFloat = 158
    var showsAppName = true
    var cornerRadius: CGFloat = 22
    var onOpen: () -> Void

    @State private var widgets = ContainerWidgetStore.shared
    @State private var runtimeRenderer = ContainerWidgetRuntimeRenderer.shared
    @State private var phase: ContainerWidgetHostPhase = .preparing
    @State private var compatibleSession: ContainerWidgetCompatibleSession?
    @State private var prepared = false
    @State private var needsSigning = false
    @State private var signOnNextAttempt = false
    @State private var attemptedAutomaticSigning = false
    @State private var retryID = UUID()

    private var runtimeRequestIdentifier: String {
        rendererInstanceIdentifier ?? "descriptor.\(widget.id)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let kind = widgets.selectedKind(for: widget)
                // Geometry can move by subpixels during page animations. A
                // pixel-stable identity prevents those harmless changes from
                // restaging and reinvoking guest widget code.
                let hostSize = CGSize(
                    width: max(1, proxy.size.width.rounded()),
                    height: max(1, contentHeight.rounded())
                )
                let hostIdentity = ContainerWidgetHostIdentity(
                    requestIdentifier: runtimeRequestIdentifier,
                    retryID: retryID,
                    kind: kind,
                    family: family,
                    size: hostSize
                )

                ZStack {
                    if let compatibleSession {
                        ContainerWidgetCompatibleHostView(session: compatibleSession)
                            .id(compatibleSession.id)
                    } else if prepared {
                        ContainerWidgetHostRepresentable(
                            widget: widget,
                            kind: kind,
                            family: family,
                            size: hostSize,
                            phase: $phase,
                            onOpen: onOpen
                        )
                        .id(hostIdentity)
                    }

                    switch phase {
                    case .preparing:
                        widgetPlaceholder {
                            ProgressView().controlSize(.small)
                            Text(signOnNextAttempt ? "Signing widget…" : "Checking widget…")
                        }
                    case .loading:
                        widgetPlaceholder {
                            ProgressView().controlSize(.small)
                            Text("Loading live widget…")
                        }
                    case .ready:
                        EmptyView()
                    case .failed(let message):
                        widgetFailure(message)
                    }
                }
                .frame(width: proxy.size.width, height: contentHeight)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Palette.paper.opacity(0.12), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topTrailing) {
                    if compatibleSession == nil,
                       phase != .ready,
                       let report = runtimeRenderer.report(for: runtimeRequestIdentifier) {
                        ContainerWidgetRuntimeStatusView(report: report)
                            .padding(8)
                    }
                }
                .task(id: hostIdentity) {
                    await prepareWidget(hostSize: hostSize, kind: kind)
                }
            }
            .frame(height: contentHeight)

            if showsAppName {
                Text(widget.appName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SysColor.secondaryLabel)
                    .padding(.leading, 4)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live \(widget.extensionName) widget from \(widget.appName)")
    }

    @MainActor
    private func prepareWidget(hostSize: CGSize, kind: String) async {
        let shouldSign = signOnNextAttempt
        compatibleSession = nil
        prepared = false
        needsSigning = false
        phase = .preparing
        var compatibleFailureMessage: String?

        let app = URL(fileURLWithPath: widget.containerBundlePath, isDirectory: true)
        let appex = URL(fileURLWithPath: widget.extensionBundlePath, isDirectory: true)
        if runtimeRenderer.shouldAttemptCompatibleRender(for: runtimeRequestIdentifier) {
            do {
                let module = try await JITLessSigner.prepareWidgetRuntimeModule(
                    appBundle: app,
                    extensionBundle: appex
                )
                try Task.checkCancellation()
                if !runtimeRenderer.reuseCapturedBundleIfAvailable(
                    requestIdentifier: runtimeRequestIdentifier,
                    extensionBundleIdentifier: widget.extensionBundleIdentifier,
                    executablePath: module.executablePath
                ) {
                    try JITLessSigner.captureWidgetRuntimeModule(
                        module,
                        requestIdentifier: runtimeRequestIdentifier,
                        extensionBundleIdentifier: widget.extensionBundleIdentifier
                    )
                }
                guard let bundle = runtimeRenderer.capturedBundle(
                    for: runtimeRequestIdentifier
                ) else {
                    throw ContainerWidgetCompatibleRenderer.Failure(
                        stage: .capture,
                        code: "captured_bundle_missing",
                        message: "WidgetBundle.main returned without a compatible bundle capture.",
                        recoverable: true
                    )
                }
                let session = try await bundle.render(
                    requestedKind: kind,
                    familyRawValue: family,
                    displaySize: hostSize,
                    requestIdentifier: runtimeRequestIdentifier,
                    extensionBundleIdentifier: widget.extensionBundleIdentifier,
                    executablePath: module.executablePath
                )
                try Task.checkCancellation()
                compatibleSession = session
                signOnNextAttempt = false
                phase = .ready
                NSLog(
                    "[WidgetRuntime] Rendered %@ kind=%@ family=%lld snapshot=%@ size=%.0fx%.0f.",
                    widget.extensionBundleIdentifier,
                    session.kind,
                    family,
                    session.usedSnapshot ? "yes" : "placeholder",
                    hostSize.width,
                    hostSize.height
                )
                return
            } catch is CancellationError {
                return
            } catch let failure as ContainerWidgetCompatibleRenderer.Failure {
                runtimeRenderer.fail(
                    requestIdentifier: runtimeRequestIdentifier,
                    extensionBundleIdentifier: widget.extensionBundleIdentifier,
                    executablePath: widget.extensionBundlePath,
                    stage: failure.stage,
                    code: failure.code,
                    message: failure.message,
                    recoverable: failure.recoverable
                )
                compatibleFailureMessage = failure.message
            } catch {
                runtimeRenderer.fail(
                    requestIdentifier: runtimeRequestIdentifier,
                    extensionBundleIdentifier: widget.extensionBundleIdentifier,
                    executablePath: widget.extensionBundlePath,
                    stage: .loader,
                    code: "compatible_loader_failed",
                    message: error.localizedDescription,
                    recoverable: true
                )
                compatibleFailureMessage = error.localizedDescription
            }
        }

        // On supported devices, a compatible-render failure is the useful
        // result. Do not immediately obscure it by repeatedly staging the old
        // PlugInKit runner, which LaunchServices cannot register from inside a
        // container app. Crash-fused requests remain eligible for that legacy
        // fallback on a later launch.
        if let compatibleFailureMessage {
            phase = .failed(compatibleFailureMessage)
            return
        }
        if runtimeRenderer.isEnabled,
           let report = runtimeRenderer.report(for: runtimeRequestIdentifier),
           report.outcome == .failed,
           let failure = report.failure,
           failure.stage != .recovery {
            phase = .failed(failure.message)
            return
        }

        // The private system host remains the precise fallback for unsupported
        // configuration sources, ABI-gate failures, and crash-fused guests.
        do {
            if shouldSign {
                try await JITLessSigner.prepareWidgetForHosting(
                    appBundle: app,
                    extensionBundle: appex
                )
            } else {
                try await JITLessSigner.preflightWidgetForHosting(
                    appBundle: app,
                    extensionBundle: appex
                )
            }
            try Task.checkCancellation()
            signOnNextAttempt = false
            phase = .loading
            prepared = true
        } catch is CancellationError {
            return
        } catch let error as JITLessSigner.WidgetSigningRequired {
            if !attemptedAutomaticSigning {
                attemptedAutomaticSigning = true
                signOnNextAttempt = true
                phase = .preparing
                retryID = UUID()
                return
            }
            needsSigning = true
            phase = .failed(error.localizedDescription)
        } catch {
            needsSigning = shouldSign
            phase = .failed(error.localizedDescription)
        }
    }

    @ViewBuilder
    private func widgetPlaceholder<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            HStack(spacing: 9) { content() }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SysColor.secondaryLabel)
        }
    }

    private func widgetFailure(_ message: String) -> some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    PackageIcon(url: widget.iconURL, tint: nil, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(widget.extensionName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(SysColor.label)
                            .lineLimit(1)
                        Text(message)
                            .font(.system(size: 10.5))
                            .foregroundStyle(SysColor.secondaryLabel)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    Button(needsSigning ? "Sign & Retry" : "Retry") {
                        runtimeRenderer.retryCompatibleRender(
                            for: runtimeRequestIdentifier
                        )
                        signOnNextAttempt = needsSigning
                        compatibleSession = nil
                        prepared = false
                        phase = .preparing
                        retryID = UUID()
                    }
                    .buttonStyle(.bordered)

                    Button("Open App", action: onOpen)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(13)
        }
    }
}

private struct ContainerWidgetHostRepresentable: UIViewControllerRepresentable {
    let widget: ContainerWidgetStore.Descriptor
    let kind: String
    let family: Int64
    let size: CGSize
    @Binding var phase: ContainerWidgetHostPhase
    var onOpen: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(phase: $phase, onOpen: onOpen)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let pointer = widget.extensionBundleIdentifier.withCString { extensionID in
            widget.ownerBundleIdentifier.withCString { ownerID in
                kind.withCString { kindBytes in
                    widget.extensionBundlePath.withCString { pathBytes in
                        IOSSimCreateContainerWidgetHost(
                            extensionID, ownerID, kindBytes, pathBytes,
                            family, size.width, size.height
                        )
                    }
                }
            }
        }

        guard let pointer else {
            let message: String
            if let error = IOSSimCopyContainerWidgetHostError() {
                message = String(cString: error)
                free(error)
            } else {
                message = "Private WidgetRenderer host unavailable"
            }
            DispatchQueue.main.async { phase = .failed(message) }
            return UIViewController()
        }

        let controller = Unmanaged<UIViewController>
            .fromOpaque(pointer)
            .takeRetainedValue()
        context.coordinator.start(controller: controller)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.onOpen = onOpen
    }

    static func dismantleUIViewController(
        _ uiViewController: UIViewController,
        coordinator: Coordinator
    ) {
        coordinator.stop()
        IOSSimInvalidateContainerWidgetHost(
            Unmanaged.passUnretained(uiViewController).toOpaque()
        )
    }

    final class Coordinator {
        private var statusObserver: NSObjectProtocol?
        private var launchObserver: NSObjectProtocol?
        private var phase: Binding<ContainerWidgetHostPhase>
        var onOpen: () -> Void

        init(phase: Binding<ContainerWidgetHostPhase>, onOpen: @escaping () -> Void) {
            self.phase = phase
            self.onOpen = onOpen
        }

        func start(controller: UIViewController) {
            statusObserver = NotificationCenter.default.addObserver(
                forName: widgetStatusNotification,
                object: controller,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                if notification.userInfo?["phase"] as? String == "ready" {
                    self.phase.wrappedValue = .ready
                } else {
                    let message = notification.userInfo?["message"] as? String
                        ?? "WidgetRenderer could not load this widget"
                    self.phase.wrappedValue = .failed(message)
                }
            }
            launchObserver = NotificationCenter.default.addObserver(
                forName: widgetLaunchNotification,
                object: controller,
                queue: .main
            ) { [weak self] _ in
                self?.onOpen()
            }
        }

        func stop() {
            if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
            if let launchObserver { NotificationCenter.default.removeObserver(launchObserver) }
            statusObserver = nil
            launchObserver = nil
        }

        deinit { stop() }
    }
}

struct ContainerWidgetGallery: View {
    var preferredPage = 0
    var onPlaced: (HomeItem) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var widgets = ContainerWidgetStore.shared
    @State private var layout = HomeLayoutStore.shared

    private var appearance: Appearance { Appearance.shared }

    var body: some View {
        NavigationStack {
            Group {
                if widgets.discovered.isEmpty {
                    ContentUnavailableView(
                        "No Container Widgets",
                        systemImage: "rectangle.stack",
                        description: Text("Install an app whose payload includes a WidgetKit extension, then return here.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(widgets.discovered) { widget in
                                VStack(alignment: .leading, spacing: 11) {
                                    HStack(spacing: 12) {
                                        PackageIcon(url: widget.iconURL, tint: nil, size: 42)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(widget.extensionName)
                                                .foregroundStyle(SysColor.label)
                                            Text("\(widget.appName) · \(widget.kindLabel)")
                                                .font(.caption)
                                                .foregroundStyle(SysColor.secondaryLabel)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 8)
                                        let count = layout.placedWidgetCount(descriptorID: widget.id)
                                        if count > 0 {
                                            Text("\(count) added")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(SysColor.blue)
                                        }
                                    }

                                    HStack(spacing: 8) {
                                        TextField(
                                            "Widget kind",
                                            text: Binding(
                                                get: { widgets.selectedKind(for: widget) },
                                                set: { widgets.setKind($0, for: widget) }
                                            )
                                        )
                                        .font(.caption.monospaced())
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()

                                        if !widget.candidateKinds.isEmpty {
                                            Menu {
                                                ForEach(widget.candidateKinds, id: \.self) { kind in
                                                    Button(kind) { widgets.setKind(kind, for: widget) }
                                                }
                                            } label: {
                                                Image(systemName: "chevron.up.chevron.down")
                                                    .font(.caption)
                                            }
                                        }
                                    }
                                    .padding(.leading, 54)
                                    .accessibilityLabel("Widget configuration kind")

                                    HStack(spacing: 10) {
                                        addButton(widget, size: .small)
                                        addButton(widget, size: .medium)
                                        addButton(widget, size: .large)
                                    }
                                    .padding(.leading, 54)
                                }
                            }
                        } header: {
                            Text("Installed Apps")
                        } footer: {
                            Text("Choose a size to place the live widget in the first open region on this Home Screen page. In edit mode you can drag, resize, or remove it just like an app icon.")
                        }
                    }
                }
            }
            .navigationTitle("Add Widgets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            widgets.refresh()
            layout.normalize(columns: appearance.columns)
        }
        .presentationDetents([.medium, .large])
    }

    private func addButton(
        _ widget: ContainerWidgetStore.Descriptor,
        size: HomeLayoutStore.WidgetSize
    ) -> some View {
        Button {
            let page = min(max(0, preferredPage), max(0, layout.pages.count - 1))
            guard let item = layout.addWidget(
                descriptorID: widget.id,
                size: size,
                preferring: page,
                columns: appearance.columns
            ) else { return }
            widgets.setEnabled(true, for: widget)
            Haptics.tap(.medium)
            onPlaced(item)
            dismiss()
        } label: {
            Label(size.title, systemImage: size == .small ? "square" : "rectangle")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}
