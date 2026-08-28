import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The session activity: a running guest, a running web server, or both.
///
/// Each half brings its own control, so whichever is up can be stopped from the
/// lock screen without opening iOSSim.
struct GuestExitActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GuestSessionAttributes.self) { context in
            VStack(spacing: 10) {
                if let bundle = context.state.bundleIdentifier {
                    GuestRow(bundleIdentifier: bundle)
                }
                if context.state.bundleIdentifier != nil && context.state.server != nil {
                    Divider().overlay(.white.opacity(0.15))
                }
                if let server = context.state.server {
                    ServerRow(server: server)
                }
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.88))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.bundleIdentifier != nil
                          ? "iphone.and.arrow.forward"
                          : serverSymbol(context.state.server))
                        .font(.title2)
                        .foregroundStyle(context.state.bundleIdentifier != nil ? .orange : .teal)
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.bundleIdentifier != nil ? "VibeContainers Guest" : "VibeContainers Server")
                            .font(.headline)
                        Text(centerDetail(context.state))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.bundleIdentifier != nil {
                        Button(intent: ExitGuestIntent()) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.title3)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .accessibilityLabel("Exit guest and return to VibeContainers")
                    } else if context.state.server != nil {
                        Button(intent: StopServerIntent()) {
                            Image(systemName: "stop.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                        .accessibilityLabel("Stop the VibeContainers HTTP server")
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    if let server = context.state.server, context.state.bundleIdentifier != nil {
                        // Both halves are up, so the server needs its own line
                        // and its own button down here.
                        HStack {
                            Label(server.address, systemImage: serverSymbol(server))
                                .font(.caption)
                                .foregroundStyle(server.paused ? Color.secondary : Color.teal)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Button(intent: StopServerIntent()) {
                                Text("Stop").font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .tint(.teal)
                        }
                    } else {
                        Text(bottomHint(context.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.bundleIdentifier != nil
                      ? "iphone"
                      : serverSymbol(context.state.server))
                    .foregroundStyle(context.state.bundleIdentifier != nil ? .orange : .teal)
            } compactTrailing: {
                if context.state.bundleIdentifier != nil {
                    Button(intent: ExitGuestIntent()) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Exit VibeContainers guest")
                } else if let server = context.state.server {
                    Text("\(server.requests)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.teal)
                }
            } minimal: {
                Image(systemName: context.state.bundleIdentifier != nil
                      ? "iphone"
                      : serverSymbol(context.state.server))
                    .foregroundStyle(context.state.bundleIdentifier != nil ? .orange : .teal)
            }
            .keylineTint(context.state.bundleIdentifier != nil ? .orange : .teal)
        }
    }

    private func serverSymbol(_ server: GuestSessionAttributes.ServerState?) -> String {
        (server?.paused ?? false) ? "pause.circle" : "dot.radiowaves.left.and.right"
    }

    private func centerDetail(_ state: GuestSessionAttributes.ContentState) -> String {
        if let bundle = state.bundleIdentifier { return bundle }
        guard let server = state.server else { return "" }
        return server.paused ? "Paused — open VibeContainers to resume" : server.address
    }

    private func bottomHint(_ state: GuestSessionAttributes.ContentState) -> String {
        if state.bundleIdentifier != nil {
            return "Tap Exit to return safely to the VibeContainers home screen."
        }
        guard let server = state.server else { return "" }
        return server.paused
            ? "iOS suspended VibeContainers, so the server stopped. It resumes when you open the app."
            : "Serving \(server.folder) · \(server.requests) request\(server.requests == 1 ? "" : "s")"
    }
}

/// The guest half of the lock-screen card.
private struct GuestRow: View {
    let bundleIdentifier: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.title2)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Guest running in VibeContainers")
                    .font(.headline)
                Text(bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(intent: ExitGuestIntent()) {
                Label("Exit", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
    }
}

/// The web server half: the address to type into another device, and Stop.
private struct ServerRow: View {
    let server: GuestSessionAttributes.ServerState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: server.paused ? "pause.circle" : "dot.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(server.paused ? Color.secondary : Color.teal)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.paused ? "HTTP server paused" : server.address)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(server.paused
                     ? "Open VibeContainers to start serving again"
                     : "\(server.folder) · \(server.requests) request\(server.requests == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(intent: StopServerIntent()) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
        }
    }
}

@main
struct IOSSimExitActivityBundle: WidgetBundle {
    var body: some Widget {
        GuestExitActivityWidget()
    }
}
