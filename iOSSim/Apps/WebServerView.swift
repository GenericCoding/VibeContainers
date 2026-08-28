import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Settings → ★ HTTP Server. Start it, point it at a folder, and read off the
/// address the rest of the network should open.
struct WebServerView: View {
    var onBack: () -> Void

    @State private var server = WebServer.shared
    @State private var portText = ""
    @State private var picking = false
    @State private var notice: String?
    @State private var copied: String?

    @Environment(\.deviceSafeArea) private var safeArea

    var body: some View {
        ZStack(alignment: .top) {
            SysColor.groupedBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    statusCard
                    if let notice { noticeStrip(notice) }
                    addressSection
                    pathSection
                    portSection
                    logSection
                }
                .padding(.top, safeArea.top + 60)
                .padding(.bottom, safeArea.bottom + 40)
            }
            // The port field is a text field inside the scroll view, and
            // without this the page opens scrolled down to meet it.
            .defaultScrollAnchor(.top)

            InlineNavBar(title: "★ HTTP Server", backTitle: "Settings", onBack: onBack)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                server.setRoot(url, external: true)
                notice = nil
                if server.status.isRunning { server.restart() }
            case .failure(let error):
                notice = error.localizedDescription
            }
        }
        .onAppear { portText = String(server.port) }
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(statusTint.opacity(0.16))
                    .frame(width: 82, height: 82)
                Image(systemName: statusSymbol)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(statusTint)
            }

            Text(statusTitle)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(SysColor.label)

            Text(statusDetail)
                .font(.system(size: 14))
                .foregroundStyle(SysColor.secondaryLabel)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)

            Button {
                Haptics.tap(.medium)
                if server.status.isRunning { server.stop() } else { server.start() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: server.status.isRunning ? "stop.fill" : "play.fill")
                    Text(server.status.isRunning ? "Stop Server" : "Start Server")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Capsule().fill(server.status.isRunning ? SysColor.red : SysColor.green))
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .disabled(server.status.isBusy)
        }
        .padding(.bottom, 26)
    }

    private var statusSymbol: String {
        switch server.status {
        case .running: "dot.radiowaves.left.and.right"
        case .paused: "pause.circle"
        case .starting: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle"
        case .stopped: "network.slash"
        }
    }

    private var statusTint: Color {
        switch server.status {
        case .running: SysColor.green
        case .failed: SysColor.red
        case .starting, .paused: SysColor.orange
        case .stopped: SysColor.secondaryLabel
        }
    }

    private var statusTitle: String {
        switch server.status {
        case .running: "Serving"
        case .starting: "Starting…"
        case .paused: "Paused"
        case .failed: "Couldn't Start"
        case .stopped: "Stopped"
        }
    }

    private var statusDetail: String {
        switch server.status {
        case .running:
            "Anything on the same Wi-Fi can open the address below. The Live Activity keeps the address and a Stop button on your lock screen."
        case .starting:
            "Binding to port \(server.port)…"
        case .paused:
            "iOS suspended VibeContainers in the background and the listener went with it. It starts again by itself now that the app is open."
        case .failed(let message):
            message
        case .stopped:
            "Serves the www path over HTTP to this Wi-Fi network. Nothing outside that folder is reachable."
        }
    }

    @ViewBuilder
    private func noticeStrip(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SysColor.orange)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(SysColor.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { notice = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SysColor.secondaryLabel)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(SysColor.secondaryGrouped)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
    }

    // MARK: - Address

    private var addressSection: some View {
        ListSection(
            header: "Address",
            footer: server.status.isRunning
                ? "Tap an address to copy it. Open it in a browser on another device on the same network."
                : "These are this device's addresses on the network. They go live when the server starts."
        ) {
            let addresses = server.addresses
            if addresses.isEmpty {
                ListRow(showsSeparator: false, separatorInset: 16) {
                    Text("No network interface")
                        .font(.system(size: 17))
                        .foregroundStyle(SysColor.secondaryLabel)
                }
            } else {
                ForEach(Array(addresses.enumerated()), id: \.offset) { index, address in
                    ListRow(
                        showsSeparator: index != addresses.count - 1,
                        separatorInset: 16,
                        action: {
                            UIPasteboard.general.string = address
                            Haptics.tap(.light)
                            withAnimation(.snappy) { copied = address }
                            Task {
                                try? await Task.sleep(for: .seconds(1.6))
                                withAnimation(.easeOut(duration: 0.25)) { copied = nil }
                            }
                        }
                    ) {
                        Text(address)
                            .font(.system(size: 16, design: .monospaced))
                            .foregroundStyle(server.status.isRunning ? SysColor.label : SysColor.secondaryLabel)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    } trailing: {
                        Image(systemName: copied == address ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 15))
                            .foregroundStyle(copied == address ? SysColor.green : SysColor.secondaryLabel)
                    }
                }
            }
        }
    }

    // MARK: - www path

    private var pathSection: some View {
        ListSection(
            header: "www Path",
            footer: "The folder to serve. Documents/www is visible in the Files app, so a site can be dropped straight into it."
        ) {
            ListRow(separatorInset: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(server.root.lastPathComponent)
                        .font(.system(size: 17))
                        .foregroundStyle(SysColor.label)
                    Text(displayPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(SysColor.secondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding(.vertical, 5)
            } trailing: {
                Text(itemCount)
                    .font(.system(size: 13))
                    .foregroundStyle(SysColor.secondaryLabel)
            }

            ForEach(Array(server.documentFolders.enumerated()), id: \.element) { _, folder in
                ListRow(separatorInset: 16, action: { choose(folder) }) {
                    Label(folder.lastPathComponent, systemImage: "folder")
                        .font(.system(size: 17))
                        .foregroundStyle(SysColor.label)
                } trailing: {
                    if folder.standardizedFileURL == server.root.standardizedFileURL {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(SysColor.blue)
                    }
                }
            }

            ListRow(showsSeparator: false, separatorInset: 16, action: {
                Haptics.tap(.light)
                picking = true
            }) {
                Label("Choose Another Folder…", systemImage: "folder.badge.plus")
                    .font(.system(size: 17))
                    .foregroundStyle(SysColor.blue)
                    .padding(.vertical, 2)
            }
        }
    }

    private var displayPath: String {
        let home = NSHomeDirectory()
        return server.root.path.replacingOccurrences(of: home, with: "~")
    }

    private var itemCount: String {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: server.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return "\(contents.count) item\(contents.count == 1 ? "" : "s")"
    }

    private func choose(_ folder: URL) {
        Haptics.selection()
        server.setRoot(folder, external: false)
        if server.status.isRunning { server.restart() }
    }

    // MARK: - Port

    private var portSection: some View {
        ListSection(header: "Port",
                    footer: "Ports below 1024 are reserved. Changing this while the server is running restarts it.") {
            ListRow(showsSeparator: false, separatorInset: 16) {
                Text("Port")
                    .font(.system(size: 17))
                    .foregroundStyle(SysColor.label)
            } trailing: {
                TextField("8080", text: $portText)
                    .font(.system(size: 17, design: .monospaced))
                    .foregroundStyle(SysColor.label)
                    .tint(SysColor.blue)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .onSubmit(applyPort)
                    .onChange(of: portText) { _, _ in applyPort() }
            }
        }
    }

    private func applyPort() {
        guard let value = UInt16(portText), value >= 1024 else { return }
        guard value != server.port else { return }
        server.port = value
        if server.status.isRunning { server.restart() }
    }

    // MARK: - Log

    @ViewBuilder
    private var logSection: some View {
        ListSection(
            header: "Requests",
            footer: server.log.isEmpty
                ? nil
                : "\(server.requestCount) request\(server.requestCount == 1 ? "" : "s") · \(WebServerPage.byteCount(server.bytesServed)) served."
        ) {
            if server.log.isEmpty {
                ListRow(showsSeparator: false, separatorInset: 16) {
                    Text(server.status.isRunning ? "Waiting for the first request" : "No requests yet")
                        .font(.system(size: 17))
                        .foregroundStyle(SysColor.secondaryLabel)
                }
            } else {
                ForEach(Array(server.log.prefix(12).enumerated()), id: \.element.id) { index, entry in
                    ListRow(showsSeparator: index != min(11, server.log.count - 1), separatorInset: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.path)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundStyle(SysColor.label)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(entry.method) · \(entry.time.formatted(date: .omitted, time: .standard)) · \(WebServerPage.byteCount(entry.bytes))")
                                .font(.system(size: 12))
                                .foregroundStyle(SysColor.secondaryLabel)
                        }
                        .padding(.vertical, 4)
                    } trailing: {
                        Text("\(entry.status)")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(entry.status < 400 ? SysColor.green : SysColor.orange)
                    }
                }

                ListRow(showsSeparator: false, separatorInset: 16, action: {
                    Haptics.tap(.light)
                    withAnimation(.snappy) { server.clearLog() }
                }) {
                    Text("Clear Log")
                        .font(.system(size: 17))
                        .foregroundStyle(SysColor.blue)
                }
            }
        }
    }
}
