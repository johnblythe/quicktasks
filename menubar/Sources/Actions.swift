// Actions.swift -- everything the widget can do: fire a task, capture to The
// Pass, resume a run, open a report, open the Pass, and post a verdict.
//
// A menu-bar app launched by launchd or as a login item inherits almost no
// PATH, so every binary is resolved explicitly rather than trusted to be
// findable. The only network calls are the loopback ones in PassClient; this
// file shells out and opens URLs.

import Foundation
import AppKit

enum Actions {
    /// The Pass, as served by hub/serve.py.
    static let passURL = URL(string: PassEndpoint.defaultURL + "/")!

    /// Locates the `qt` script. install.sh symlinks it to ~/.local/bin/qt,
    /// which is the first place checked; QT_BIN overrides for a dev checkout.
    static func qtBinary(env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let override = env["QT_BIN"], !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".local/bin/qt"),
            home.appendingPathComponent("code/quicktasks/qt"),
            URL(fileURLWithPath: "/opt/homebrew/bin/qt"),
            URL(fileURLWithPath: "/usr/local/bin/qt"),
        ]
        // A qt sitting next to the built app, for a checkout-local install.
        let bundleNeighbour = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("qt")
        candidates.append(bundleNeighbour)
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Directory the fired task records as `invoked_from`. Deliberately $HOME
    /// and not a trusted dir, so a task fired from the menu bar runs under the
    /// default permission mode rather than silently escalating. Override with
    /// QT_MENUBAR_FIRE_DIR if you want quick-fire to land somewhere specific.
    static func fireDirectory(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = env["QT_MENUBAR_FIRE_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Queues a task the same way a shell would: `qt <prompt>`. qt's own
    /// catch-all branch turns a bare argument list into a queued task.
    @discardableResult
    static func fire(prompt: String) -> Result<Void, Problem> {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure("nothing to fire") }
        guard let qt = qtBinary() else {
            return .failure("qt not found; run install.sh")
        }
        let p = Process()
        p.executableURL = qt
        p.arguments = [text]
        p.currentDirectoryURL = fireDirectory()
        // qt detaches the run itself, so this returns as soon as it is queued.
        do {
            try p.run()
        } catch {
            return .failure("could not run qt: \(error.localizedDescription)")
        }
        return .success(())
    }

    /// Reopens a run in John's preferred terminal. The quicktask:// handler
    /// installed by `qt install-handler` is the same path Slack resume links
    /// take, so this shares its terminal choice and cmux behaviour. Falls back
    /// to invoking qt directly when the handler is not registered.
    @discardableResult
    static func resume(id: String) -> Result<Void, Problem> {
        guard !id.isEmpty else { return .failure("no task id") }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        if let url = URL(string: "quicktask://resume/\(encoded)"),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
            return .success(())
        }
        guard let qt = qtBinary() else {
            return .failure("no quicktask:// handler and no qt binary; run qt install-handler")
        }
        let p = Process()
        p.executableURL = qt
        p.arguments = ["_resume-launch", id]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        do {
            try p.run()
        } catch {
            return .failure("could not run qt resume: \(error.localizedDescription)")
        }
        return .success(())
    }

    /// Reopens a run, preferring the resume URL The Pass handed over so the
    /// widget follows the server's idea of the slug rather than deriving it.
    @discardableResult
    static func resume(record: TaskRecord) -> Result<Void, Problem> {
        if let raw = record.resumeURL, !raw.isEmpty, let url = URL(string: raw) {
            if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
                return .success(())
            }
            // No handler registered: fall through to the qt path with the slug
            // out of the URL, which is the same id `qt resume` takes.
            if let slug = PassStatus.resumeSlug(raw), !slug.isEmpty {
                return resume(id: slug)
            }
        }
        return resume(id: record.id)
    }

    // MARK: - The Pass

    static func openPass(_ base: String = PassEndpoint.defaultURL) {
        NSWorkspace.shared.open(URL(string: base) ?? passURL)
    }

    /// The Pass's deep link to one item, from `/status.json`'s
    /// `item_url_template` (`http://127.0.0.1:<port>/?item={item_id}`) with the
    /// id substituted. serve.py reads that query parameter and build() scrolls
    /// the item into view, so the title now lands on the row rather than on the
    /// top of the page.
    ///
    /// Falls back to the Pass root when there is no template (a v1 payload, or
    /// the file feed) or no item id (a freshly fired quicktask The Pass has not
    /// heard about yet), because opening the page is still better than a dead
    /// click.
    static func itemURL(template: String?, base: String, itemID: String?) -> URL? {
        guard let template, !template.isEmpty,
              let itemID, !itemID.isEmpty,
              template.contains(idPlaceholder) else {
            return URL(string: base) ?? passURL
        }
        // RFC 3986 unreserved only, not .urlQueryAllowed: the id goes in as a
        // query *value*, so an "&" in it has to be escaped rather than end the
        // parameter. Ids are normally slugs; captures are the ones that are not.
        let unreserved = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-._~"))
        let encoded = itemID.addingPercentEncoding(
            withAllowedCharacters: unreserved) ?? itemID
        let filled = template.replacingOccurrences(of: idPlaceholder, with: encoded)
        // A template that came back unusable is not worth a dead click either.
        return URL(string: filled) ?? URL(string: base) ?? passURL
    }

    /// The token serve.py leaves in `item_url_template`.
    static let idPlaceholder = "{item_id}"

    @discardableResult
    static func openItem(template: String?, base: String, itemID: String?) -> Result<Void, Problem> {
        guard let url = itemURL(template: template, base: base, itemID: itemID) else {
            return .failure("no link for this row")
        }
        NSWorkspace.shared.open(url)
        return .success(())
    }

    /// Fires an item's own kickoff prompt as a headless job, through The Pass
    /// rather than through qt: the prompt lives in the ledger, not in the
    /// widget, and `POST /run` is the route that already knows how to spawn it
    /// under the three-slot limit. Returns the job slug it started.
    static func run(record: TaskRecord, base: URL) -> Result<String, Problem> {
        guard let itemID = record.itemID, !itemID.isEmpty else {
            return .failure("row has no Pass item id")
        }
        return PassClient(base: base).run(id: itemID)
    }

    /// Joins /status.json's root-relative `report` path onto its `pass_url`.
    /// The report is served over http because a file:// link is dead from an
    /// http:// page, and serve.py sandboxes the response.
    static func reportURL(base: String, report: String) -> URL? {
        guard !report.isEmpty else { return nil }
        guard let root = URL(string: base) else { return nil }
        if let absolute = URL(string: report), absolute.scheme != nil { return absolute }
        return URL(string: report, relativeTo: root)?.absoluteURL
    }

    @discardableResult
    static func openReport(base: String, report: String?) -> Result<Void, Problem> {
        guard let report, let url = reportURL(base: base, report: report) else {
            return .failure("no report on this row")
        }
        NSWorkspace.shared.open(url)
        return .success(())
    }

    /// Sends the quick-fire text to The Pass as a gate item instead of running
    /// it. Returns the id the Pass assigned, for the flash message.
    static func capture(text: String, base: URL) -> Result<String, Problem> {
        PassClient(base: base).capture(text: text)
    }

    /// Posts one verdict for a verify row, in the same shape the review page's
    /// Save button posts. Any decision already sitting unreconciled in
    /// hub/decisions.json rides along, because serve.py overwrites that file
    /// wholesale and a one-row post would otherwise drop John's saved review.
    static func decide(record: TaskRecord,
                       action: String,
                       comment: String = "",
                       base: URL,
                       hubDir: URL?) -> Result<Void, Problem> {
        PassClient(base: base).decide(record: record,
                                      action: action,
                                      comment: comment,
                                      pending: PassPayload.pendingDecisions(hubDir: hubDir))
    }
}
