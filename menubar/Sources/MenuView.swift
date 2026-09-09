// MenuView.swift -- the dropdown, laid out after the status-menu reference:
// a quick-fire field with a Run-now / To-Pass toggle, the aggregate header,
// then collapsible sections (Running, Needs you, Done today, Earlier) with one
// row per task, and a footer carrying refreshed-at, the feed's health, the
// login toggle, and quit.
//
// Every action on a row is one click with no dialog, except the two that ask
// first: reject, which throws a finished job's work away, and Run it, which
// spends a job slot and a model's time. Accept and redo are recoverable in the
// review page, so they go straight through.
//
// Keyboard, deliberately minimal: up and down move a highlight through the
// visible rows, return takes the highlighted row's primary action (resume when
// there is a session, else the item's deep link), and escape clears the
// quick-fire field. The first arrow key also drops focus out of that field --
// while it has focus the field owns the arrows and return, which is what makes
// typing and pressing return still fire a quick task.

import SwiftUI
import AppKit

/// What quick-fire's own field is doing right now, driving both its
/// disabled state and the line drawn under it. Kept apart from the shared
/// outcome queue (`StatusController.post`, used by every other action --
/// resume, run, decide): a failure here has to leave the typed text on
/// screen rather than clearing it, and there is no queue-driven equivalent
/// of the field itself being re-enabled.
enum FireFieldState: Equatable {
    case idle
    case firing(toPass: Bool)
    case success(String)
    case failure(String)

    var isFiring: Bool {
        if case .firing = self { return true }
        return false
    }
}

/// What a fire's `Result` becomes on screen, and whether the panel it
/// happened in should close because of it -- pure, so `--dump-fire-outcome`
/// and MenuView's own `fire()` compute the exact same outcome from the same
/// `Actions.fire`/`Actions.capture` result, the same reason `FireResolve
/// .describe` exists apart from the view it backs.
///
/// A success closes the panel (`isPanel` gates it: never the real
/// dropdown) once the field has had a moment to show it landed; a failure
/// never closes anything, in either host, because the point of keeping the
/// typed text on screen is that John still has it in front of him to fix
/// or retry.
enum FireFieldOutcome {
    static func describe(result: Result<String, Problem>,
                         toPass: Bool,
                         displayText: String,
                         isPanel: Bool) -> (state: FireFieldState, hidesPanel: Bool) {
        switch result {
        case .success:
            let shown = toPass ? "On the Pass: \(displayText)"
                               : "Fired: \(String(displayText.prefix(40)))"
            return (.success(shown), isPanel)
        case .failure(let problem):
            return (.failure(problem.message), false)
        }
    }
}

struct MenuView: View {
    @ObservedObject var controller: StatusController
    @State private var draft: String = ""
    /// What quick-fire's own field is doing right now -- idle, firing,
    /// landed, or refused. Separate from the outcome queue, which every
    /// other action (resume, run, decide) posts to instead: a refusal here
    /// has to leave `draft` on screen, which the queue's own
    /// clears-after-being-seen behaviour cannot do.
    @State private var fireState: FireFieldState = .idle
    /// Row id the keyboard highlight sits on, nil when nothing is highlighted.
    @State private var highlighted: String?
    @FocusState private var fieldFocused: Bool

    /// The quick-search query. Narrows the rows across every section; the
    /// header keeps counting the whole feed, because a search box that also
    /// retallied "6 tasks need you" would be answering a question nobody asked.
    @State private var search: String = ""
    /// Whether the search field is on screen. Separate from the query being
    /// empty, so the field can be opened with an empty query and stay open
    /// while it is being typed into.
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    /// Which suggestion is mid-confirm, and for which action. Go and Deny ask
    /// first: one spends a job slot, the other throws the engine's find away.
    @State private var confirmingSuggestion: (id: String, action: String)?

    /// Called when Escape has nothing left to clear (draft, search, and
    /// highlight are already empty). nil for the real MenuBarExtra dropdown,
    /// which just keeps falling through to `.ignored`; the standalone hotkey
    /// panel wires this to close itself, since Escape closing the panel is
    /// the one behaviour a floating window needs that a dropdown does not.
    var onEscapeExhausted: (() -> Void)? = nil

    /// Wider than v1's 320: a verify row carries report, accept, redo, reject,
    /// and resume, and the title still has to be readable next to them.
    /// Shared with --snapshot so the render is the real panel width.
    static let panelWidth: CGFloat = 352

    /// Tallest the row list may get before it scrolls, so a long history
    /// cannot grow the panel off the bottom of the screen.
    static let listMaxHeight: CGFloat = 320

    /// Measured height of the row list's content, reported up from a
    /// GeometryReader behind it.
    ///
    /// The list needs an *explicit* height, not a `maxHeight` cap. A bare
    /// ScrollView is fully flexible along its scroll axis: it accepts a zero
    /// height proposal, and `.frame(maxHeight:)` only caps it -- nothing
    /// establishes a floor. `MenuBarExtra(.window)` hosts the panel under Auto
    /// Layout with the content pinned top and bottom, and in that regime
    /// SwiftUI compressed the flexible child to nothing: the entire list
    /// vanished while the header, computed from the model, went on counting
    /// the rows it was not drawing. Measuring the content and pinning the
    /// height to it renders the same under every proposal.
    @State private var listHeight: CGFloat = 0

    /// The model the list draws: the controller's, narrowed to the search
    /// query. Everything below the header reads this; the header itself reads
    /// the controller's own model, so the count never moves while filtering.
    private var model: MenuModel { controller.model.filtered(query: search) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            quickFire
            Divider()
            header
            if searching {
                Divider()
                searchField
            }
            Divider()
            if let latest = controller.outcomes.first, !latest.seen {
                OutcomeBanner(outcome: latest,
                             earlier: Array(controller.outcomes.dropFirst()),
                             onDismiss: { controller.dismissOutcome(latest.id) })
                Divider()
            }
            if controller.model.records.isEmpty {
                Text(emptyText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else if model.records.isEmpty && !model.showsSuggestions {
                // Filtered down to nothing. Says what was searched for, since
                // the query is one line up and easy to forget mid-type.
                Text("Nothing matches \u{201C}\(search)\u{201D}")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Suggestions lead the list: they are the only rows
                        // that are here to be decided rather than watched.
                        if model.showsSuggestions {
                            SuggestionSectionHeader(count: model.suggestions.count,
                                                    collapsed: controller.suggestionsCollapsed) {
                                controller.toggleSuggestions()
                            }
                            if !controller.suggestionsCollapsed {
                                ForEach(model.suggestions, id: \.itemID) { suggestion in
                                    SuggestionRow(
                                        suggestion: suggestion,
                                        busy: controller.busy.contains(suggestion.itemID),
                                        confirming: confirmingSuggestion?.id == suggestion.itemID
                                            ? confirmingSuggestion?.action : nil,
                                        onTitle: { openSuggestion(suggestion) },
                                        onAsk: { action in
                                            confirmingSuggestion = (suggestion.itemID, action)
                                        },
                                        onCancelAsk: { confirmingSuggestion = nil },
                                        onDecide: { action in
                                            confirmingSuggestion = nil
                                            decideSuggestion(suggestion, action: action)
                                        })
                                }
                            }
                        }
                        ForEach(model.sections(now: controller.now), id: \.section) { entry in
                            SectionHeader(section: entry.section,
                                          count: entry.records.count,
                                          collapsed: controller.isCollapsed(entry.section)) {
                                controller.toggle(entry.section)
                            }
                            if !controller.isCollapsed(entry.section) {
                                ForEach(entry.records, id: \.id) { record in
                                    TaskRow(record: record,
                                            now: controller.now,
                                            fetchedAt: controller.model.refreshedAt,
                                            busy: controller.busy.contains(record.id),
                                            highlighted: highlighted == record.id,
                                            onResume: { resume(record) },
                                            onReport: { openReport(record) },
                                            onTitle: { openItem(record) },
                                            onRun: { run(record) },
                                            onDecide: { action, comment in
                                                decide(record, action: action, comment: comment)
                                            })
                                }
                            }
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ListHeightKey.self,
                                                   value: geo.size.height)
                        }
                    )
                }
                // An explicit height, not a cap: see `listHeight`. Scrolls
                // once the content passes listMaxHeight, so a long history
                // cannot grow the menu off the bottom of the screen.
                .frame(height: renderedListHeight)
                .onPreferenceChange(ListHeightKey.self) { measured in
                    if abs(measured - listHeight) > 0.5 { listHeight = measured }
                }
            }
            if let warning = controller.model.warning {
                Divider()
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            Divider()
            footer
        }
        .frame(width: Self.panelWidth)
        // Two zero-sized buttons carry the command shortcuts. A MenuBarExtra
        // window has no menu bar of its own to hang them off, and onKeyPress
        // does not see a command-modified key that the menu system claims
        // first, so the shortcut has to belong to a real (if invisible) button.
        .background {
            VStack(spacing: 0) {
                Button("", action: toggleSearch)
                    .keyboardShortcut("f", modifiers: .command)
                Button("", action: { controller.showSettings() })
                    .keyboardShortcut(",", modifiers: .command)
                // Mode-select and one-shot-fire, all command-modified: same
                // reason as \u{2318}F/\u{2318}, above, a hidden button rather than
                // onKeyPress. Each checks fieldFocused itself so the shortcut
                // only fires while quick-fire's own field owns the keystroke.
                Button("", action: { selectMode(toPass: false) })
                    .keyboardShortcut("1", modifiers: .command)
                Button("", action: { selectMode(toPass: true) })
                    .keyboardShortcut("2", modifiers: .command)
                Button("", action: fireOtherMode)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .onAppear {
            controller.refresh()
            // The panel needs to be key before the TextField will take
            // keystrokes, and opening a MenuBarExtra window does not
            // activate the app on its own -- see `focusQuickFireField`.
            NSApp.activate(ignoringOtherApps: true)
            focusQuickFireField()
            // Only the real dropdown: the summon panel's own visibility is
            // tracked separately (StatusController.hotkeyPanel), and
            // `anyWindowVisible` already reads that directly.
            if onEscapeExhausted == nil { controller.dropdownDidAppear() }
            // Unconditional for both hosts: whichever one just opened, a
            // fresh banner in it still deserves its ~2s look before it
            // collapses into "N earlier".
            controller.scheduleMarkOutcomesSeen()
        }
        .onDisappear {
            if onEscapeExhausted == nil { controller.dropdownDidDisappear() }
        }
        .onChange(of: controller.summonTick) { _, _ in
            // A cached, reused panel (StatusController.showHotkeyPanel keeps
            // one and re-shows it) never re-fires .onAppear after its first
            // show, which is exactly why \u{2325}Q used to focus once and go
            // silent on every summon after. This tick is bumped on every
            // summon, cached panel or not, so the dance below always
            // reruns. Harmless for the real dropdown's own MenuView, which
            // observes the same controller: writing @FocusState on a
            // window that is not key has no visible effect.
            focusQuickFireField()
        }
        .onKeyPress(.downArrow) { moveHighlight(1) }
        .onKeyPress(.upArrow) { moveHighlight(-1) }
        .onKeyPress(.return) { triggerHighlighted() }
        // Bare Tab, no modifier, so onKeyPress sees it directly -- only the
        // command-modified shortcuts above need the hidden-button trick.
        // Guarded to the quick-fire field itself: Tab while it is unfocused
        // is normal control-to-control focus movement, not a mode swap.
        .onKeyPress(.tab) { toggleMode() }
        .onKeyPress(.escape) { clearDraft() }
        // Typing with neither field focused opens search and keeps the
        // keystroke, so the letter that started the search is not swallowed.
        // Only once the arrows have taken focus off the quick-fire field: while
        // that field has focus it owns every character, which is what keeps
        // "type, press return, task fired" working.
        .onKeyPress(phases: .down) { press in
            guard !fieldFocused, !searchFocused, !searching else { return .ignored }
            guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
            guard let c = press.characters.first, c.isLetter || c.isNumber else {
                return .ignored
            }
            search = String(press.characters)
            searching = true
            searchFocused = true
            return .handled
        }
        .onChange(of: controller.model.refreshedAt) { _, _ in
            // A highlight whose row has left the feed is dropped rather than
            // moved: the row under the cursor changing identity between polls
            // is how you act on the wrong thing.
            highlighted = KeyboardNav.survivor(ids: visibleIDs, current: highlighted)
        }
    }

    // MARK: - keyboard

    /// The rows the highlight can walk: display order, collapsed sections left
    /// out, so it is the same list the eye is walking.
    private var visibleIDs: [String] {
        controller.model
            .visibleRecords(collapsed: controller.collapsed, now: controller.now)
            .map { $0.id }
    }

    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        let ids = visibleIDs
        guard !ids.isEmpty else { return .ignored }
        // The arrows belong to the list once it is being navigated. Dropping
        // the field's focus is what lets return act on the row rather than
        // firing whatever is half-typed in the field.
        fieldFocused = false
        highlighted = KeyboardNav.move(ids: ids, from: highlighted, delta: delta)
        return .handled
    }

    private func triggerHighlighted() -> KeyPress.Result {
        guard let id = highlighted,
              let record = controller.model.records.first(where: { $0.id == id }) else {
            return .ignored
        }
        switch record.primaryAction {
        case .resume: resume(record)
        case .item: openItem(record)
        }
        return .handled
    }

    /// Escape backs out of one thing at a time, innermost first: a pending
    /// Go/Deny confirmation, then the search, then the quick-fire draft, then
    /// the highlight. One key undoing everything at once would make it
    /// impossible to abandon a confirmation without also losing the search.
    private func clearDraft() -> KeyPress.Result {
        if confirmingSuggestion != nil {
            confirmingSuggestion = nil
            return .handled
        }
        if searching {
            // First escape empties a non-empty query, second closes the field.
            if !search.isEmpty {
                search = ""
            } else {
                searching = false
                searchFocused = false
            }
            return .handled
        }
        if !draft.isEmpty {
            draft = ""
            return .handled
        }
        if highlighted != nil {
            highlighted = nil
            return .handled
        }
        // Nothing left to clear. The real MenuBarExtra dropdown passes no
        // closure here and keeps falling through to .ignored unchanged; the
        // standalone hotkey panel wires this to close itself, which is the
        // one thing a floating window needs from Escape that a dropdown does
        // not (a dropdown's own Escape-to-dismiss is AppKit's, not this).
        if let onEscapeExhausted {
            onEscapeExhausted()
            return .handled
        }
        return .ignored
    }

    /// Command-F. Opens the field and takes focus; closes it and drops the
    /// query when it is already open, so the same key puts the list back.
    private func toggleSearch() {
        if searching {
            searching = false
            search = ""
            searchFocused = false
        } else {
            searching = true
            searchFocused = true
            fieldFocused = false
        }
    }

    /// Height to give the row list. Falls back to one section header plus a
    /// row before the first measurement lands, so the list is never blank on
    /// the frame the menu opens on.
    private var renderedListHeight: CGFloat {
        let measured = listHeight > 0.5 ? listHeight : 58
        return min(measured, Self.listMaxHeight)
    }

    private var emptyText: String {
        controller.model.source == .pass ? "Nothing on the Pass and no task runs yet"
                                         : "No task runs yet"
    }

    // MARK: - sections

    private var quickFire: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: controller.fireToPass ? "tray.and.arrow.down.fill" : "bolt.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(controller.fireToPass ? "Capture to the Pass\u{2026}"
                                                : "Fire a quick task\u{2026}",
                          text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($fieldFocused)
                    .disabled(fireState.isFiring)
                    .onSubmit(send)
                if !draft.isEmpty, !fireState.isFiring {
                    Button(action: send) {
                        Image(systemName: "return")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(controller.fireToPass ? "Add to the Pass" : "Queue this task")
                }
            }
            if let line = fireStatusLine {
                Text(line.text)
                    .font(.system(size: 11))
                    .foregroundStyle(line.isError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 7) {
                Picker("", selection: $controller.fireToPass) {
                    Text("Run now").tag(false)
                    Text("To Pass").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .disabled(fireState.isFiring)
                .help("Run now fires it with qt, in the chip's folder. To Pass files it "
                      + "as an item needing your go. Tab swaps the two; \u{2318}1/\u{2318}2 "
                      + "pick one directly; \u{2318}\u{21A9} fires the other one once.")
                FireDirectoryChip(controller: controller)
            }
            Text("Tab swaps \u{00B7} \u{2318}\u{21A9} fires the other way")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// The line drawn under quick-fire's field for `fireState`, nil at rest.
    /// A firing state is worded so nothing reads as done before it is
    /// ("Firing\u{2026}" / "Sending to the Pass\u{2026}"); a landed one
    /// names what happened, briefly, before clearing itself; a refused one
    /// keeps its message on screen -- in red -- until the next fire
    /// replaces it, because nothing here ever clears it on a timer.
    private var fireStatusLine: (text: String, isError: Bool)? {
        switch fireState {
        case .idle: return nil
        case .firing(let toPass):
            return (toPass ? "Sending to the Pass\u{2026}" : "Firing\u{2026}", false)
        case .success(let text): return (text, false)
        case .failure(let message): return (message, true)
        }
    }

    /// The quick-search field. Narrows every section at once, including the
    /// suggestions, over the row's title, status text, reason, and source.
    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Filter rows\u{2026}", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if !search.isEmpty {
                // The count is the useful thing here rather than in the header:
                // it says how much of the list the query is hiding.
                Text("\(model.records.count + model.suggestions.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            RowButton(icon: "xmark.circle.fill", help: "Clear the filter") {
                search = ""
                searching = false
                searchFocused = false
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .help("Matches on title, status, reason, and source. Escape clears it.")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(StatusPalette.color(for: controller.model.aggregate)))
                    .frame(width: 8, height: 8)
                Text(controller.model.headlineText)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                FooterButton(icon: searching ? "magnifyingglass.circle.fill" : "magnifyingglass",
                             help: "Filter the rows (\u{2318}F)",
                             action: toggleSearch)
            }
            // "6 tasks need you" names nothing John can act on. The titles do,
            // and they are the reason the widget is a list rather than a badge
            // -- so the count carries two or three of them even when the rows
            // themselves are collapsed or scrolled out of sight.
            if let preview = headlinePreview {
                Text(preview)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .help(groupsTooltip)
    }

    /// The titles under the count, or nil when they would say nothing new.
    ///
    /// Two cases earn them. When the section holding the counted rows is
    /// collapsed, the count is all there is and the titles are the only way to
    /// know what it means. When the list is short, they cost one line and make
    /// the header readable without moving the eye. Once the list is long and
    /// open, the rows are right there and a preview is a second copy of the
    /// top of it -- so it is left off.
    private var headlinePreview: String? {
        // Nothing to preview when nothing needs him.
        if case .idle = controller.model.aggregate { return nil }
        let titles = controller.model.headlinePreview(limit: 3, now: controller.now)
        guard !titles.isEmpty else { return nil }
        let countedSection: Section = {
            if case .running = controller.model.aggregate { return .running }
            return .needsYou
        }()
        let collapsed = controller.isCollapsed(countedSection)
        guard collapsed || titles.count <= 3 else { return nil }
        return titles.joined(separator: " \u{00B7} ")
    }

    /// The Pass's own group counts. It sends every group it renders, including
    /// the empty ones, and "Today: 0 of 0 open" is noise in a tooltip.
    private var groupsTooltip: String {
        var lines = controller.model.groups
            .filter { $0.count > 0 || $0.undone > 0 }
            .map { "\($0.label): \($0.undone) of \($0.count) open" }
        // v2 counts finished-today off each job's own `finished` stamp, which
        // is a truer number than the widget's own Done-today section: that one
        // only holds the jobs still in the payload.
        if let done = controller.model.counts["done_today"], done > 0 {
            lines.append("Done today: \(done)")
        }
        guard !lines.isEmpty else { return controller.model.aggregate.headline }
        return lines.joined(separator: "\n")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The Pass caps jobs[] at 200. Said out loud, because a widget
            // quietly showing a slice of the history is the kind of thing you
            // only notice when it matters.
            if controller.model.truncated {
                Text("Recent runs only \u{00B7} the Pass has "
                     + "\(controller.model.counts["total_jobs"] ?? 0) jobs")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("/status.json caps jobs at 200 and sets counts.truncated. "
                          + "Open the Pass for the full history.")
            }
            HStack(spacing: 8) {
                Text(FreshnessLine.text(for: controller.model, now: controller.now))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                sourceBadge
                Spacer()
                FooterButton(icon: "list.bullet.rectangle", help: "Open the Pass") {
                    Actions.openPass(controller.model.passURL)
                }
                FooterButton(icon: "gearshape", help: "Settings (\u{2318},)") {
                    controller.showSettings()
                }
                FooterButton(icon: "arrow.clockwise", help: "Refresh now") {
                    controller.refresh()
                }
                FooterButton(icon: "power", help: "Quit") {
                    NSApp.terminate(nil)
                }
            }
            Toggle(isOn: Binding(
                get: { controller.loginItem },
                // The outcome -- success or failure -- is StatusController's
                // to post now: it has to survive this dropdown closing
                // mid-toggle the same way a Restart Pass verdict does.
                set: { on in controller.setLoginItem(on) { _ in } }
            )) {
                Text("Start at login").font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Writes ~/Library/LaunchAgents/com.quicktasks.menubar.plist, the same one build.sh --agent installs")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Which feed the rows came from. Grey is not an error state -- the file
    /// ledgers are a complete answer for everything qt knows about -- but it
    /// does mean gates and verify rows are invisible, so it has to be visible.
    /// Amber is its own state, in between: the Pass has started failing but
    /// the 90-second hold has not run out, so what is on screen is still the
    /// Pass's own last good model, just not fresh.
    private var sourceBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(sourceDotColor)
                .frame(width: 6, height: 6)
            Text("Pass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .help(sourceTooltip)
    }

    private var sourceDotColor: Color {
        if controller.model.source == .pass {
            return controller.model.passReachable ? .green : .orange
        }
        return .secondary.opacity(0.5)
    }

    /// Which feed is live, and where the widget is looking for The Pass. The
    /// resolved URL is in here because "the Pass is not answering" reads very
    /// differently depending on whether the widget guessed port 8811 or read a
    /// live URL out of the hub's `.pass-url`.
    private var sourceTooltip: String {
        var lines: [String] = []
        let model = controller.model
        if model.source == .pass && model.passReachable {
            let statusURL = URL(string: model.passURL)?
                .appendingPathComponent("status.json").absoluteString
            lines.append("Live from \(statusURL ?? model.passURL)")
        } else if model.source == .pass {
            // Held: still the Pass's own last good model, not yet the file
            // ledgers. `refreshedAt` is untouched by a held poll, so it is
            // still the time that model actually came from the Pass.
            let since = model.passStaleSince.map { Self.clock.string(from: $0) } ?? "just now"
            let asOf = Self.clock.string(from: model.refreshedAt)
            lines.append("Pass unreachable since \(since) \u{00B7} showing \(asOf)")
        } else {
            lines.append("Reading the ledgers off disk: "
                         + (model.passError ?? "the Pass feed is off"))
        }
        lines.append("Looking at \(controller.config.pass.describe)")
        if let rejected = controller.config.pass.rejected {
            lines.append(rejected)
        }
        if let problem = controller.config.pass.fileProblem {
            lines.append("Ignored \(problem)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - behaviour

    /// The belt-and-braces focus dance a summon needs: SwiftUI drops an
    /// `@FocusState` write that lands before the hosting window is actually
    /// key, and `makeKeyAndOrderFront` returning is not the same moment as
    /// that becoming true. Setting it once on the next run-loop turn and
    /// again \u{2248}50ms later catches the ordinary case and the rare one
    /// where the first attempt loses that race.
    private func focusQuickFireField() {
        DispatchQueue.main.async { fieldFocused = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fieldFocused = true }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !fireState.isFiring else { return }
        fire(rawText: text, toPass: controller.fireToPass)
    }

    /// The one place a quick-fire text actually goes out, in either mode.
    /// `send()` (return, or the field's own return-arrow button), \u{2318}1/\u{2318}2
    /// after they have already changed the mode, and `fireOtherMode()`'s
    /// one-shot all end up here so a fire is described and dispatched exactly
    /// one way regardless of which key sent it.
    ///
    /// `draft` is not cleared up front any more -- only `settle(...)` clears
    /// it, and only on success -- so a refusal leaves the typed text exactly
    /// where John can fix it or retry, instead of throwing it away the
    /// moment Return was pressed.
    ///
    /// To Pass ignores `--in`/`@` outright: the raw, unstripped text goes to
    /// `/capture`, matching `FireResolve.describe`'s own rule that the
    /// directory convention is a Run-now-only thing.
    private func fire(rawText: String, toPass: Bool) {
        fireState = .firing(toPass: toPass)
        // The standalone summon panel is the only host that ever closes
        // itself on a successful fire; the real dropdown never does. This
        // is the same "am I the panel" signal `clearDraft()` already uses
        // for Escape.
        let isPanel = onEscapeExhausted != nil
        if toPass {
            let base = controller.passBase
            controller.perform(key: "capture", { Actions.capture(text: rawText, base: base) }) { outcome in
                let (state, hidesPanel) = FireFieldOutcome.describe(
                    result: outcome, toPass: true, displayText: rawText, isPanel: isPanel)
                postFireOutcome(state)
                settle(state, hidesPanel: hidesPanel)
            }
        } else {
            let (prefixDir, stripped) = FireResolve.parsePrefix(rawText)
            let resolved = FireResolve.runDirectory(prefixDir: prefixDir, settings: controller.settings)
            controller.perform(key: "fire", {
                Actions.fire(prompt: stripped, in: resolved.url).map { "" }
            }) { outcome in
                let (state, hidesPanel) = FireFieldOutcome.describe(
                    result: outcome, toPass: false, displayText: stripped, isPanel: isPanel)
                postFireOutcome(state)
                settle(state, hidesPanel: hidesPanel)
            }
        }
    }

    /// Quick-fire posts to the shared outcome queue in addition to its own
    /// inline field message -- the inline message is instant feedback right
    /// where John typed; the queue is what a banner or a background
    /// notification draws from once the field itself is gone. Only a
    /// failure notifies: "quick-fire failure" is one of the few event
    /// types worth a real notification, a success is not, since the
    /// field's own line is already right in front of him when it lands.
    private func postFireOutcome(_ state: FireFieldState) {
        switch state {
        case .success(let text): controller.post(kind: .ok, title: text)
        case .failure(let message): controller.post(kind: .error, title: message, notify: true)
        default: break
        }
    }

    /// Lands one fire's outcome on the field. A success clears `draft` right
    /// away and shows its confirmation for \u{2248}1.2s before clearing
    /// itself -- closing the panel then too, when `hidesPanel` -- so "type,
    /// Enter" reads as one completed action. A failure clears nothing and
    /// schedules nothing: it shows and stays, in red, with the draft intact,
    /// until the next fire replaces it.
    private func settle(_ state: FireFieldState, hidesPanel: Bool) {
        if case .success = state { draft = "" }
        fireState = state
        guard case .success = state else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            // Only clear up and close if nothing else -- a fresh fire, the
            // panel already closing some other way -- has superseded this
            // one in the meantime.
            guard fireState == state else { return }
            fireState = .idle
            if hidesPanel { onEscapeExhausted?() }
        }
    }

    /// Tab, while the quick-fire field has focus: flips Run now/To Pass and
    /// back. Unguarded Tab elsewhere is left to do its normal job of moving
    /// focus between controls.
    private func toggleMode() -> KeyPress.Result {
        guard fieldFocused else { return .ignored }
        controller.fireToPass.toggle()
        return .handled
    }

    /// \u{2318}1/\u{2318}2: picks a mode directly rather than toggling it, so
    /// pressing the same one twice is a no-op instead of flipping back.
    private func selectMode(toPass: Bool) {
        guard fieldFocused else { return }
        controller.fireToPass = toPass
    }

    /// \u{2318}-Return: fires once with whichever mode the segmented control is
    /// *not* currently showing, then leaves the control exactly where it was.
    /// This is what lets one field serve both "mostly Run now, occasionally
    /// To Pass" and the opposite without either habit fighting the other's
    /// remembered default.
    private func fireOtherMode() {
        guard fieldFocused, !fireState.isFiring else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        fire(rawText: text, toPass: !controller.fireToPass)
    }

    private func resume(_ record: TaskRecord) {
        controller.perform(key: record.id, {
            Actions.resume(record: record).map { "Resuming \(record.id)" }
        }) { outcome in
            switch outcome {
            case .success:
                controller.post(kind: .info, title: "Resuming \(record.id)")
            case .failure(let problem):
                controller.post(kind: .error, title: "Couldn't resume", detail: problem.message)
            }
        }
    }

    private func openReport(_ record: TaskRecord) {
        switch Actions.openReport(base: controller.model.passURL, report: record.report) {
        case .success: break
        case .failure(let problem):
            controller.post(kind: .error, title: "Couldn't open the report", detail: problem.message)
        }
    }

    /// The title's click and return's default: the Pass's own deep link to the
    /// item, falling back to the Pass root when the payload carried no template.
    private func openItem(_ record: TaskRecord) {
        switch Actions.openItem(template: controller.model.itemURLTemplate,
                                base: controller.model.passURL,
                                itemID: record.itemID ?? record.id) {
        case .success: break
        case .failure(let problem):
            controller.post(kind: .error, title: "Couldn't open the item", detail: problem.message)
        }
    }

    /// Fires the item's own kickoff prompt through `POST /run`. A 409 comes
    /// back as a short line in the header ("Already running", "Job slots
    /// full") rather than an HTTP status, because it is an expected answer.
    private func run(_ record: TaskRecord) {
        let base = controller.passBase
        controller.perform(key: record.id, {
            Actions.run(record: record, base: base)
        }) { outcome in
            switch outcome {
            case .success(let slug):
                controller.post(kind: .ok, title: slug.isEmpty ? "Job started" : "Job started: \(slug)")
            case .failure(let problem):
                controller.post(kind: .error, title: "Couldn't start the job", detail: problem.message)
            }
        }
    }

    private func decide(_ record: TaskRecord, action: String, comment: String) {
        let base = controller.passBase
        let hub = controller.config.hubDir
        controller.perform(key: record.id, {
            Actions.decide(record: record, action: action, comment: comment,
                           base: base, hubDir: hub).map { action }
        }) { outcome in
            switch outcome {
            case .success:
                controller.post(kind: .ok, title: Self.decisionTitle(for: action))
            case .failure(let problem):
                controller.post(kind: .error, title: "Couldn't save the decision", detail: problem.message)
            }
        }
    }

    /// The outcome-queue wording for a row's verdict -- worded as what just
    /// happened, not the raw action name the Pass's `/decide` route expects.
    private static func decisionTitle(for action: String) -> String {
        switch action {
        case "accept": return "Accepted"
        case "redo": return "Sent back for redo"
        case "reject": return "Rejected"
        default: return "\(action.capitalized) saved"
        }
    }

    /// A suggestion's title click. Goes to wherever the suggestion came from
    /// when the engine said (`source_url`), and to the item in the Pass
    /// otherwise -- the source is the more useful of the two, since deciding a
    /// suggestion usually means reading the Slack thread behind it.
    private func openSuggestion(_ suggestion: Suggestion) {
        if let raw = suggestion.sourceURL, let url = URL(string: raw) {
            NSWorkspace.shared.open(url)
            return
        }
        switch Actions.openItem(template: controller.model.itemURLTemplate,
                                base: controller.model.passURL,
                                itemID: suggestion.itemID) {
        case .success: break
        case .failure(let problem):
            controller.post(kind: .error, title: "Couldn't open the item", detail: problem.message)
        }
    }

    /// Posts one of confirm / deny / go / snooze through `POST /decide`,
    /// falling back to `POST /save` on a Pass that has not shipped the route.
    private func decideSuggestion(_ suggestion: Suggestion, action: String) {
        let base = controller.passBase
        let hubDir = controller.config.hubDir
        controller.perform(key: suggestion.itemID, {
            Actions.decideSuggestion(id: suggestion.itemID,
                                     title: suggestion.title,
                                     action: action,
                                     base: base,
                                     hubDir: hubDir)
        }) { outcome in
            switch outcome {
            case .success(let message):
                controller.post(kind: .ok, title: message)
            case .failure(let problem):
                controller.post(kind: .error, title: "Couldn't save the decision", detail: problem.message)
            }
        }
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
}

// MARK: - outcome banner

/// The newest unseen Outcome, drawn at the top of the row list -- "Fired:",
/// "Accepted", "Job started:", an error in red with its reason, whatever
/// the newest producer just posted. A tap on the X dismisses it without
/// waiting for the ~2s auto-seen timer; "N earlier" only appears once there
/// is a second entry in the queue, so a burst of several outcomes (a poll
/// that both restarted Pass and finished two jobs) is never lost the moment
/// the newest one is dismissed or marked seen.
struct OutcomeBanner: View {
    let outcome: Outcome
    let earlier: [Outcome]
    let onDismiss: () -> Void

    @State private var showingEarlier = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: icon(for: outcome.kind))
                    .font(.system(size: 12))
                    .foregroundStyle(tint(for: outcome.kind))
                VStack(alignment: .leading, spacing: 1) {
                    Text(outcome.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint(for: outcome.kind))
                        .lineLimit(2)
                    if let detail = outcome.detail {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 6)
                RowButton(icon: "xmark", help: "Dismiss", action: onDismiss)
            }
            if !earlier.isEmpty {
                Button(showingEarlier ? "Hide \(earlier.count) earlier" : "\(earlier.count) earlier") {
                    showingEarlier.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.leading, 19)
                if showingEarlier {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(earlier) { item in
                            HStack(spacing: 5) {
                                Image(systemName: icon(for: item.kind))
                                    .font(.system(size: 9))
                                    .foregroundStyle(tint(for: item.kind))
                                Text(item.title)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.leading, 19)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func icon(for kind: Outcome.Kind) -> String {
        switch kind {
        case .ok: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func tint(for kind: Outcome.Kind) -> Color {
        switch kind {
        case .ok: return .primary
        case .error: return .red
        case .info: return .secondary
        }
    }
}

// MARK: - section header

/// The suggestions section's own header. Titled from the count rather than
/// labelled and counted like the others ("3 things we think you need to do",
/// not "Suggestions 3"), because the sentence is the pitch: these rows are a
/// claim about John's day, and a claim reads differently from a tally.
struct SuggestionSectionHeader: View {
    let count: Int
    let collapsed: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 9)
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(Suggestion.headline(count))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.primary.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(collapsed ? "Show the suggestions" : "Hide the suggestions")
    }
}

/// One suggestion: title, a line of reasoning, a confidence pip, and the four
/// answers. Two lines tall rather than one, because the rationale is the whole
/// reason the row is trustworthy enough to act on from a menu.
struct SuggestionRow: View {
    let suggestion: Suggestion
    let busy: Bool
    /// Non-nil while this row is asking about an action, and the action it is
    /// asking about.
    let confirming: String?
    let onTitle: () -> Void
    let onAsk: (_ action: String) -> Void
    let onCancelAsk: () -> Void
    let onDecide: (_ action: String) -> Void

    @State private var hovering = false

    /// Go and Deny ask first. Go spends a job slot and a model's time; Deny
    /// throws the engine's find away. Confirm and Snooze are both recoverable
    /// in the review page, so they go straight through -- the same split the
    /// task rows draw between accept/redo and reject/run.
    static let asksFirst: Set<String> = ["go", "deny"]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                ConfidencePip(step: suggestion.confidenceStep)
                Image(systemName: suggestion.source.symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 11)
                Button(action: onTitle) {
                    Text(suggestion.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12)
                } else if let action = confirming {
                    Text(action == "go" ? "Run it?" : "Drop it?")
                        .font(.system(size: 11))
                        .foregroundStyle(action == "go" ? .blue : .red)
                    RowButton(icon: "checkmark",
                              help: action == "go" ? "Yes, fire it now" : "Yes, drop it",
                              tint: AnyShapeStyle(action == "go" ? Color.blue : Color.red)) {
                        onDecide(action)
                    }
                    RowButton(icon: "xmark", help: "Leave it", action: onCancelAsk)
                } else {
                    actions
                }
            }
            if !suggestion.rationale.isEmpty {
                Text(suggestion.rationale)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
        .onHover { hovering = $0 }
        .help(helpText)
    }

    /// Confirm, Deny, Go, Snooze. Snooze is the hover-reveal one: it is the
    /// only one of the four that changes nothing, so it is the one that can
    /// afford to wait for the mouse to arrive on a 352-point row.
    @ViewBuilder private var actions: some View {
        RowButton(icon: "checkmark.circle", help: "Confirm: yes, this is mine") {
            onDecide("confirm")
        }
        RowButton(icon: "play.circle", help: "Go: fire it now (asks first)") {
            onAsk("go")
        }
        RowButton(icon: "xmark.circle", help: "Deny: not mine, drop it (asks first)") {
            onAsk("deny")
        }
        if hovering {
            RowButton(icon: "clock", help: "Snooze: ask me again later") {
                onDecide("snooze")
            }
        }
    }

    var helpText: String {
        var parts = [suggestion.title]
        if !suggestion.rationale.isEmpty { parts.append(suggestion.rationale) }
        parts.append("item: \(suggestion.itemID)")
        parts.append("source: \(suggestion.sourceRaw ?? suggestion.source.label)")
        parts.append(suggestion.confidenceWord)
        if !suggestion.proposed.isEmpty { parts.append("proposed: \(suggestion.proposed)") }
        if let at = suggestion.date { parts.append("from \(shortAge(from: at)) ago") }
        parts.append("confirm / go / deny, and snooze on hover")
        parts.append(suggestion.sourceURL == nil
                     ? "click the title to open it in the Pass"
                     : "click the title to open where it came from")
        return parts.joined(separator: "\n")
    }
}

/// Three dots, filled to the engine's confidence. Coarse on purpose: the
/// difference between 0.61 and 0.68 is not something the engine can defend,
/// and a percentage would imply that it can.
struct ConfidencePip: View {
    let step: Int

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(1...3, id: \.self) { i in
                Circle()
                    .fill(i <= step ? Color.secondary : Color.secondary.opacity(0.22))
                    .frame(width: 3.5, height: 3.5)
            }
        }
        .frame(width: 14)
    }
}

struct SectionHeader: View {
    let section: Section
    let count: Int
    let collapsed: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 9)
                Text(section.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.primary.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(collapsed ? "Show \(section.label.lowercased())" : "Hide \(section.label.lowercased())")
    }
}

// MARK: - one task row

struct TaskRow: View {
    let record: TaskRecord
    let now: Date
    let fetchedAt: Date
    let busy: Bool
    /// Whether the keyboard highlight is on this row.
    var highlighted: Bool = false
    let onResume: () -> Void
    let onReport: () -> Void
    let onTitle: () -> Void
    let onRun: () -> Void
    let onDecide: (_ action: String, _ comment: String) -> Void

    @State private var hovering = false
    /// Reject is two clicks. The first swaps the verdict buttons for a
    /// confirm pair, so the destructive one cannot be hit by accident on a
    /// 352-point-wide row full of 10-point icons.
    @State private var confirmingReject = false
    /// Run it asks the same way, for a different reason: it spends a job slot
    /// and a model's time, and the Pass only has three slots.
    @State private var confirmingRun = false
    @State private var noting = false
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(StatusPalette.color(for: record)))
                    .frame(width: 7, height: 7)
                // Which spoke filed this. A fixed-width glyph rather than a
                // word: at 352 points the title is the scarce thing, and the
                // full name is one hover away in the tooltip. Drawn even for
                // .other so the titles stay on one vertical line -- a column
                // that appears and disappears per row is harder to read past
                // than a neutral mark.
                Image(systemName: record.source.symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 11)
                Button(action: onTitle) {
                    Text(record.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                if confirmingReject {
                    Text("Reject?")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                    RowButton(icon: "checkmark", help: "Yes, reject it",
                              tint: AnyShapeStyle(.red)) {
                        confirmingReject = false
                        onDecide("reject", "")
                    }
                    RowButton(icon: "xmark", help: "Keep it") {
                        confirmingReject = false
                    }
                } else if confirmingRun {
                    Text("Run it?")
                        .font(.system(size: 11))
                        .foregroundStyle(.blue)
                    RowButton(icon: "checkmark", help: "Yes, fire it now",
                              tint: AnyShapeStyle(.blue)) {
                        confirmingRun = false
                        onRun()
                    }
                    RowButton(icon: "xmark", help: "Leave it") {
                        confirmingRun = false
                    }
                } else {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .frame(width: 12)
                    } else {
                        actions
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The keyboard highlight reads stronger than hover, so a row the
            // arrows landed on is findable without moving the mouse to it.
            .background(highlighted ? Color.accentColor.opacity(0.18)
                                    : (hovering ? Color.primary.opacity(0.06) : .clear))
            .onHover { hovering = $0 }
            .help(helpText)

            if noting {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    TextField("What should it redo?", text: $note)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .onSubmit {
                            noting = false
                            onDecide("redo", note)
                            note = ""
                        }
                    RowButton(icon: "xmark", help: "Cancel") {
                        noting = false
                        note = ""
                    }
                }
                .padding(.leading, 27)
                .padding(.trailing, 12)
                .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if record.hasReport {
            RowButton(icon: "doc.richtext", help: "Open the report", action: onReport)
        }
        // Fire the item's own prompt. Only offered when The Pass says it would
        // accept it: it has a prompt, and it is not already running or waiting
        // on a verdict.
        if record.canRun {
            RowButton(icon: "play.circle",
                      help: "Run it: fire this item's prompt as a job",
                      tint: AnyShapeStyle(.blue)) { confirmingRun = true }
        }
        if record.canDecide {
            RowButton(icon: "checkmark.circle", help: "Approve") { onDecide("accept", "") }
            RowButton(icon: "arrow.uturn.backward", help: "Redo with a note") {
                noting = true
            }
            RowButton(icon: "xmark.circle", help: "Reject") { confirmingReject = true }
        }
        // The reference's external-link arrow, here meaning "reopen the
        // session". Only shown when there is a session to reopen; the
        // placeholder keeps every row's detail column aligned.
        if record.canResume {
            RowButton(icon: "arrow.up.forward.app",
                      help: "Reopen in the terminal",
                      tint: AnyShapeStyle(record.wantsResume ? .primary : .tertiary),
                      action: onResume)
        } else {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 10))
                .opacity(0)
        }
    }

    /// Status text plus, for an in-flight row, a stopwatch that ticks off the
    /// wall clock. Finished rows keep the coarse relative age v1 showed.
    var detail: String {
        if let elapsed = record.liveElapsed(fetchedAt: fetchedAt, now: now) {
            return "\(record.detail) \(stopwatch(elapsed))"
        }
        guard let at = record.activity else { return record.detail }
        return "\(record.detail) \u{00B7} \(shortAge(from: at, to: now))"
    }

    var helpText: String {
        var parts = [record.title, "id: \(record.id)"]
        // Names the glyph. `.other` still says something -- "no source" is a
        // fact about the row, and for a quicktask it is the expected one.
        parts.append("source: \(record.sourceRaw ?? record.source.label)")
        if let item = record.itemID, item != record.id { parts.append("item: \(item)") }
        if let state = record.state, !state.isEmpty { parts.append("state: \(state)") }
        if record.origin == .pass { parts.append("from the Pass") }
        // The two things a row carries that the row itself has no room for.
        // Both come from the job side of /status.json, and both are the reason
        // you would want this row rather than its neighbour.
        if record.denialCount > 0 { parts.append("\(record.denialCount) permission denial(s)") }
        if record.outputCount > 0 { parts.append("\(record.outputCount) output file(s)") }
        if let e = record.error, !e.isEmpty { parts.append(String(e.prefix(160))) }
        parts.append(record.canResume ? "click the arrow to resume in a terminal"
                                      : "no session to resume")
        if record.canRun { parts.append("click play to fire its prompt as a job") }
        parts.append("click the title to open it in the Pass")
        return parts.joined(separator: "\n")
    }
}

/// A 10-point icon button sized to sit in a row without stealing width from
/// the title.
struct RowButton: View {
    let icon: String
    let help: String
    var tint: AnyShapeStyle = AnyShapeStyle(.primary)
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: hovering ? .semibold : .regular))
                .frame(width: 12)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct FooterButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

/// The compact directory chip next to the mode picker: where a Run-now fire
/// with no typed `--in`/`@` prefix lands. Dims and stops responding when To
/// Pass is selected, since To Pass ignores the directory outright -- the
/// chip would otherwise be inviting a click that changes nothing.
struct FireDirectoryChip: View {
    @ObservedObject var controller: StatusController

    private var resolved: FireResolve.Directory {
        FireResolve.chipDirectory(settings: controller.settings)
    }

    private var abbreviated: String {
        Self.abbreviate(resolved.url.path)
    }

    var body: some View {
        let recents = RecentDirs.load(tasksDir: controller.config.tasksDir)
        Menu {
            ForEach(recents, id: \.self) { dir in
                Button(Self.abbreviate(dir)) { commit(dir) }
            }
            if !recents.isEmpty { Divider() }
            Button("Choose\u{2026}") { chooseDirectory() }
            Button("Reset to default") { reset() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                Text(abbreviated)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(maxWidth: 130)
        .disabled(controller.fireToPass)
        .opacity(controller.fireToPass ? 0.35 : 1)
        .help(chipHelp)
    }

    private var chipHelp: String {
        switch resolved.source {
        case "env": return "QT_MENUBAR_FIRE_DIR overrides this: \(resolved.url.path)"
        case "chip": return "Run now fires in \(resolved.url.path). Click to change, or type "
            + "\u{201C}--in <dir>\u{201D} or \u{201C}@<dir>\u{201D} to fire in a directory once."
        default: return "Run now fires in \(resolved.url.path) (default). Click to change, or "
            + "type \u{201C}--in <dir>\u{201D} or \u{201C}@<dir>\u{201D} to fire in a directory once."
        }
    }

    private static func abbreviate(_ raw: String) -> String {
        (raw as NSString).abbreviatingWithTildeInPath
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = resolved.url
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            commit(url.path)
        }
    }

    private func reset() {
        var next = controller.settings
        next.fireDirOverride = nil
        controller.apply(next)
    }

    private func commit(_ dir: String) {
        var next = controller.settings
        next.fireDirOverride = dir
        controller.apply(next)
    }
}

/// Carries the measured height of the row list's content up to the panel, so
/// the scroll area can be given an explicit height rather than a cap. See
/// `MenuView.listHeight` for why a cap is not enough.
struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
