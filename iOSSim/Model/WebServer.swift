import Foundation
import Network
import Observation
import UIKit

/// A small HTTP/1.1 file server for the folder chosen as the www path.
///
/// Built straight on `NWListener` rather than a package: the whole job is
/// accept a connection, read a request line, write a response, and iOSSim has
/// no dependency manager to pull anything in with.
///
/// The socket work happens on its own queue inside `Engine`, which is not
/// main-actor bound; everything the UI reads is published back onto the main
/// actor. Nothing in here touches the filesystem outside the served root — see
/// `resolve(_:)`, which is the only place a request path becomes a file URL.
@MainActor
@Observable
final class WebServer {
    static let shared = WebServer()

    enum Status: Equatable {
        case stopped
        case starting
        case running(UInt16)
        /// iOS suspended the app and took the listener with it. The server
        /// starts again by itself when iOSSim comes back to the foreground.
        case paused
        case failed(String)

        var isRunning: Bool { if case .running = self { return true }; return false }
        var isBusy: Bool { self == .starting }
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let time: Date
        let method: String
        let path: String
        let status: Int
        let bytes: Int
    }

    private(set) var status: Status = .stopped
    private(set) var log: [LogEntry] = []
    private(set) var requestCount = 0
    private(set) var bytesServed = 0

    /// The folder being served.
    private(set) var root: URL

    var port: UInt16 {
        didSet { UserDefaults.standard.set(Int(port), forKey: Self.portKey) }
    }

    private var engine: Engine?
    /// Set while the app is in the background and the server is still up on
    /// borrowed time.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lastActivityPush = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    private static let portKey = "webserver.port"
    private static let rootKey = "webserver.rootBookmark"
    private static let rootPathKey = "webserver.rootPath"

    private init() {
        let defaults = UserDefaults.standard
        let savedPort = defaults.integer(forKey: Self.portKey)
        port = savedPort > 0 ? UInt16(savedPort) : 8080

        root = Self.defaultRoot
        restoreRoot()
        Self.seedDefaultRootIfNeeded(root)
        observeAppState()
        observeStopRequests()
    }

    // MARK: - The www path

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// `Documents/www`, which the Files app can reach — drop a site in there and
    /// it is served with no picking required.
    static var defaultRoot: URL {
        documents.appendingPathComponent("www", isDirectory: true)
    }

    var rootIsDefault: Bool { root.standardizedFileURL == Self.defaultRoot.standardizedFileURL }

    /// Folders sitting directly in Documents, offered as one-tap www paths.
    var documentFolders: [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.documents,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    func setRoot(_ url: URL, external: Bool) {
        // A folder from the document picker is only reachable through a
        // security-scoped bookmark, and only after the scope is opened.
        if external, let bookmark = try? url.bookmarkData(options: .minimalBookmark) {
            UserDefaults.standard.set(bookmark, forKey: Self.rootKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.rootKey)
        }
        UserDefaults.standard.set(url.path, forKey: Self.rootPathKey)
        root = url
        engine?.root = url
    }

    private func restoreRoot() {
        let defaults = UserDefaults.standard
        if let bookmark = defaults.data(forKey: Self.rootKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: [],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                root = url
                return
            }
        }
        if let path = defaults.string(forKey: Self.rootPathKey) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                root = url
                return
            }
        }
        root = Self.defaultRoot
    }

    /// Gives a brand new install something to serve, so the feature can be seen
    /// working before any files have been put anywhere.
    private static func seedDefaultRootIfNeeded(_ root: URL) {
        guard root.standardizedFileURL == defaultRoot.standardizedFileURL else { return }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: root.path) else { return }
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)

        let index = """
        <!doctype html>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>VibeContainers HTTP Server</title>
        <style>
          body { margin:0; font:16px/1.6 -apple-system,system-ui,sans-serif;
                 background:#16110F; color:#F2E6D8; padding:48px 24px; }
          main { max-width:36rem; margin:0 auto; }
          h1 { font-size:1.6rem; margin:0 0 .4rem; }
          p { color:#A2907F; }
          code { background:#211A17; padding:.15rem .4rem; border-radius:4px; color:#DFC17C; }
        </style>
        <main>
          <h1>It works.</h1>
          <p>This page is <code>index.html</code> in the folder VibeContainers is serving.
             Replace it, or drop any files beside it — they will be listed at
             <code>/</code> when there is no index page.</p>
          <p>The www path is set in Settings → ★ HTTP Server.</p>
        </main>
        """
        try? index.data(using: .utf8)?.write(to: root.appendingPathComponent("index.html"))
    }

    // MARK: - Lifecycle

    func start() {
        guard !status.isRunning, !status.isBusy else { return }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            status = .failed("The www path no longer exists. Choose another folder.")
            return
        }

        status = .starting
        let engine = Engine(root: root, port: port)
        self.engine = engine

        engine.onStatus = { [weak self] status in
            Task { @MainActor in self?.status = status }
        }
        engine.onRequest = { [weak self] entry in
            Task { @MainActor in self?.record(entry) }
        }
        engine.start()
        publishToActivity()
    }

    func stop() {
        engine?.stop()
        engine = nil
        status = .stopped
        endBackgroundTask()
        withdrawFromActivity()
    }

    func restart() {
        stop()
        start()
    }

    func clearLog() {
        log = []
        requestCount = 0
        bytesServed = 0
    }

    private func record(_ entry: LogEntry) {
        requestCount += 1
        bytesServed += entry.bytes
        log.insert(entry, at: 0)
        if log.count > 40 { log.removeLast(log.count - 40) }

        // ActivityKit rate-limits updates, and a page load is a burst of them
        // (html, css, every image). One push every couple of seconds keeps the
        // counter honest without spending the budget.
        if Date().timeIntervalSince(lastActivityPush) > 2 { publishToActivity() }
    }

    // MARK: - Live Activity

    /// Puts the server on the shared session activity — the address on the lock
    /// screen, a Stop button in the Dynamic Island.
    ///
    /// This is presence and control, not lifetime: an activity does not grant
    /// its app background runtime. What keeps the listener up for a little
    /// while after you leave is the background task below, and when that runs
    /// out the activity is the thing that says so.
    private func publishToActivity() {
        guard status.isRunning || status == .paused else { return }
        lastActivityPush = Date()
        let snapshot = GuestSessionAttributes.ServerState(
            address: addresses.first ?? "http://localhost:\(port)",
            folder: root.lastPathComponent,
            requests: requestCount,
            paused: status == .paused
        )
        try? SessionActivity.apply { $0.server = snapshot }
    }

    private func withdrawFromActivity() {
        try? SessionActivity.apply { $0.server = nil }
    }

    // MARK: - Background

    private func observeAppState() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.holdInBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeFromBackground() }
        })
    }

    /// Buys the listener what iOS is willing to give — around half a minute —
    /// and shuts it down cleanly when that runs out rather than letting the
    /// address go dead with the activity still advertising it.
    private func holdInBackground() {
        guard status.isRunning, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VibeContainers HTTP Server") { [weak self] in
            Task { @MainActor in self?.pauseForBackground() }
        }
    }

    private func pauseForBackground() {
        guard status.isRunning else { endBackgroundTask(); return }
        engine?.stop()
        engine = nil
        status = .paused
        publishToActivity()
        endBackgroundTask()
    }

    private func resumeFromBackground() {
        endBackgroundTask()
        guard status == .paused else { return }
        status = .stopped
        start()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// The Stop button in the Live Activity runs in the widget's process, so it
    /// reaches the app as a Darwin notification — delivered on resume if the
    /// app happened to be suspended when it was pressed.
    private func observeStopRequests() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, _, _, _ in
                Task { @MainActor in WebServer.shared.stop() }
            },
            SessionNotification.stopServer as CFString,
            nil,
            .deliverImmediately
        )
    }

    // MARK: - Addresses

    /// Every address the phone can be reached on, the Wi-Fi one first.
    var addresses: [String] {
        let running = status.isRunning
        let hostPort = running ? port : port
        return Self.localIPv4Addresses().map { "http://\($0):\(hostPort)" }
    }

    static func localIPv4Addresses() -> [String] {
        var found: [(name: String, address: String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = interface.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                     &host, socklen_t(host.count),
                                     nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let name = String(cString: interface.pointee.ifa_name)
            found.append((name, String(cString: host)))
        }

        // en0 is Wi-Fi on a phone and the host's network in the Simulator.
        return found
            .sorted { lhs, rhs in
                if lhs.name == "en0" { return true }
                if rhs.name == "en0" { return false }
                return lhs.name < rhs.name
            }
            .map(\.address)
    }
}
