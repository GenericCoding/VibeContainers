import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var booted = false
    /// The boot screen is faded out first and only unmounted afterwards, so
    /// the springboard is never inserted in the middle of the transition.
    @State private var bootScreenMounted = true
    /// Resolved once on appear — see `Metrics.readSafeArea()`.
    @State private var safeArea = Metrics.fallbackSafeArea

    @State private var controllers = ControllerHub.shared
    /// Set when the dashboard is left deliberately — the PS button at its root,
    /// its on-screen Exit control, or a "Return to iOS Home Screen" row.
    @State private var dismissedDashboard = false

    /// The Settings button explicitly turns this device into a console. A pad
    /// may drive the dashboard, but pairing one never changes the startup UI.
    /// The springboard stays mounted underneath, so leaving is a cross-fade.
    private var dashboardActive: Bool {
        booted && controllers.dashboardRequested && !dismissedDashboard
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                SpringboardView(active: booted)
                    .opacity(dashboardActive ? 0 : 1)
                    .allowsHitTesting(!dashboardActive)

                if dashboardActive {
                    XMBRootView(onExit: leaveDashboard)
                        .transition(.opacity)
                        .zIndex(2)
                }

                if bootScreenMounted {
                    BootScreen {
                        withAnimation(.easeOut(duration: 0.45)) { booted = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            bootScreenMounted = false
                        }
                    }
                    .opacity(booted ? 0 : 1)
                    .allowsHitTesting(!booted)
                    .zIndex(3)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onChange(of: geometry.size) { _, _ in
                // Scene bounds can change independently of device rotation on
                // iPadOS. Refresh the forwarded insets after layout settles.
                DispatchQueue.main.async { safeArea = Metrics.readSafeArea() }
            }
        }
        .ignoresSafeArea()
        // Give VibeContainers' in-app switcher the first upward drag while a
        // full-screen guest is hosted. A second swipe still reaches the real
        // iOS Home Screen, matching the system's deferred-edge behavior.
        .defersSystemGestures(on: .bottom)
        .environment(\.deviceSafeArea, safeArea)
        .animation(.easeInOut(duration: 0.45), value: dashboardActive)
        .onAppear {
            safeArea = Metrics.readSafeArea()
            controllers.restoreTouchOrientation()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                controllers.restoreTouchOrientation()
            }
        }
        .onChange(of: controllers.controllerUITestMode) { _, testing in
            // Every explicit Settings request re-arms a previously dismissed
            // dashboard.
            if testing { dismissedDashboard = false }
        }
    }

    private func leaveDashboard() {
        if controllers.controllerUITestMode {
            controllers.leaveControllerUITestMode()
        }
        dismissedDashboard = true
    }
}
