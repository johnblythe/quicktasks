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

struct MenuView: View {
    @ObservedObject var controller: StatusController
    @State private var draft: String = ""
    @State private var flash: String?
    /// Row id the keyboard highlight sits on, nil when nothing is highlighted.
    @State private var highlighted: String?
    @FocusState private var fieldFocused: Bool

    /// Wider than v1's 320: a verify row carries report, accept, redo, reject,
    /// and resume, and the title still has to be readable next to them.
    /// Shared with --snapshot so the render is the real panel width.
    static let panelWidth: CGFloat = 352

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            quickFire
            Divider()
            header
            Divider()
            if controller.model.records.isEmpty {
                Text(emptyText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(controller.model.sections(now: controller.now), id: \.section) { entry in
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
                }
                // Caps the panel height so a long history scrolls instead of
                // growing the menu off the bottom of the screen.
                .frame(maxHeight: 320)
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
        .onAppear {
            controller.refresh()
            // The panel needs to be key before the TextField will take
            // keystrokes, and opening a MenuBarExtra window does not
            // activate the app on its own.
            NSApp.activate(ignoringOtherApps: true)
            fieldFocused = true
        }
        .onKeyPress(.downArrow) { moveHighlight(1) }
        .onKeyPress(.upArrow) { moveHighlight(-1) }
        .onKeyPress(.return) { triggerHighlighted() }
        .onKeyPress(.escape) { clearDraft() }
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

    /// Escape empties the quick-fire field first, then clears the highlight, so
    /// one key backs out of whichever thing is in progress.
    private func clearDraft() -> KeyPress.Result {
        if !draft.isEmpty {
            draft = ""
            return .handled
        }
        if highlighted != nil {
            highlighted = nil
            return .handled
        }
        return .ignored
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
                    .onSubmit(send)
                if !draft.isEmpty {
                    Button(action: send) {
                        Image(systemName: "return")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(controller.fireToPass ? "Add to the Pass" : "Queue this task")
                }
            }
            Picker("", selection: $controller.fireToPass) {
                Text("Run now").tag(false)
                Text("To Pass").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .help("Run now fires it with qt. To Pass files it as an item needing your go.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(StatusPalette.color(for: controller.model.aggregate)))
                .frame(width: 8, height: 8)
            Text(flash ?? controller.model.aggregate.headline)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .help(groupsTooltip)
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
                Text("Refreshed \(Self.clock.string(from: controller.model.refreshedAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                sourceBadge
                Spacer()
                FooterButton(icon: "list.bullet.rectangle", help: "Open the Pass") {
                    Actions.openPass(controller.model.passURL)
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
                set: { on in
                    controller.setLoginItem(on) { outcome in
                        switch outcome {
                        case .success:
                            show(on ? "Starts at login" : "Login item removed")
                        case .failure(let problem):
                            show(problem.message)
                        }
                    }
                }
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
    private var sourceBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(controller.model.source == .pass ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text("Pass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .help(sourceTooltip)
    }

    /// Which feed is live, and where the widget is looking for The Pass. The
    /// resolved URL is in here because "the Pass is not answering" reads very
    /// differently depending on whether the widget guessed port 8811 or read a
    /// live URL out of the hub's `.pass-url`.
    private var sourceTooltip: String {
        var lines: [String] = []
        if controller.model.source == .pass {
            let statusURL = URL(string: controller.model.passURL)?
                .appendingPathComponent("status.json").absoluteString
            lines.append("Live from \(statusURL ?? controller.model.passURL)")
        } else {
            lines.append("Reading the ledgers off disk: "
                         + (controller.model.passError ?? "the Pass feed is off"))
        }
        lines.append("Looking at \(controller.config.pass.describe)")
        if let problem = controller.config.pass.fileProblem {
            lines.append("Ignored \(problem)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - behaviour

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        if controller.fireToPass {
            let base = controller.passBase
            controller.perform(key: "capture", { Actions.capture(text: text, base: base) }) { outcome in
                switch outcome {
                case .success(let id): show(id.isEmpty ? "Added to the Pass" : "Added \(id)")
                case .failure(let problem): show(problem.message)
                }
            }
        } else {
            controller.perform(key: "fire", { Actions.fire(prompt: text).map { "Queued" } }) { outcome in
                switch outcome {
                case .success: show("Queued")
                case .failure(let problem): show(problem.message)
                }
            }
        }
    }

    private func resume(_ record: TaskRecord) {
        controller.perform(key: record.id, {
            Actions.resume(record: record).map { "Resuming \(record.id)" }
        }) { outcome in
            switch outcome {
            case .success(let message): show(message)
            case .failure(let problem): show(problem.message)
            }
        }
    }

    private func openReport(_ record: TaskRecord) {
        switch Actions.openReport(base: controller.model.passURL, report: record.report) {
        case .success: break
        case .failure(let problem): show(problem.message)
        }
    }

    /// The title's click and return's default: the Pass's own deep link to the
    /// item, falling back to the Pass root when the payload carried no template.
    private func openItem(_ record: TaskRecord) {
        switch Actions.openItem(template: controller.model.itemURLTemplate,
                                base: controller.model.passURL,
                                itemID: record.itemID ?? record.id) {
        case .success: break
        case .failure(let problem): show(problem.message)
        }
    }

    /// Fires the item's own kickoff prompt through `POST /run`. A 409 comes
    /// back as a short line in the header ("Already running", "Job slots
    /// full") rather than an HTTP status, because it is an expected answer.
    private func run(_ record: TaskRecord) {
        let base = controller.passBase
        controller.perform(key: record.id, {
            Actions.run(record: record, base: base).map { slug in
                slug.isEmpty ? "Fired" : "Fired \(slug)"
            }
        }) { outcome in
            switch outcome {
            case .success(let message): show(message)
            case .failure(let problem): show(problem.message)
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
            case .success: show("\(action.capitalized) saved")
            case .failure(let problem): show(problem.message)
            }
        }
    }

    /// Shows an outcome in the header for a couple of seconds. A failure has
    /// to be visible: the alternative is a task John believes is queued and
    /// never hears about again.
    private func show(_ message: String) {
        flash = message
        let shown = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if flash == shown { flash = nil }
        }
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
}

// MARK: - section header

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
