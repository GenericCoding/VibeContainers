import CoreHaptics
import Foundation
import GameController
import Observation
import SwiftUI
import UIKit

/// Everything the XMB can be told to do, named after the buttons that do it.
///
/// The dashboard never sees a `GCController`: it consumes this and nothing
/// else, which is what lets the same navigator be driven from a menu button in
/// a debug build without a pad plugged in.
enum XMBInput: Equatable {
    case up, down, left, right
    /// ✕ — confirm. Western PlayStation layout, which is what a PS4/PS5 pad
    /// reports as `buttonA`.
    case cross
    /// ○ — back.
    case circle
    /// △ — show the information panel for whatever is selected.
    case triangle
    /// □ — the item's secondary action (install, uninstall, refresh).
    case square
    /// Shoulder buttons jump a whole category at a time.
    case l1, r1
    /// OPTIONS / SHARE.
    case options, share
    /// The PS button.
    case home
}

/// A connected pad, described in the terms the Settings column shows.
struct GamePad: Identifiable, Equatable {
    enum Kind: Equatable {
        case dualSense          // PS5
        case dualSenseEdge      // PS5, pro
        case dualShock4         // PS4
        case extended           // anything else that reports an extended profile

        var title: String {
            switch self {
            case .dualSense: "DualSense Wireless Controller"
            case .dualSenseEdge: "DualSense Edge Wireless Controller"
            case .dualShock4: "DualShock 4 Wireless Controller"
            case .extended: "Extended Gamepad"
            }
        }

        var shortTitle: String {
            switch self {
            case .dualSense: "DualSense"
            case .dualSenseEdge: "DualSense Edge"
            case .dualShock4: "DualShock 4"
            case .extended: "Gamepad"
            }
        }

        /// PS4 and PS5 pads are the ones this dashboard is drawn for; anything
        /// else is driven through the same generic extended profile.
        var isPlayStation: Bool { self != .extended }

        var symbol: String {
            isPlayStation ? "playstation.logo" : "gamecontroller.fill"
        }
    }

    let id: Int
    let kind: Kind
    let vendorName: String
    let battery: Float?
    let charging: Bool
    let hasLightBar: Bool
    let hasHaptics: Bool
    /// PS5 pads report an adaptive-trigger profile; PS4 pads do not.
    let hasAdaptiveTriggers: Bool

    var batteryText: String {
        guard let battery else { return charging ? "Charging" : "—" }
        let percent = Int((battery * 100).rounded())
        return charging ? "\(percent)% · charging" : "\(percent)%"
    }
}

/// Finds PlayStation pads, keeps their lights and rumble in step with the
/// dashboard, and turns their buttons into `XMBInput`.
///
/// Detection is explicit rather than "anything with an extended profile":
/// `GCDualSenseGamepad` and `GCDualShockGamepad` are the concrete profile
/// classes iOS hands back for a PS5 and a PS4 pad, and the product category
/// string is checked alongside them so a pad that pairs before its profile is
/// fully described still lands in the right bucket.
///
/// Only one sink is installed at a time — the running `XMBNavigator`. The
/// hub deliberately does not buffer: a menu that is not on screen has no
/// business acting on a stick that was pushed while it was away.
@MainActor
@Observable
final class ControllerHub {
    static let shared = ControllerHub()

    private(set) var pads: [GamePad] = []
    /// A session-only virtual pad used to exercise the dashboard on a device
    /// or simulator without pairing controller hardware. It deliberately
    /// starts false on every launch so the XMB can never become a saved boot
    /// state.
    private(set) var controllerUITestMode: Bool
    /// True from the moment a pad is seen. The root view watches this.
    var isConnected: Bool { !pads.isEmpty }
    /// Entering the dashboard is always an explicit Settings action. Simulator
    /// can report a virtual `GCController` even with no physical pad attached,
    /// so connection discovery must never select the app's startup UI.
    /// Connected hardware still feeds input after Controller mode is opened.
    var dashboardRequested: Bool { controllerUITestMode }
    /// A PS4/PS5 pad specifically, which is what the dashboard is drawn for.
    var hasPlayStationPad: Bool { pads.contains { $0.kind.isPlayStation } }

    /// Set by whoever is currently accepting input.
    @ObservationIgnored var sink: ((XMBInput) -> Void)?
    /// The PS button is routed separately: it means "leave", and it has to
    /// work whatever else has claimed the sink.
    @ObservationIgnored var onHome: (() -> Void)?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var repeaters: [XMBInput: Task<Void, Never>] = [:]
    /// Latched stick direction per controller, so a held stick repeats like a
    /// held d-pad instead of firing once per analogue sample.
    @ObservationIgnored private var stickDirection: [Int: XMBInput?] = [:]
    @ObservationIgnored private var haptics: [Int: CHHapticEngine] = [:]

    /// How long a direction is held before it starts repeating, and how fast it
    /// repeats after that. Tuned to the XMB's own cadence: slow enough that a
    /// nudge moves one row, fast enough to cross a long column.
    private static let repeatDelay: Duration = .milliseconds(380)
    private static let repeatInterval: Duration = .milliseconds(105)
    private init() {
        controllerUITestMode = false
        // Remove the key written by builds that briefly persisted Controller
        // mode, so an old value cannot surprise a future implementation.
        UserDefaults.standard.removeObject(forKey: "controller.ui.testMode")

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect,
                                            object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let pad = note.object as? GCController else { return }
                self?.adopt(pad)
            }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect,
                                            object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let pad = note.object as? GCController else { return }
                self?.drop(pad)
            }
        })

        GCController.controllers().forEach(adopt)
        GCController.startWirelessControllerDiscovery()
    }

    // MARK: - Controller UI test mode

    /// Presents the same dashboard a connected controller would request, then
    /// asks the active scene to rotate into its widescreen test layout.
    func enterControllerUITestMode() {
        controllerUITestMode = true
        requestInterfaceOrientation(.landscape)
    }

    /// Test mode has its own on-screen Exit control, so it can always return to
    /// the touch UI even when no physical controller exists.
    func leaveControllerUITestMode() {
        controllerUITestMode = false
        requestInterfaceOrientation(.portrait)
    }

    /// Scene geometry can survive process termination in Simulator. Reassert
    /// portrait whenever the touch shell starts so a session killed in
    /// Controller mode cannot rotate the next launch.
    func restoreTouchOrientation() {
        guard !controllerUITestMode else { return }
        requestInterfaceOrientation(.portrait)
    }

    private func requestInterfaceOrientation(_ orientations: UIInterfaceOrientationMask) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first else { return }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
    }

    // MARK: - Connect / disconnect

    private func adopt(_ controller: GCController) {
        guard controller.extendedGamepad != nil else { return }
        bind(controller)
        paint(controller)
        prepareHaptics(controller)
        refreshPads()
    }

    private func drop(_ controller: GCController) {
        let key = Self.key(controller)
        stickDirection[key] = nil
        haptics[key]?.stop()
        haptics[key] = nil
        cancelAllRepeats()
        refreshPads()
    }

    private static func key(_ controller: GCController) -> Int {
        ObjectIdentifier(controller).hashValue
    }

    private func refreshPads() {
        pads = GCController.controllers().compactMap(Self.describe)
    }

    private static func describe(_ controller: GCController) -> GamePad? {
        guard controller.extendedGamepad != nil else { return nil }
        let battery = controller.battery
        return GamePad(
            id: key(controller),
            kind: kind(of: controller),
            vendorName: controller.vendorName ?? "Controller",
            battery: battery?.batteryLevel,
            charging: battery?.batteryState == .charging,
            hasLightBar: controller.light != nil,
            hasHaptics: controller.haptics != nil,
            hasAdaptiveTriggers: controller.physicalInputProfile is GCDualSenseGamepad
        )
    }

    /// The concrete profile class is the reliable signal; the product category
    /// is the fallback for the window between pairing and profile description.
    private static func kind(of controller: GCController) -> GamePad.Kind {
        let category = controller.productCategory
        if controller.physicalInputProfile is GCDualSenseGamepad {
            return category.localizedCaseInsensitiveContains("edge") ? .dualSenseEdge : .dualSense
        }
        if controller.physicalInputProfile is GCDualShockGamepad { return .dualShock4 }
        if category == GCProductCategoryDualSense { return .dualSense }
        if category == GCProductCategoryDualShock4 { return .dualShock4 }
        return .extended
    }

    // MARK: - Lights and rumble

    /// Puts the pad's light bar in the dashboard's own ice-cyan. PS4 and PS5
    /// pads both expose this; everything else quietly has no `light`.
    func paint(_ controller: GCController, color: Color = Palette.ice) {
        guard let light = controller.light else { return }
        let resolved = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        light.color = GCColor(red: Float(r), green: Float(g), blue: Float(b))
    }

    func paintAll(_ color: Color) {
        GCController.controllers().forEach { paint($0, color: color) }
    }

    private func prepareHaptics(_ controller: GCController) {
        guard let engine = controller.haptics?.createEngine(withLocality: .default) else { return }
        engine.isAutoShutdownEnabled = true
        try? engine.start()
        haptics[Self.key(controller)] = engine
    }

    /// A short tap through the pad, used the way the springboard uses `Haptics`.
    func rumble(intensity: Float = 0.6, sharpness: Float = 0.5, duration: TimeInterval = 0.08) {
        for (_, engine) in haptics {
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                ],
                relativeTime: 0,
                duration: duration
            )
            guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
                  let player = try? engine.makePlayer(with: pattern) else { continue }
            try? engine.start()
            try? player.start(atTime: CHHapticTimeImmediate)
        }
    }

    // MARK: - Binding

    private func bind(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        // Handlers arrive on this queue; everything below touches main-actor
        // state, so it must be the main queue.
        controller.handlerQueue = .main

        pad.dpad.up.pressedChangedHandler = press(.up)
        pad.dpad.down.pressedChangedHandler = press(.down)
        pad.dpad.left.pressedChangedHandler = press(.left)
        pad.dpad.right.pressedChangedHandler = press(.right)

        // Western PlayStation mapping: buttonA is ✕, buttonB is ○, buttonX is
        // □, buttonY is △. GameController normalises PS pads onto these names.
        pad.buttonA.pressedChangedHandler = tap(.cross)
        pad.buttonB.pressedChangedHandler = tap(.circle)
        pad.buttonX.pressedChangedHandler = tap(.square)
        pad.buttonY.pressedChangedHandler = tap(.triangle)

        pad.leftShoulder.pressedChangedHandler = press(.l1)
        pad.rightShoulder.pressedChangedHandler = press(.r1)
        pad.buttonMenu.pressedChangedHandler = tap(.options)
        pad.buttonOptions?.pressedChangedHandler = tap(.share)

        // The PS button. iOS only forwards it when the app has opted out of
        // system controller UI — see `GCSupportsControllerUserInteraction` in
        // Info.plist. Without that key set to NO the press is swallowed by the
        // system overlay and this handler never runs.
        pad.buttonHome?.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated {
                guard pressed else { return }
                self?.onHome?()
            }
        }

        let key = Self.key(controller)
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.stickMoved(key: key, x: x, y: y) }
        }
    }

    /// A direction or shoulder: fires immediately, then repeats while held.
    private func press(_ input: XMBInput) -> GCControllerButtonValueChangedHandler {
        { [weak self] _, _, pressed in
            MainActor.assumeIsolated {
                guard let self else { return }
                if pressed { self.beginRepeating(input) } else { self.endRepeating(input) }
            }
        }
    }

    /// A face button: one event per press, no repeat.
    private func tap(_ input: XMBInput) -> GCControllerButtonValueChangedHandler {
        { [weak self] _, _, pressed in
            MainActor.assumeIsolated {
                guard pressed else { return }
                self?.sink?(input)
            }
        }
    }

    // MARK: - Stick

    /// Turns a continuous stick into the same discrete, repeating events the
    /// d-pad produces. The outer threshold arms a direction and the inner one
    /// disarms it, so a stick resting near the edge cannot chatter.
    private func stickMoved(key: Int, x: Float, y: Float) {
        let armed: XMBInput?
        if abs(x) > abs(y) {
            armed = abs(x) > 0.6 ? (x > 0 ? .right : .left) : nil
        } else {
            armed = abs(y) > 0.6 ? (y > 0 ? .up : .down) : nil
        }

        let current = stickDirection[key] ?? nil
        // Still inside the release band with nothing new armed: hold what we
        // have rather than dropping it on a single noisy sample.
        if armed == nil && max(abs(x), abs(y)) > 0.35 { return }
        guard armed != current else { return }

        if let current { endRepeating(current) }
        stickDirection[key] = armed
        if let armed { beginRepeating(armed) }
    }

    // MARK: - Auto-repeat

    private func beginRepeating(_ input: XMBInput) {
        repeaters[input]?.cancel()
        sink?(input)

        // Shoulders step one category per press; only the directions repeat.
        guard [.up, .down, .left, .right].contains(input) else { return }

        repeaters[input] = Task { [weak self] in
            try? await Task.sleep(for: Self.repeatDelay)
            while !Task.isCancelled {
                guard let self else { return }
                self.sink?(input)
                try? await Task.sleep(for: Self.repeatInterval)
            }
        }
    }

    private func endRepeating(_ input: XMBInput) {
        repeaters[input]?.cancel()
        repeaters[input] = nil
    }

    private func cancelAllRepeats() {
        repeaters.values.forEach { $0.cancel() }
        repeaters.removeAll()
    }
}
