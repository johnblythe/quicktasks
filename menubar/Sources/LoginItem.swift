// LoginItem.swift -- the footer's "Start at login" toggle.
//
// Does exactly what `./build.sh --agent` does, from inside the app: write
// ~/Library/LaunchAgents/com.quicktasks.menubar.plist out of the same
// template, with the real executable path substituted, then bootout and
// bootstrap it. Turning it off boots it out and deletes the plist, so the
// toggle is not a one-way door.
//
// KeepAlive stays false in the template on purpose: the dropdown's power
// button is a real quit, and a KeepAlive agent would relaunch the widget three
// seconds after John closed it. RunAtLoad is the intended lifetime.
//
// Read-back is the plist's existence, not `launchctl print`. The menu asks on
// every open, and spawning a subprocess to redraw a checkbox is a worse
// trade than being wrong in the one case where someone booted the agent out by
// hand and left the file behind.

import Foundation

enum LoginItem {
    static let label = "com.quicktasks.menubar"

    /// Overridable so a test can point the read-back at a scratch path and
    /// never touch the real LaunchAgents directory.
    static func plistPath(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = env["QT_MENUBAR_AGENT_PLIST"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func isEnabled(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        FileManager.default.fileExists(atPath: plistPath(env: env).path)
    }

    /// The executable the agent should launch. Prefers the installed copy
    /// under ~/.quicktasks, matching what build.sh --agent registers, so
    /// toggling this on from a build-directory run still points login at the
    /// installed app rather than at a scratch build that may be deleted.
    static func targetExecutable(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let dataDir = env["QT_DATA"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".quicktasks")
        let installed = dataDir
            .appendingPathComponent("QuicktaskStatus.app/Contents/MacOS/QuicktaskStatus")
        if FileManager.default.isExecutableFile(atPath: installed.path) { return installed }
        return URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first
            ?? Bundle.main.executableURL?.path
            ?? installed.path)
    }

    @discardableResult
    static func set(_ enabled: Bool,
                    env: [String: String] = ProcessInfo.processInfo.environment) -> Result<Void, Problem> {
        // Test-only override: a real failure here means launchctl refused the
        // agent or the plist could not be written, neither of which a test
        // can trigger on demand without leaving a real job loaded or a real
        // file on disk. Set to any non-empty string to force that failure
        // deterministically, with the string as the reported reason, and
        // skip both the filesystem write and the launchctl call entirely.
        if let forced = env["QT_MENUBAR_LOGINITEM_FORCE_FAIL"], !forced.isEmpty {
            return .failure(Problem(forced))
        }
        // Test-only override, the success twin of the one above: a real
        // success still writes the plist (safe -- the test-overridden
        // QT_MENUBAR_AGENT_PLIST path, never the real LaunchAgents one) so
        // isEnabled()'s read-back keeps telling the truth, but skips both
        // launchctl calls, which use the constant `label` regardless of
        // plist path and so could otherwise evict or replace a real login
        // item loaded under the same name.
        let skipLaunchctl = env["QT_MENUBAR_LOGINITEM_FORCE_OK"].map { !$0.isEmpty } ?? false
        return enabled ? enable(env: env, skipLaunchctl: skipLaunchctl)
                       : disable(env: env, skipLaunchctl: skipLaunchctl)
    }

    private static func enable(env: [String: String], skipLaunchctl: Bool = false) -> Result<Void, Problem> {
        let plist = plistPath(env: env)
        let body = template().replacingOccurrences(of: "__EXECUTABLE__",
                                                   with: targetExecutable(env: env).path)
        do {
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try body.write(to: plist, atomically: true, encoding: .utf8)
        } catch {
            return .failure("could not write \(plist.path): \(error.localizedDescription)")
        }
        guard !skipLaunchctl else { return .success(()) }
        // bootout first, so a re-run picks up the new plist instead of
        // silently keeping the previously loaded definition. It fails when
        // nothing is loaded, which is the normal case and not an error.
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        if case .failure(let problem) = launchctl(["bootstrap", "gui/\(getuid())", plist.path]) {
            // The plist is on disk either way, so login will still work next
            // time; only this session missed the bootstrap.
            return .failure("wrote the plist but launchctl refused it: \(problem.message)")
        }
        return .success(())
    }

    private static func disable(env: [String: String], skipLaunchctl: Bool = false) -> Result<Void, Problem> {
        let plist = plistPath(env: env)
        if !skipLaunchctl { _ = launchctl(["bootout", "gui/\(getuid())/\(label)"]) }
        if FileManager.default.fileExists(atPath: plist.path) {
            do {
                try FileManager.default.removeItem(at: plist)
            } catch {
                return .failure("booted it out but could not delete \(plist.path)")
            }
        }
        return .success(())
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Result<Void, Problem> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        do {
            try p.run()
        } catch {
            return .failure("could not run launchctl: \(error.localizedDescription)")
        }
        let detail = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(Problem(trimmed.isEmpty
                ? "launchctl exited \(p.terminationStatus)"
                : trimmed))
        }
        return .success(())
    }

    /// The committed template, read out of the app bundle first so the plist
    /// the toggle writes and the plist build.sh writes cannot drift. The inline
    /// copy is the fallback for a bundle built before build.sh copied it in.
    static func template() -> String {
        if let url = Bundle.main.url(forResource: label, withExtension: "plist"),
           let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            return text
        }
        return fallbackTemplate
    }

    static let fallbackTemplate = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>com.quicktasks.menubar</string>
          <key>ProgramArguments</key>
          <array>
            <string>__EXECUTABLE__</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <false/>
          <key>ProcessType</key>
          <string>Interactive</string>
          <key>StandardOutPath</key>
          <string>/tmp/quicktask-menubar.log</string>
          <key>StandardErrorPath</key>
          <string>/tmp/quicktask-menubar.log</string>
        </dict>
        </plist>
        """
}
