import Foundation
import Observation
import SwiftUI
import UIKit

@_silgen_name("IOSSimFocusMultitaskGuest")
private func IOSSimFocusMultitaskGuest(_ dataUUID: UnsafePointer<CChar>) -> Int32

@_silgen_name("IOSSimTerminateMultitaskGuest")
private func IOSSimTerminateMultitaskGuest(_ dataUUID: UnsafePointer<CChar>) -> Int32

@_silgen_name("IOSSimPresentMultitaskSwitcher")
private func IOSSimPresentMultitaskSwitcher() -> Int32

/// The host-side view of LiveContainer's independently running guest scenes.
///
/// LiveContainer remains the source of truth for the actual UIKit scenes. This
/// store only keeps enough identity and lifecycle state to render an app
/// switcher, then routes focus and termination back through the runtime bridge.
/// Keeping the launch-in-progress state here also prevents a fast second tap
/// from opening the same container (and its persistent stores) twice.
@MainActor
@Observable
final class RunningContainerStore: NSObject {
    static let shared = RunningContainerStore()

    enum Phase: Equatable {
        case launching
        case running(pid: Int32?)
        case failed(String)
        case terminated

        var isActive: Bool {
            switch self {
            case .launching, .running: true
            case .failed, .terminated: false
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        var id: String { dataUUID }
        let bundleIdentifier: String
        let dataUUID: String
        var displayName: String
        var phase: Phase
        var lastFocused: Date
    }

    private(set) var entries: [Entry] = []
    private(set) var isSwitcherPresented = false
    private(set) var previews: [String: UIImage] = [:]
    /// Detached UIKit replicas of remote scene surfaces. These remain views,
    /// rather than being rasterized, because an FBScene's cross-process layer
    /// is not guaranteed to participate in `drawHierarchy` or `layer.render`.
    private(set) var previewViews: [String: UIView] = [:]
    /// A successful terminate request is not the same as a disconnected
    /// scene. Hide accepted cards immediately, but keep their lifecycle entry
    /// until LiveContainer posts the authoritative close notification.
    private var terminatingEntryIDs: Set<String> = []

    var activeEntries: [Entry] {
        entries
            .filter { $0.phase.isActive && !terminatingEntryIDs.contains($0.dataUUID) }
            .sorted { $0.lastFocused > $1.lastFocused }
    }

    var visibleEntries: [Entry] {
        entries
            .filter { !terminatingEntryIDs.contains($0.dataUUID) }
            .sorted {
                if $0.phase.isActive != $1.phase.isActive { return $0.phase.isActive }
                return $0.lastFocused > $1.lastFocused
            }
    }

    var activeCount: Int { activeEntries.count }

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(guestDidOpen(_:)),
            name: .iOSSimMultitaskGuestDidOpen,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(guestDidBecomeReady(_:)),
            name: .iOSSimMultitaskGuestDidBecomeReady,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(guestDidFail(_:)),
            name: .iOSSimMultitaskGuestDidFail,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(guestDidClose(_:)),
            name: .iOSSimMultitaskGuestDidClose,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(showSwitcher(_:)),
            name: .iOSSimShowContainerSwitcher,
            object: nil
        )
    }

    func entry(for dataUUID: String) -> Entry? {
        entries.first { $0.dataUUID == dataUUID }
    }

    func preview(for dataUUID: String) -> UIImage? {
        previews[dataUUID]
    }

    func previewView(for dataUUID: String) -> UIView? {
        previewViews[dataUUID]
    }

    /// Returns false while this exact data container already has a live or
    /// pending scene, allowing callers to coalesce rapid duplicate launches.
    @discardableResult
    func beginLaunch(
        bundleIdentifier: String,
        dataUUID: String,
        displayName: String
    ) -> Bool {
        if let existing = entry(for: dataUUID), existing.phase.isActive {
            return false
        }

        upsert(
            bundleIdentifier: bundleIdentifier,
            dataUUID: dataUUID,
            displayName: displayName,
            phase: .launching
        )
        return true
    }

    func markLaunchFailed(dataUUID: String, message: String) {
        setPhase(.failed(message), for: dataUUID)
    }

    @discardableResult
    func focus(_ entry: Entry) -> Bool {
        focusResult(entry) == 0
    }

    /// Returns the runtime errno for diagnostics and process-wide routes while
    /// preserving the exact bookkeeping performed by the interactive card.
    @discardableResult
    func focusResult(_ entry: Entry) -> Int32 {
        // A card selection always closes the host overlay. Keeping it mounted
        // while UIKit raises a remote surface can leave an invisible SwiftUI
        // layer intercepting the next touch if scene activation wins the race.
        dismissSwitcher()

        // The launch request already exists but no scene is guaranteed to be
        // registered yet. Treat this tap as consumed instead of asking SwiftUI
        // to open a second window for the same data UUID.
        if case .launching = entry.phase {
            return 0
        }

        let result = entry.dataUUID.withCString(IOSSimFocusMultitaskGuest)
        guard result == 0 else {
            // ENOENT means the runtime no longer owns the scene. Treat the
            // registry row as stale so a subsequent tap may launch it again.
            if result == ENOENT { markTerminated(dataUUID: entry.dataUUID) }
            return result
        }

        if let index = index(for: entry.dataUUID) {
            entries[index].lastFocused = Date()
            if case .launching = entries[index].phase {
                // Keep the more precise pending state until the PID callback.
            } else {
                let pid: Int32?
                if case .running(let currentPID) = entries[index].phase {
                    pid = currentPID
                } else {
                    pid = nil
                }
                entries[index].phase = .running(pid: pid)
            }
        }
        return 0
    }

    @discardableResult
    func terminate(_ entry: Entry) -> Bool {
        if terminatingEntryIDs.contains(entry.dataUUID) { return true }

        let result = entry.dataUUID.withCString(IOSSimTerminateMultitaskGuest)
        if result == 0 {
            // The runtime only accepted the destruction request. Keep the
            // entry active until its scene actually disconnects and posts the
            // close notification.
            beginTermination(of: entry.dataUUID)
            return true
        }
        if result == ENOENT {
            markTerminated(dataUUID: entry.dataUUID)
            return true
        }
        return false
    }

    func presentSwitcher() {
        guard visibleEntries.contains(where: { entry in
            if case .terminated = entry.phase { return false }
            return true
        }) else { return }
        isSwitcherPresented = true
    }

    /// Asks LiveContainer to capture the visible guest before presenting.
    /// Returns false when the runtime bridge is unavailable so the host can
    /// still show its lifecycle cards without image previews.
    @discardableResult
    func presentCapturedSwitcher() -> Bool {
        guard IOSSimPresentMultitaskSwitcher() == 0 else { return false }
        return true
    }

    func dismissSwitcher() {
        isSwitcherPresented = false
    }

    // MARK: - Runtime lifecycle

    @objc private func guestDidOpen(_ notification: Notification) {
        guard let dataUUID = notification.userInfo?["dataUUID"] as? String else { return }
        let displayName = notification.userInfo?["displayName"] as? String ?? "Container"
        let bundleIdentifier = notification.userInfo?["bundleIdentifier"] as? String
            ?? entries.first(where: { $0.dataUUID == dataUUID })?.bundleIdentifier
            ?? dataUUID

        if entry(for: dataUUID) == nil {
            upsert(
                bundleIdentifier: bundleIdentifier,
                dataUUID: dataUUID,
                displayName: displayName,
                phase: .launching
            )
        }
    }

    @objc private func guestDidBecomeReady(_ notification: Notification) {
        guard let dataUUID = notification.userInfo?["dataUUID"] as? String else { return }
        let number = notification.userInfo?["pid"] as? NSNumber
        setPhase(.running(pid: number?.int32Value), for: dataUUID)
    }

    @objc private func guestDidFail(_ notification: Notification) {
        guard let dataUUID = notification.userInfo?["dataUUID"] as? String else { return }
        let message = notification.userInfo?["message"] as? String
            ?? "The container process ended before its scene became ready."
        markLaunchFailed(dataUUID: dataUUID, message: message)
    }

    @objc private func guestDidClose(_ notification: Notification) {
        guard let dataUUID = notification.userInfo?["dataUUID"] as? String else { return }
        terminatingEntryIDs.remove(dataUUID)
        previews.removeValue(forKey: dataUUID)
        previewViews.removeValue(forKey: dataUUID)
        // Initialization failures deliberately remain as retryable cards even
        // after their dead UIKit scene has been cleaned up. A swipe-to-close
        // still removes one because `terminate` resolves ENOENT explicitly.
        if case .failed = entry(for: dataUUID)?.phase { return }
        markTerminated(dataUUID: dataUUID)
    }

    @objc private func showSwitcher(_ notification: Notification) {
        if let capturedPreviews = notification.userInfo?["previews"] as? [String: UIImage] {
            // LiveContainer publishes its complete verified cache. Replacing
            // instead of merging is significant for protected content: an ID
            // deliberately omitted from the newest capture must not retain an
            // older bitmap in the host.
            previews = capturedPreviews
        }
        if let capturedPreviewViews = notification.userInfo?["previewViews"] as? [String: UIView] {
            // A bitmap is the preferred, detached representation. Do not keep
            // its older render-server UIView alive as an unused remote surface.
            previewViews = capturedPreviewViews.filter { previews[$0.key] == nil }
        }
        let animated = notification.userInfo?["animated"] as? Bool ?? true
        if animated {
            // Requests originating inside a hosted guest do not pass through
            // the Springboard gesture's transaction. Give that route the same
            // stable, critically damped presentation.
            withAnimation(
                Appearance.shared.animation(.spring(response: 0.28, dampingFraction: 0.94))
            ) {
                presentSwitcher()
            }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                // The visible close route has already hidden the guest surface;
                // inserting the overlay in this same non-animated turn prevents
                // the home screen from becoming an intermediate destination.
                presentSwitcher()
            }
        }
    }

    private func upsert(
        bundleIdentifier: String,
        dataUUID: String,
        displayName: String,
        phase: Phase
    ) {
        if let index = index(for: dataUUID) {
            entries[index].displayName = displayName
            entries[index].phase = phase
            entries[index].lastFocused = Date()
        } else {
            entries.append(
                Entry(
                    bundleIdentifier: bundleIdentifier,
                    dataUUID: dataUUID,
                    displayName: displayName,
                    phase: phase,
                    lastFocused: Date()
                )
            )
        }
    }

    private func setPhase(_ phase: Phase, for dataUUID: String) {
        guard let index = index(for: dataUUID) else { return }
        entries[index].phase = phase
    }

    private func markTerminated(dataUUID: String) {
        terminatingEntryIDs.remove(dataUUID)
        previews.removeValue(forKey: dataUUID)
        previewViews.removeValue(forKey: dataUUID)
        setPhase(.terminated, for: dataUUID)
        removeLaterIfInactive(dataUUID)
    }

    private func beginTermination(of dataUUID: String) {
        terminatingEntryIDs.insert(dataUUID)

        // AppSceneViewController gives a cooperative guest three seconds
        // before its kill fallback. If neither path reports disconnection,
        // restore the card so the UI never loses control of a live process.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4.5))
            guard let self,
                  self.terminatingEntryIDs.contains(dataUUID),
                  self.entry(for: dataUUID)?.phase.isActive == true else { return }
            self.terminatingEntryIDs.remove(dataUUID)
        }
    }

    private func removeLaterIfInactive(_ dataUUID: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self,
                  let entry = self.entry(for: dataUUID),
                  !entry.phase.isActive else { return }
            self.entries.removeAll { $0.dataUUID == dataUUID }
            self.previews.removeValue(forKey: dataUUID)
            self.previewViews.removeValue(forKey: dataUUID)
        }
    }

    private func index(for dataUUID: String) -> Int? {
        entries.firstIndex { $0.dataUUID == dataUUID }
    }
}

extension Notification.Name {
    static let iOSSimMultitaskGuestDidOpen = Notification.Name("IOSSimMultitaskGuestDidOpen")
    static let iOSSimMultitaskGuestDidBecomeReady = Notification.Name("IOSSimMultitaskGuestDidBecomeReady")
    static let iOSSimMultitaskGuestDidFail = Notification.Name("IOSSimMultitaskGuestDidFail")
    static let iOSSimMultitaskGuestDidClose = Notification.Name("IOSSimMultitaskGuestDidClose")
    static let iOSSimShowContainerSwitcher = Notification.Name("IOSSimShowContainerSwitcher")
}
