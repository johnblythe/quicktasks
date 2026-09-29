// LoginItem.swift -- the footer's "Start at login" toggle.
//
// Writes ~/Library/LaunchAgents/com.quicktasks.menubar.plist out of the same
// template `./build.sh --agent` uses, with the real executable path
// substituted, and deletes it again when turned off. launchd loads that
// directory at login, so the file alone is the whole switch. It never calls
// launchctl: see `enable`/`disable` for why.
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

    /// The executable the agent should launch. Prefers the installed copy at
    /// ${QT_APP_DIR:-/Applications}/Quicktask.app, matching what build.sh's
    /// install step writes, so toggling this on from a build-directory run
    /// still points login at the installed app rather than at a scratch
    /// build that may be deleted. Falls back to the pre-/Applications
    /// install location under ~/.quicktasks for a machine that has not
    /// rebuilt since that moved, then to whatever binary is actually running.
    static func targetExecutable(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let appDir = env["QT_APP_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? URL(fileURLWithPath: "/Applications")
        let installed = appDir
            .appendingPathComponent("Quicktask.app/Contents/MacOS/QuicktaskStatus")
        if FileManager.default.isExecutableFile(atPath: installed.path) { return installed }
        let dataDir = env["QT_DATA"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".quicktasks")
        let legacy = dataDir
            .appendingPathComponent("QuicktaskStatus.app/Contents/MacOS/QuicktaskStatus")
        if FileManager.default.isExecutableFile(atPath: legacy.path) { return legacy }
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
        // QT_MENUBAR_LOGINITEM_FORCE_OK used to skip the launchctl calls here.
        // There are none now, so it is accepted and ignored; a test's writes
        // still land on its QT_MENUBAR_AGENT_PLIST override, never the real one.
        return enabled ? enable(env: env) : disable(env: env)
    }

    /// Writes the plist and stops there. Bootstrapping it on the spot, as
    /// this used to, starts a second copy (RunAtLoad) when this one was
    /// opened from Finder, and its bootout-first kills this very process when
    /// it is the agent's own job, before the bootstrap ever runs.
    private static func enable(env: [String: String]) -> Result<Void, Problem> {
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
        return .success(())
    }

    /// Deletes the plist and never boots the agent out. When this process is
    /// the agent's job -- the normal case after `build.sh --agent` -- a
    /// bootout SIGTERMs it before the delete runs (2026-09-28: the switch
    /// quit the widget, unloaded the agent, and left the plist behind, so
    /// login would have started it anyway). With the file gone, a job still
    /// loaded for this session is inert: KeepAlive is off and nothing loads
    /// it again at the next login.
    private static func disable(env: [String: String]) -> Result<Void, Problem> {
        let plist = plistPath(env: env)
        guard FileManager.default.fileExists(atPath: plist.path) else { return .success(()) }
        do {
            try FileManager.default.removeItem(at: plist)
        } catch {
            return .failure("could not delete \(plist.path): \(error.localizedDescription)")
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
