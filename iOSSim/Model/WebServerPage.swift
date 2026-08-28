import Foundation

/// The HTML the server generates: the directory browser and its error pages.
///
/// Styled to match the simulator rather than left as Apache-grey, because this
/// page *is* the interface anyone on the network sees.
enum WebServerPage {
    static func listing(of directory: URL, root: URL, requestPath: String) -> String {
        let manager = FileManager.default
        let contents = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let entries = contents
            .map { url -> (name: String, isDirectory: Bool, size: Int, modified: Date?) in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                return (url.lastPathComponent,
                        values?.isDirectory ?? false,
                        values?.fileSize ?? 0,
                        values?.contentModificationDate)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

        let base = requestPath.hasSuffix("/") ? requestPath : requestPath + "/"
        let title = requestPath == "/" ? root.lastPathComponent : directory.lastPathComponent

        var rows = ""
        if requestPath != "/" {
            let parent = (base as NSString).deletingLastPathComponent
            let up = parent.hasSuffix("/") ? parent : parent + "/"
            rows += """
            <a class="row up" href="\(escape(up))">
              <span class="icon">↑</span><span class="name">Parent folder</span><span class="meta"></span>
            </a>
            """
        }

        for entry in entries {
            let href = escape(base + entry.name) + (entry.isDirectory ? "/" : "")
            let meta = entry.isDirectory ? "folder" : byteCount(entry.size)
            let stamp = entry.modified.map { date in
                date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
            } ?? ""
            rows += """
            <a class="row" href="\(href)">
              <span class="icon">\(entry.isDirectory ? "▸" : "•")</span>
              <span class="name">\(escapeHTML(entry.name))</span>
              <span class="meta">\(meta)<span class="stamp">\(stamp)</span></span>
            </a>
            """
        }

        if entries.isEmpty {
            rows += #"<div class="empty">This folder is empty.</div>"#
        }

        return page(title: title, body: """
        <header>
          <h1>\(escapeHTML(title))</h1>
          <p class="path">\(escapeHTML(requestPath))</p>
        </header>
        <div class="list">\(rows)</div>
        <footer>\(entries.count) item\(entries.count == 1 ? "" : "s") · served by VibeContainers</footer>
        """)
    }

    static func notFound(path: String) -> String {
        page(title: "Not found", body: """
        <header>
          <h1>404</h1>
          <p class="path">\(escapeHTML(path))</p>
        </header>
        <div class="empty">Nothing is there. <a href="/">Back to the top</a>.</div>
        """)
    }

    // MARK: - Shell

    private static func page(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapeHTML(title)) — VibeContainers</title>
        <style>
          :root { color-scheme: dark; }
          * { box-sizing: border-box; }
          body { margin:0; background:#16110F; color:#F2E6D8;
                 font:16px/1.5 -apple-system, system-ui, "Segoe UI", sans-serif; }
          .wrap { max-width: 46rem; margin:0 auto; padding: 40px 20px 64px; }
          header { padding-bottom: 18px; }
          h1 { margin:0; font-size:1.75rem; letter-spacing:-0.01em; }
          .path { margin:.35rem 0 0; color:#A2907F; font:13px ui-monospace, Menlo, monospace;
                  word-break: break-all; }
          .list { border:1px solid rgba(242,230,216,.10); border-radius:12px; overflow:hidden;
                  background:#211A17; }
          .row { display:flex; align-items:center; gap:12px; padding:12px 16px;
                 text-decoration:none; color:inherit; border-bottom:1px solid rgba(242,230,216,.08); }
          .row:last-child { border-bottom:0; }
          .row:hover { background:#2E2521; }
          .row.up .name { color:#A2907F; }
          .icon { width:1rem; color:#DFC17C; text-align:center; flex:none; }
          .name { flex:1; word-break:break-all; }
          .meta { color:#A2907F; font-size:.8rem; text-align:right; flex:none; }
          .stamp { display:block; opacity:.65; font-size:.72rem; }
          .empty { padding:28px 16px; color:#A2907F; text-align:center; }
          a { color:#7C9EB8; }
          footer { margin-top:18px; color:#A2907F; font-size:.8rem; text-align:center; }
          @media (max-width: 30rem) { .stamp { display:none; } }
        </style>
        <div class="wrap">\(body)</div>
        </html>
        """
    }

    // MARK: - Bits

    static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "txt", "log", "md": "text/plain; charset=utf-8"
        case "xml", "plist": "application/xml; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "ico": "image/x-icon"
        case "pdf": "application/pdf"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        case "wav": "audio/wav"
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "zip": "application/zip"
        case "ipa": "application/octet-stream"
        case "dylib": "application/octet-stream"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "ttf": "font/ttf"
        default: "application/octet-stream"
        }
    }

    static func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Percent-encodes a path for an `href`.
    private static func escape(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }

    /// A file called `<script>x</script>.txt` must not become one.
    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
