// Actions.swift -- the three things the widget can do: fire, resume, open.
//
// A menu-bar app launched by launchd or as a login item inherits almost no
// PATH, so every binary is resolved explicitly rather than trusted to be
// findable. Nothing here reaches the network; the only URL opened is the
// loopback address The Pass already serves on.

import Foundation
import AppKit

enum Actions {
    /// The Pass, as served by hub/serve.py.
    static let passURL = URL(string: "http://127.0.0.1:8811/")!

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

    static func openPass() {
        NSWorkspace.shared.open(passURL)
    }
}
