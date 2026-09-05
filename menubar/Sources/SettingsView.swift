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
// Restart Pass is drawn but disabled: POST /restart is LD-212 and does not
// exist yet. It is here rather than left out because the button is the obvious
// thing to reach for when the Pass is the grey dot in the footer, and a
// disabled control with a tooltip saying which ticket will light it up answers
// that question better than an absence does.

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("The Pass") {
                    field("Base URL",
                          text: $passURL,
                          placeholder: "discover it",
                          commit: { commit { $0.passURLOverride = passURL } })
                    resolved(controller.config.pass.describe)
                    if let problem = controller.config.pass.settingProblem {
                        problemLine(problem)
                    }
                    if let problem = controller.config.pass.fileProblem {
                        problemLine("\(PassEndpoint.urlFileName): \(problem)")
                    }
                    note(passNote)
                    HStack(spacing: 8) {
                        Button("Restart Pass") {}
                            .disabled(true)
                            .help("Waiting on POST /restart (LD-212). Until the Pass "
                                  + "exposes it there is nothing for this to call.")
                        Text("Not yet available")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                section("Hub checkout") {
                    field("Directory",
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

    private var passNote: String {
        "QT_PASS_URL overrides this. Has to be http on 127.0.0.1 or localhost -- "
        + "the widget only ever talks to loopback. Leave it empty to use the hub's "
        + "\(PassEndpoint.urlFileName), then port 8811."
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
    private func field(_ label: String,
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
                .onSubmit(commit)
            Button("Apply", action: commit)
                .controlSize(.small)
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
