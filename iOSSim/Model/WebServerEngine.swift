import Foundation
import Network

extension WebServer {
    /// The socket half of the server: listens, parses one request per
    /// connection, writes a response, closes.
    ///
    /// Deliberately HTTP/1.0-shaped — a response per connection, `Connection:
    /// close`, no keep-alive — because that removes every question about
    /// pipelining and half-read bodies from a server whose whole job is handing
    /// a browser some files off local Wi-Fi.
    final class Engine: @unchecked Sendable {
        var root: URL
        private let port: UInt16
        private let queue = DispatchQueue(label: "iossim.webserver", qos: .userInitiated)
        private var listener: NWListener?

        var onStatus: ((Status) -> Void)?
        var onRequest: ((LogEntry) -> Void)?

        init(root: URL, port: UInt16) {
            self.root = root
            self.port = port
        }

        // MARK: - Listening

        func start() {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                onStatus?(.failed("\(port) is not a usable port."))
                return
            }

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            do {
                let listener = try NWListener(using: parameters, on: nwPort)
                self.listener = listener

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        onStatus?(.running(port))
                    case .failed(let error):
                        onStatus?(.failed(Self.describe(error, port: port)))
                        stop()
                    case .cancelled:
                        onStatus?(.stopped)
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
            } catch {
                onStatus?(.failed(Self.describe(error, port: port)))
            }
        }

        func stop() {
            listener?.cancel()
            listener = nil
        }

        private static func describe(_ error: Error, port: UInt16) -> String {
            if let nwError = error as? NWError, case .posix(let code) = nwError, code == .EADDRINUSE {
                return "Port \(port) is already in use. Try another one."
            }
            return error.localizedDescription
        }

        // MARK: - One connection, one request

        private func accept(_ connection: NWConnection) {
            connection.start(queue: queue)
            read(connection, buffer: Data())
        }

        private func read(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] chunk, _, isComplete, error in
                guard let self else { return }
                guard error == nil else { connection.cancel(); return }

                var buffer = buffer
                if let chunk { buffer.append(chunk) }

                // Headers end at the blank line; the body (if any) is ignored.
                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                    respond(to: head, on: connection)
                    return
                }

                if isComplete || buffer.count > 64 * 1024 {
                    connection.cancel()
                    return
                }
                read(connection, buffer: buffer)
            }
        }

        private func respond(to head: String, on connection: NWConnection) {
            let requestLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = requestLine.split(separator: " ").map(String.init)
            let method = parts.first ?? "GET"
            let rawTarget = parts.count > 1 ? parts[1] : "/"

            guard method == "GET" || method == "HEAD" else {
                send(.init(status: 405, reason: "Method Not Allowed",
                           type: "text/plain; charset=utf-8",
                           body: Data("Only GET and HEAD are served.\n".utf8)),
                     method: method, path: rawTarget, on: connection)
                return
            }

            let path = String(rawTarget.split(separator: "?").first ?? "/")
            let decoded = path.removingPercentEncoding ?? path
            let response = makeResponse(for: decoded)
            send(response, method: method, path: decoded, on: connection)
        }

        // MARK: - Routing

        private func makeResponse(for path: String) -> Response {
            guard let url = resolve(path) else {
                return .init(status: 403, reason: "Forbidden",
                             type: "text/plain; charset=utf-8",
                             body: Data("That path is outside the served folder.\n".utf8))
            }

            let manager = FileManager.default
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return .init(status: 404, reason: "Not Found",
                             type: "text/html; charset=utf-8",
                             body: Data(WebServerPage.notFound(path: path).utf8))
            }

            if isDirectory.boolValue {
                // A directory with an index page serves it, like any web server.
                let index = url.appendingPathComponent("index.html")
                if manager.fileExists(atPath: index.path) {
                    return file(at: index)
                }
                return .init(status: 200, reason: "OK",
                             type: "text/html; charset=utf-8",
                             body: Data(WebServerPage.listing(of: url, root: root, requestPath: path).utf8))
            }

            return file(at: url)
        }

        private func file(at url: URL) -> Response {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return .init(status: 500, reason: "Internal Server Error",
                             type: "text/plain; charset=utf-8",
                             body: Data("Could not read that file.\n".utf8))
            }
            return .init(status: 200, reason: "OK",
                         type: WebServerPage.contentType(for: url),
                         body: data)
        }

        /// Turns a request path into a file inside the root — or nothing.
        ///
        /// The standardised path has to still be under the standardised root,
        /// which is what stops `/../../Library` and a symlink pointing out of
        /// the folder from being served.
        private func resolve(_ path: String) -> URL? {
            let base = root.standardizedFileURL
            let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
            let candidate = base.appendingPathComponent(trimmed).standardizedFileURL

            let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
            guard candidate.path == base.path || candidate.path.hasPrefix(basePath) else { return nil }

            // Follow symlinks and check again, so a link inside the folder
            // cannot point out of it.
            let resolved = candidate.resolvingSymlinksInPath()
            let resolvedBase = base.resolvingSymlinksInPath()
            let resolvedBasePath = resolvedBase.path.hasSuffix("/") ? resolvedBase.path : resolvedBase.path + "/"
            guard resolved.path == resolvedBase.path || resolved.path.hasPrefix(resolvedBasePath) else { return nil }

            return candidate
        }

        // MARK: - Writing

        struct Response {
            let status: Int
            let reason: String
            let type: String
            let body: Data
        }

        private func send(_ response: Response, method: String, path: String, on connection: NWConnection) {
            var header = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
            header += "Content-Type: \(response.type)\r\n"
            header += "Content-Length: \(response.body.count)\r\n"
            header += "Cache-Control: no-store\r\n"
            header += "Connection: close\r\n\r\n"

            var payload = Data(header.utf8)
            if method != "HEAD" { payload.append(response.body) }

            onRequest?(LogEntry(time: Date(), method: method, path: path,
                                status: response.status, bytes: response.body.count))

            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
