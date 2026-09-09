// SettingsView.swift -- the settings window behind the footer's gear.
//
// Every field is an override of something the widget already worked out for
// itself, so each one shows the *resolved* value next to the box: an empty Pass
// URL field is not "no Pass", it is "discovered, and here is what was found and
// how". A settings window that only showed what you typed would be the one
// place in the app that could not answer "so where is it actually looking".
//
// Writes are applied on commit rather than per keystroke -- a Pass URL is not a
// valid URL for most of the time it is being typed, and re-resolving the feed
// against each half-finished one would fill the footer with errors that are
// only true for a moment. The toggles and steppers, which cannot be
// half-finished, apply immediately.
//
// Restart Pass calls POST /restart (LD-201) behind a confirmation sheet, since
// it is disruptive enough to a launchd-supervised Pass (and final for a
// hand-started one) that a stray click should not be able to fire it. The
// outcome text after a click comes from StatusController.RestartMessage,
// which is worded once there rather than re-derived here.

import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var controller: StatusController

    /// Wide enough for a `file:///Users/...` path to read without truncating,
    /// which is most of what this window shows.
    static let windowWidth: CGFloat = 460

    /// Working copies. Committed to the controller on submit or on focus
    /// leaving the field, so a partly-typed URL never reaches the feed.
    @State private var passURL: String = ""
    @State private var hubDir: String = ""
    @State private var showRestartConfirm = false
    @State private var restartMessage: StatusController.RestartMessage?
    /// Which field's Apply button most recently committed, nil once its
    /// checkmark's 1.5s is up. Restart Pass's own verdict already survives
    /// this window closing (StatusController posts it as an outcome), but a
    /// checkmark right on the button is still the fastest confirmation that
    /// a plain field commit landed while this window is still open.
    @State private var appliedField: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("The Pass") {
                    field("passURL", "Base URL",
                          text: $passURL,
                          placeholder: "discover it",
                          commit: { commit { $0.passURLOverride = passURL } })
                    resolved(controller.config.pass.describe)
                    if let rejected = controller.config.pass.rejected {
                        note(rejected)
                    }
                    if let problem = controller.config.pass.settingProblem {
                        problemLine(problem)
                    }
                    if let problem = controller.config.pass.fileProblem {
                        problemLine("\(PassEndpoint.urlFileName): \(problem)")
                    }
                    note(passNote)
                    HStack(spacing: 8) {
                        Button("Restart Pass") { showRestartConfirm = true }
                            .disabled(controller.busy.contains(StatusController.restartBusyKey))
                        if controller.busy.contains(StatusController.restartBusyKey) {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .confirmationDialog("Restart The Pass?",
                                        isPresented: $showRestartConfirm,
                                        titleVisibility: .visible) {
                        Button("Restart", role: .destructive) {
                            controller.restartPass { message in restartMessage = message }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Jobs in flight keep running; the page and this widget "
                             + "reconnect in a few seconds.")
                    }
                    if let restartMessage {
                        switch restartMessage {
                        case .restarting:
                            note("Restarting… back in a few seconds")
                        case .backUp:
                            note("Pass is back")
                        case .stillDown:
                            problemLine("Still not answering after about 20 seconds. It "
                                        + "may need starting by hand.")
                        case .stopped:
                            problemLine("Pass stopped (it was hand-started, so nothing "
                                        + "restarts it). Start it again with launchctl "
                                        + "kickstart -k gui/$UID/to.punchlist.serve after "
                                        + "loading the agent, or python3 serve.py.")
                        case .problem(let text):
                            problemLine(text)
                        }
                    }
                }

                section("Hub checkout") {
                    field("hubDir", "Directory",
                          text: $hubDir,
                          placeholder: "from config.json",
                          commit: { commit { $0.hubDirOverride = hubDir } })
                    resolved(controller.config.hubDir?.path ?? "hub feed off")
                    note("Where the job ledger and \(PassEndpoint.urlFileName) are read "
                         + "from. QT_HUB overrides this.")
                }

                section("Polling") {
                    HStack(spacing: 10) {
                        Stepper(value: Binding(
                            get: { controller.settings.pollInterval },
                            set: { new in commit { $0.pollInterval = new } }
                        ), in: Settings.pollRange, step: 1) {
                            Text("Every \(Int(controller.settings.pollInterval)) seconds")
                                .font(.system(size: 12))
                        }
                    }
                    note("The menu also re-reads the moment it opens, so this is how "
                         + "fresh the menu-bar dot is, not how fresh the list is.")
                }

                section("Rows") {
                    Stepper(value: Binding(
                        get: { controller.settings.rowLimit },
                        set: { new in commit { $0.rowLimit = new } }
                    ), in: Settings.limitRange, step: 1) {
                        Text("Show at most \(controller.settings.rowLimit) rows")
                            .font(.system(size: 12))
                    }
                    note("Trimmed after ordering, so the acting rows survive. The header "
                         + "count is never trimmed -- it always tallies the whole feed.")
                }

                section("Sections") {
                    ForEach(Section.allCases.sorted { $0.order < $1.order }, id: \.self) { s in
                        Toggle(isOn: Binding(
                            get: { controller.settings.shows(s) },
                            set: { on in
                                commit { settings in
                                    if on {
                                        settings.visibleSections.insert(s.rawValue)
                                    } else {
                                        settings.visibleSections.remove(s.rawValue)
                                    }
                                }
                            }
                        )) {
                            Text(s.label).font(.system(size: 12))
                        }
                        .toggleStyle(.checkbox)
                    }
                    note("Switching a section off drops it from the list entirely, header "
                         + "and count included. Collapsing one in the menu keeps both.")
                }

                section("Summon hotkey") {
                    HotkeyRecorderControl(combo: Binding(
                        get: { controller.settings.hotkeyCombo },
                        set: { new in commit { $0.hotkeyCombo = new } }
                    ))
                    note("Opens quick-fire from anywhere, focused and ready to type. "
                         + "Default is \u{2325}Q. Clear turns the shortcut off; it does "
                         + "not fall back to the default.")
                }

                section("Notifications") {
                    Toggle(isOn: Binding(
                        get: { controller.settings.notifyWhenHidden },
                        set: { on in commit { $0.notifyWhenHidden = on } }
                    )) {
                        Text("Notify me when the dropdown is closed").font(.system(size: 12))
                    }
                    .toggleStyle(.checkbox)
                    note("Only while neither the dropdown nor the summon panel is open: a "
                         + "job finishing or failing, a Pass health change, a Restart Pass "
                         + "verdict, or a quick-fire failure. Turning this on for the first "
                         + "time asks macOS for permission once.")
                }

                section("Launch") {
                    Toggle(isOn: Binding(
                        get: { controller.loginItem },
                        set: { on in controller.setLoginItem(on) { _ in } }
                    )) {
                        Text("Start at login").font(.system(size: 12))
                    }
                    .toggleStyle(.checkbox)
                    note("Writes ~/Library/LaunchAgents/com.quicktasks.menubar.plist, "
                         + "the same one build.sh --agent installs.")
                }
            }
            .padding(20)
            .frame(width: Self.windowWidth, alignment: .leading)
        }
        .onAppear {
            passURL = controller.settings.passURLOverride ?? ""
            hubDir = controller.settings.hubDirOverride ?? ""
        }
    }

    // MARK: - commit

    /// Mutates a copy of the current settings and hands it to the controller,
    /// which persists it and re-resolves the feed in one step. Going through
    /// the controller rather than writing UserDefaults here is what keeps the
    /// window from showing a value the running feed has not adopted.
    private func commit(_ change: (inout Settings) -> Void) {
        var next = controller.settings
        change(&next)
        controller.apply(next)
    }

    /// Flashes the checkmark next to one field's Apply button for 1.5s.
    /// Purely a same-window confirmation that the click landed -- Restart
    /// Pass's own verdict already survives this window closing by going
    /// through the outcome queue instead, which ephemeral SwiftUI state
    /// like this one cannot do.
    private func showApplied(_ id: String) {
        appliedField = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if appliedField == id { appliedField = nil }
        }
    }

    private var passNote: String {
        "QT_PASS_URL overrides this. Has to be http on 127.0.0.1 or localhost -- "
        + "the widget only ever talks to loopback. Leave it empty to use port "
        + "8811 when it answers, then the hub's \(PassEndpoint.urlFileName) if it "
        + "names this same hub."
    }

    // MARK: - pieces

    @ViewBuilder
    private func section(_ title: String,
                         @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    @ViewBuilder
    private func field(_ id: String,
                       _ label: String,
                       text: Binding<String>,
                       placeholder: String,
                       commit: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 66, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { commit(); showApplied(id) }
            Button("Apply") { commit(); showApplied(id) }
                .controlSize(.small)
            if appliedField == id {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
            }
        }
    }

    /// What the widget actually resolved, as opposed to what was typed. The
    /// whole reason the window is worth opening when something is wrong.
    @ViewBuilder
    private func resolved(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 74)
    }

    @ViewBuilder
    private func problemLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 74)
    }

    @ViewBuilder
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
