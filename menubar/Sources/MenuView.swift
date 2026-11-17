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
// typing and pressing return still fire a quick task. That focus check
// (KeyboardNav.returnTarget) is what a fresh summon relies on too: a
// highlight left over from an earlier visit to the panel is cleared before
// the field regains focus, but even if it weren't, the field's own focus
// would still win return over a stale highlight.

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

    /// Q12: whether the state is a refused fire -- the one landing the
    /// receipt must never overwrite, because the refusal is the thing on
    /// screen worth reading.
    var isFireFailure: Bool {
        if case .failure = self { return true }
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
    /// The row with its peek panel open (2026-11-03). One at a time; set by
    /// the row's eye button or by a notification banner's deep link (the
    /// controller's revealTick onChange below). Q3 reuses it for ask rows:
    /// expanding an ask in place is the same one-peek-at-a-time gesture.
    @State private var expandedID: String?
    @FocusState private var fieldFocused: Bool

    // MARK: Q3/Q6 -- the ask board and its in-place reading

    /// The ask feed and its board live on StatusController since Q6 -- this
    /// used to be view @State with a poll of its own, which could only run
    /// while a window was open. The view reads `controller.askFeed` /
    /// `controller.askBoard` and lets the controller's poll keep them fresh.
    /// When the board speaks asks (`speaksAsks`), the list below draws ask
    /// sections instead of the legacy task rows; when the hub predates the
    /// ask API the board carries the legacy model and the menu is exactly
    /// what it has always been.
    /// Threads fetched for rows whose peek is open, keyed by ask id.
    @State private var askThreads: [String: AskThread] = [:]
    /// Rows whose thread fetch is in flight.
    @State private var askLoadingThreads: Set<String> = []
    /// The verdict line E (or a refused E) left under a row: which row, the
    /// line to draw, and the undo token Z spends. Token nil when the hub
    /// refused -- the line still shows its words, but Z has nothing to do.
    @State private var askMoveLine: (id: String, line: String, token: String?)?
    /// The row whose text editor is open (Q9): which row, the move its field
    /// feeds, that move's body key, and the words the field holds. One at a
    /// time, like the peek panel; the plan's two ask-first writes (Follow
    /// up, Try with changes) open here rather than posting blind.
    @State private var askEdit: AskEditState?
    /// Whether a row's own field -- the editor, or a question's answer box
    /// -- currently has focus. While one does, every root key handler is
    /// inert, exactly the way quick-fire's field is: the field owns Return
    /// and the letters, so R/E/Z can never fire a move under the typing.
    @State private var askFieldFocused = false
    /// Q12: the receipt a successful fire from the ask field leaves under it
    /// -- the plan's "Got it. Running. The answer will come to you here." --
    /// carrying its Undo for as long as the undo window holds. nil at rest.
    @State private var askReceipt: AskReceipt?
    /// Whether the receipt's Undo is in flight, so the button cannot be
    /// double-spent.
    @State private var undoingReceipt = false
    /// Q12: the recent done asks under the field ("Ask again"), newest first,
    /// straight off `GET /asks.json?place=done`. Empty when the hub feed is
    /// not the ask API (the file fallback has no done-list endpoint).
    @State private var recentAsks: [Ask] = []
    @State private var recentAsksLoading = false
    /// The id-substring the snapshot seam asked to pre-expand (`--snapshot
    /// <png> --expand <id>`), consumed by the first board that can satisfy
    /// it. Held as @State because consuming it mutates view state.
    @State private var preexpand: String?

    // MARK: Q11 -- the yours section, the remind picker, find, the desk

    /// The ⌥⏎ picker Q12's seam comment left open: which words the reminder
    /// is for (the field's draft, POST /asks mode "remind") or which ask it
    /// retimes (a yours row, the `remind` move), plus the time text being
    /// typed. nil at rest.
    @State private var remindPick: RemindPick?
    @State private var remindPickError: String?
    @FocusState private var remindSpecFocused: Bool
    /// ⌘F in the ask menu is find across every ask ever (GET /asks/search,
    /// H11), not the local row filter the legacy menu keeps. The results are
    /// ask rows -- they open at their own address, and the eye reads the
    /// answer in place, exactly like a section row.
    @State private var findOpen = false
    @State private var findQuery = ""
    @State private var findResults: [AskSearchHit]?
    @State private var findMessage: String?
    @State private var findLoading = false
    /// Debounces the query; cancelled by the next keystroke so a typed
    /// phrase is one request, not one per key.
    @State private var findDebounce: DispatchWorkItem?
    /// Counted per fetch so a stale answer cannot land over a newer query.
    @State private var findTick = 0
    @FocusState private var findFocused: Bool


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
    ///
    /// Cached rather than recomputed on read: this used to be a computed
    /// property that reran `filtered(query:)` (a full `RowFilter` pass,
    /// re-folding every record's haystack) on every single access, and it is
    /// read a dozen-plus times across one `body` evaluation. That meant
    /// typing into quick-fire's *unrelated* draft field -- which reruns
    /// `body` on every keystroke but never touches `search` -- still paid for
    /// the search filter's full cost, repeatedly, per character. Recomputed
    /// only in `.onChange(of: search)` and alongside the controller's own
    /// model refresh, so a keystroke elsewhere is just a body re-evaluation
    /// reading a stored value.
    @State private var filteredModel: MenuModel
    private var model: MenuModel { filteredModel }

    init(controller: StatusController,
         preexpandAsk: String? = nil,
         onEscapeExhausted: (() -> Void)? = nil) {
        self.controller = controller
        self.onEscapeExhausted = onEscapeExhausted
        self._filteredModel = State(initialValue: controller.model.filtered(query: ""))
        self._preexpand = State(initialValue: preexpandAsk)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            quickFire
            Divider()
            header
            if searching {
                Divider()
                searchField
            } else if findOpen {
                Divider()
                findField
            }
            Divider()
            if let latest = controller.outcomes.first, !latest.seen {
                OutcomeBanner(outcome: latest,
                             earlier: Array(controller.outcomes.dropFirst()),
                             onDismiss: { controller.dismissOutcome(latest.id) })
                Divider()
            }
            rowList
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
        .background { shortcutButtons }
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
            // The ask feed is the controller's own poll now (Q6); this
            // covers the one race it cannot: a board that landed before
            // this view was installed, with a snapshot pre-expand waiting
            // on it. The onChange below covers every landing after.
            consumePreexpand()
            // Q12: the Ask-again list, off the board that is already here
            // or the one the poll is about to land.
            fetchRecentAsks()
        }
        .onDisappear {
            // Whichever host just closed, it starts the next visit clean --
            // see `resetKeyboardState()`.
            resetKeyboardState()
            if onEscapeExhausted == nil { controller.dropdownDidDisappear() }
        }
        .onChange(of: controller.revealTick) { _, _ in
            // A notification banner's deep link: land the highlight and the
            // peek panel on the row the banner was about, and fetch its
            // thread so the peek shows the answer itself rather than the
            // row's excerpt (the one gap Q6 left in the reveal).
            if let id = controller.revealID {
                highlighted = id
                expandedID = id
                if let row = controller.askBoard?.row(id: id) { expand(row) }
            }
            controller.consumeReveal()
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
            //
            // Reset before focusing: a highlight (or a suggestion mid-
            // confirm) from an earlier visit to a cached panel must not
            // survive into this one, or Return would act on it the instant
            // the field's own focus dance below finishes.
            resetKeyboardState()
            focusQuickFireField()
        }
        .onKeyPress(.downArrow) { moveHighlight(1) }
        .onKeyPress(.upArrow) { moveHighlight(-1) }
        .onKeyPress(.return) { handleReturn() }
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
        //
        // Q9 made the ask rows' own keys verbs before they are search
        // starters: on the highlighted row, R follows up, ⇧R redoes with
        // changes, C copies, E files done, A allows once, ⇧A allows always,
        // X stops (the hub's `moves` list gates every one of them, so a key
        // the row cannot honour falls through to search). Handled here
        // rather than in per-key onKeyPress modifiers so there is exactly
        // one place a bare letter is interpreted -- the place that already
        // knows whether a field owns the keystroke (a row's editor and a
        // question's answer box included) and whether the modifiers are
        // bare. Z stays special: undo is about the last write, not the row
        // under the cursor.
        .onKeyPress(phases: .down) { press in
            guard !fieldFocused, !searchFocused, !searching, !askFieldFocused,
                  !findFocused, !remindSpecFocused, remindPick == nil else { return .ignored }
            guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
            guard let c = press.characters.first, c.isLetter || c.isNumber else {
                return .ignored
            }
            if let hit = askKeyTarget(press.characters) {
                performAskButton(hit.button, on: hit.row)
                return .handled
            }
            // Q11: a yours row carries its own bare keys (E done, R remind,
            // D drop -- and Run when the hub offers it), resolved the same
            // way the action rows' are: the hub's `moves` list gates every
            // one, and a field with focus owns the keystroke first.
            if let hit = yoursKeyTarget(press.characters) {
                performYoursButton(hit.button, id: hit.id)
                return .handled
            }
            if press.characters.lowercased() == "z", zActsOnAsk {
                return pressZ()
            }
            search = String(press.characters)
            searching = true
            searchFocused = true
            return .handled
        }
        .onChange(of: controller.model.refreshedAt) { _, _ in
            // The controller polled a fresh model: re-narrow it to whatever
            // is currently typed, once, here -- not on every read below.
            filteredModel = controller.model.filtered(query: search)
            // A highlight whose row has left the feed is dropped rather than
            // moved: the row under the cursor changing identity between polls
            // is how you act on the wrong thing.
            highlighted = KeyboardNav.survivor(ids: visibleIDs, current: highlighted)
        }
        .onChange(of: controller.askBoard) { _, _ in
            // The controller's ask poll landed a board (Q6: the poll that
            // used to live here). Consume any pending snapshot pre-expand
            // against the fresh board; a no-op once nothing is waiting.
            consumePreexpand()
            // And keep the Ask-again list moving with it (Q12): a done ask
            // is newest exactly once, right after the poll that saw it.
            fetchRecentAsks()
        }
        .onChange(of: search) { _, newValue in
            // The query changed: re-narrow the controller's current model
            // once, here -- see `filteredModel`'s own doc comment for why
            // this used to happen on every read instead.
            filteredModel = controller.model.filtered(query: newValue)
        }
        .onChange(of: findQuery) { _, _ in
            // Q11: find across every ask, asked on a debounce so typing a
            // phrase is one request. An emptied field clears the results and
            // cancels whatever is in flight; the ⌘F toggle owns closing.
            guard findOpen else { return }
            if trimmedFindQuery.isEmpty {
                findDebounce?.cancel()
                findTick += 1
                findLoading = false
                findResults = nil
                findMessage = nil
                return
            }
            findDebounce?.cancel()
            let work = DispatchWorkItem { fetchFind() }
            findDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    // MARK: - keyboard

    /// The rows the highlight can walk: display order, collapsed sections left
    /// out, so it is the same list the eye is walking. Reads the same
    /// (possibly search-narrowed) `model` the rows are drawn from -- with a
    /// query typed, the drawn rows and the walked rows have to be the same
    /// list, or the arrows land on a row nobody can see. Ask rows walk the
    /// same way when the feed speaks asks (Q3): the same narrowed list the
    /// ask sections are drawing.
    private var visibleIDs: [String] {
        // While find is showing results, they are the list: the arrows and
        // the eye walk the found asks, not the sections behind them.
        if findOpen, let hits = findResults { return hits.map(\.id) }
        if asksLive, let board = controller.askBoard {
            let sectionIDs = board.sections
                .map { AskFilter.apply($0.rows, query: search) }
                .flatMap { $0.map(\.id) }
            // The yours section walks the same way (Q11), narrowed by the
            // same query, so the arrows and the eye stay on one list.
            let yoursIDs = yoursRows
                .filter { AskFilter.matches($0.ask, query: search) }
                .map(\.id)
            return sectionIDs + yoursIDs
        }
        return model
            .visibleRecords(collapsed: controller.collapsed, now: controller.now)
            .map { $0.id }
    }

    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        // A row's own field owns the arrows too (Q9): they move the caret in
        // the follow-up text, not the highlight under the row.
        if askFieldFocused { return .ignored }
        let ids = visibleIDs
        guard !ids.isEmpty else { return .ignored }
        // The arrows belong to the list once it is being navigated. Dropping
        // the field's focus is what lets return act on the row rather than
        // firing whatever is half-typed in the field. Every field is dropped:
        // whichever one had focus (quick-fire, search while a query is being
        // narrowed, find or the remind picker while they are being typed
        // into) has to give up Return the same way.
        fieldFocused = false
        searchFocused = false
        findFocused = false
        remindSpecFocused = false
        highlighted = KeyboardNav.move(ids: ids, from: highlighted, delta: delta)
        return .handled
    }

    private func triggerHighlighted() -> KeyPress.Result {
        // ⏎ on a find result opens it at its one address (Q11): results are
        // rows, and reading a thread is the one thing every ask allows.
        if findOpen, let hits = findResults, let id = highlighted,
           let hit = hits.first(where: { $0.id == id }) {
            openFindHit(hit)
            return .handled
        }
        // ⏎ on an ask row acts on the row's own return-key button when it
        // has one (Q9: Try with changes on a failed row, Open on an answer)
        // and opens the ask's one address otherwise -- always enabled, never
        // dimmed. A yours row opens the same way (Q11). Return falls through
        // to the legacy record path only when the feed is not speaking asks.
        if asksLive, let board = controller.askBoard,
           let id = highlighted {
            if let row = board.row(id: id) {
                if let button = AskKeys.returnTarget(ask: row.ask, fieldHasFocus: false) {
                    performAskButton(button, on: row)
                } else {
                    openAsk(row)
                }
            } else if let yours = yoursRows.first(where: { $0.id == id }) {
                openYours(yours)
            }
            return .handled
        }
        guard let id = highlighted,
              let record = model.records.first(where: { $0.id == id }) else {
            return .ignored
        }
        switch record.primaryAction {
        case .resume: resume(record)
        case .item: openItem(record)
        }
        return .handled
    }

    /// The root `.onKeyPress(.return)` handler. Routes through
    /// `KeyboardNav.returnTarget` first: while quick-fire's own field, the
    /// search field, or a row's editor/answer field has focus, Return is
    /// `.ignored` here so the field's own `.onSubmit` (`send`/`submitSearch`/
    /// the editor's submit) is what actually runs -- a highlight left over
    /// from an earlier visit must never hijack the key the moment a fresh
    /// summon refocuses the field. Only once no field owns the keystroke
    /// does a highlighted row get to act.
    private func handleReturn() -> KeyPress.Result {
        // The two Q11 fields own Return the same way the search field does
        // (KeyboardNav.returnTarget does not know them): their own
        // .onSubmit runs, never a highlight left over from earlier.
        if findFocused || remindSpecFocused { return .ignored }
        switch KeyboardNav.returnTarget(highlighted: highlighted,
                                        fieldFocused: fieldFocused,
                                        searchFocused: searchFocused,
                                        rowFieldFocused: askFieldFocused) {
        case .field: return .ignored
        case .row: return triggerHighlighted()
        case .none: return .ignored
        }
    }

    /// Return in the search field itself, before any arrow has taken focus
    /// off it. A highlight already means an arrow got there first, and the
    /// root `.onKeyPress(.return)` -- `triggerHighlighted` -- owns that case
    /// once `moveHighlight` drops `searchFocused`; this only runs while the
    /// field still owns Return. One match is unambiguous enough to act on
    /// directly; more than one highlights the first rather than guessing
    /// which of several the query meant.
    private func submitSearch() {
        guard highlighted == nil else { return }
        let ids = visibleIDs
        if ids.count == 1, let id = ids.first {
            // One match, whichever feed is live: act on it, since one match
            // is unambiguous enough not to need the extra keystroke.
            if asksLive, let board = controller.askBoard, let row = board.row(id: id) {
                openAsk(row)
                return
            }
            if let record = model.records.first(where: { $0.id == id }) {
                switch record.primaryAction {
                case .resume: resume(record)
                case .item: openItem(record)
                }
            }
        } else if let first = ids.first {
            highlighted = first
        }
    }

    /// Escape backs out of one thing at a time, innermost first: the row's
    /// open editor (Q9 -- the most transient thing on screen), then a
    /// pending Go/Deny confirmation, then the search, then the quick-fire
    /// draft, then the highlight. One key undoing everything at once would
    /// make it impossible to abandon a confirmation without also losing the
    /// search.
    private func clearDraft() -> KeyPress.Result {
        if askEdit != nil {
            cancelEdit()
            return .handled
        }
        // Q11: the remind picker backs out before anything older -- it is
        // the most transient thing on screen, the row editor excepted.
        if remindPick != nil {
            remindPick = nil
            remindPickError = nil
            return .handled
        }
        // And find before the legacy filter, same rule: innermost first.
        if findOpen {
            if !trimmedFindQuery.isEmpty {
                findQuery = ""
            } else {
                closeFind()
            }
            return .handled
        }
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
            resetKeyboardState()
            onEscapeExhausted()
            return .handled
        }
        return .ignored
    }

    /// Command-F. In the ask menu (Q11) it is the plan's find: across every
    /// ask ever, off the hub's own search -- the same key closes it and puts
    /// the sections back. The legacy menu keeps the local row filter it has
    /// always had, because a hub that predates the ask API has nothing to
    /// search but the rows on screen.
    private func toggleSearch() {
        if asksLive {
            if findOpen { closeFind() } else { openFind() }
            return
        }
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

    /// The row list, whichever feed is live. Extracted from `body` because
    /// the three-way branch (asks / empty / legacy) plus everything each arm
    /// carries sat, as one expression, past the compiler's type-check
    /// budget -- the same treatment `feedFacts` got in DumpModel (2026-10-29).
    @ViewBuilder private var rowList: some View {
        if let board = controller.askBoard, board.speaksAsks {
            // Q11: while find is open on a query, the results are the list;
            // the sections wait behind them until ⌘F or Escape closes it.
            if findOpen, !trimmedFindQuery.isEmpty || findMessage != nil {
                findList
            } else {
                // Q3: the feed speaks asks -- the list is ask sections, with
                // the yours section under them (Q11). The legacy branches
                // below stay exactly as they were for the hubs and fallbacks
                // that do not.
                askList(board)
            }
        } else if controller.model.records.isEmpty {
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
            legacyList
        }
    }

    /// The legacy task-row list, verbatim what the menu has always drawn:
    /// suggestions, then sections with collapsible headers and TaskRows.
    /// Kept whole and separate so the ask branch above cannot cost it its
    /// type-check budget, and vice versa.
    private var legacyList: some View {
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
                                  collapsed: controller.isCollapsed(entry.section),
                                  clearable: entry.records.contains { !$0.status.isActive },
                                  onToggle: { controller.toggle(entry.section) },
                                  onClear: { controller.clearSection(entry.section) })
                    if !controller.isCollapsed(entry.section) {
                        ForEach(entry.records, id: \.id) { record in
                            TaskRow(record: record,
                                    now: controller.now,
                                    fetchedAt: controller.model.refreshedAt,
                                    busy: controller.busy.contains(record.id),
                                    highlighted: highlighted == record.id,
                                    expanded: expandedID == record.id,
                                    onResume: { resume(record) },
                                    onReport: { openReport(record) },
                                    onTitle: { openItem(record) },
                                    onRun: { run(record) },
                                    onRevive: { revive(record) },
                                    onDecide: { action, comment in
                                        decide(record, action: action, comment: comment)
                                    },
                                    onToggleExpand: {
                                        expandedID = expandedID == record.id ? nil : record.id
                                    },
                                    onOpenResult: { openResult(record) },
                                    onCopyResult: { copyResult(record) })
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

    // MARK: - sections

    private var quickFire: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: controller.fireToPass ? "tray.and.arrow.down.fill" : "bolt.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                // Q12: the field is the ask field now -- the plan's own
                // placeholder, one wording for both modes, because the mode
                // control right below it is what says which of the two an
                // Enter will do.
                TextField("Ask for something\u{2026}", text: $draft)
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
                    .help(controller.fireToPass ? "Ask it (it waits for your OK)"
                                                 : "Run it now")
                }
            }
            if let line = fireStatusLine {
                Text(line.text)
                    .font(.system(size: 11))
                    .foregroundStyle(line.isError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            // Q12: the receipt a successful fire leaves. Drawn here, not as
            // a fireState success line, because it carries an Undo the
            // 1.2-second success timer must not clear -- the undo window is
            // minutes, not a blink, and the receipt is the only thing on the
            // panel that can still act after the fire itself is done.
            if let receipt = liveReceipt {
                HStack(spacing: 6) {
                    Text(receipt.line)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if undoingReceipt {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .frame(width: 12)
                    } else {
                        Button("Undo", action: undoReceipt)
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .help("Stop it and drop it (10-minute window)")
                    }
                }
            }
            // Q11: the ⌥⏎ picker, drawn under the receipt. It is the one
            // thing between the words and their reminder: a time field with
            // the few presets a person means by "later", return sends it,
            // Escape leaves the words exactly as they were.
            if let pick = remindPick {
                remindPicker(pick)
            }
            HStack(spacing: 7) {
                // AppKit's own segmented control rather than
                // `Picker(.segmented)`: see FireModeControl for the leak the
                // picker caused.
                FireModeControl(toPass: $controller.fireToPass)
                    .disabled(fireState.isFiring)
                    .help("Run now fires it with qt, in the chip's folder. Ask me first "
                          + "posts it to the hub as an ask that waits for your OK "
                          + "(an older hub gets it as a Pass item instead). Tab swaps "
                          + "the two; \u{2318}1/\u{2318}2 pick one directly; \u{2318}\u{21A9} "
                          + "fires the other one once.")
                FireDirectoryChip(controller: controller)
            }
            Text("Tab swaps \u{00B7} \u{2318}\u{21A9} fires the other way")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            // Q12: recent done asks, one line each. A click loads the ask's
            // own words back into the field -- re-firing is then one Enter,
            // in whichever mode the fire is set to, rather than a blind
            // re-run of something finished days ago.
            if asksLive, !recentAsks.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask again")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    ForEach(recentAsks.prefix(Self.recentAskCount), id: \.id) { ask in
                        Button { askAgain(ask) } label: {
                            HStack(spacing: 6) {
                                Text(ask.title)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 4)
                                if let at = ask.finishedDate ?? ask.createdDate {
                                    Text(shortAge(from: at))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Ask this again: \(ask.words)\nClick loads the words into the field")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// How many recent asks the field shows. Three: the panel is a menu, and
    /// a recency list longer than the sections below it would be the tail
    /// wagging the dog.
    static let recentAskCount = 3

    /// The line drawn under quick-fire's field for `fireState`, nil at rest.
    /// A firing state is worded so nothing reads as done before it is
    /// ("Firing\u{2026}" / "Sending to the Pass\u{2026}"); a landed one
    /// names what happened, briefly, before clearing itself; a refused one
    /// keeps its message on screen -- in red -- until the next fire
    /// replaces it, because nothing here ever clears it on a timer.
    ///
    /// Q12: while a live receipt is drawing (its own row, with its Undo),
    /// the success and idle states say nothing -- the receipt *is* the
    /// landing line now, and "Fired: \u{2026}" right above "Got it.
    /// Running\u{2026" would be the same fact twice. A firing or refused
    /// state still wins: the receipt describes the last fire, not the one
    /// in flight.
    private var fireStatusLine: (text: String, isError: Bool)? {
        if liveReceipt != nil, !fireState.isFiring, !fireState.isFireFailure {
            return nil
        }
        switch fireState {
        case .idle: return nil
        case .firing(let toPass):
            return (toPass ? "Asking\u{2026}" : "Firing\u{2026}", false)
        case .success(let text): return (text, false)
        case .failure(let message): return (message, true)
        }
    }

    /// The receipt currently worth drawing: one exists, and its undo window
    /// has not lapsed. `controller.now` ticks, so a receipt past its window
    /// leaves the screen on its own.
    private var liveReceipt: AskReceipt? {
        guard let askReceipt, askReceipt.undoable(now: controller.now) else { return nil }
        return askReceipt
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
                .onSubmit(submitSearch)
            if !search.isEmpty {
                // The count is the useful thing here rather than in the header:
                // it says how much of the list the query is hiding. Ask rows
                // count the same way: every row the query kept, sections and
                // all.
                Text("\(matchedRowCount)")
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

    /// ⌘F in the ask menu (Q11): the find field. Unlike the legacy filter
    /// above it narrows nothing locally -- the hub searches every ask ever
    /// (done and archived included, H11) and the results arrive as rows.
    private var findField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Find any ask\u{2026}", text: $findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($findFocused)
                .onSubmit(submitFind)
            if findLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12)
            } else if let hits = findResults, !trimmedFindQuery.isEmpty {
                Text("\(hits.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            RowButton(icon: "xmark.circle.fill", help: "Close find (\u{2318}F)") {
                closeFind()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .help("Searches every ask ever -- done and archived included -- through "
              + "the hub. \u{23CE} opens the first result; the eye reads one in place.")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle()
                    .fill(headerDot)
                    .frame(width: 8, height: 8)
                Text(headerHeadline)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                FooterButton(icon: searching ? "magnifyingglass.circle.fill" : "magnifyingglass",
                             help: asksLive ? "Find any ask (\u{2318}F)"
                                            : "Filter the rows (\u{2318}F)",
                             action: toggleSearch)
            }
            // "6 tasks need you" names nothing John can act on. The titles do,
            // and they are the reason the widget is a list rather than a badge
            // -- so the count carries two or three of them even when the rows
            // themselves are collapsed or scrolled out of sight.
            if let preview = headerPreviewText {
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

    /// The zero-sized buttons that carry the command shortcuts: a
    /// MenuBarExtra window has no menu bar of its own to hang them off, and
    /// onKeyPress does not see a command-modified key the menu system claims
    /// first, so the shortcut has to belong to a real (if invisible) button.
    /// Its own property so `body`'s modifier chain stays inside the
    /// type-checker's budget.
    private var shortcutButtons: some View {
        VStack(spacing: 0) {
            Button("", action: toggleSearch)
                .keyboardShortcut("f", modifiers: .command)
            Button("", action: { controller.showSettings() })
                .keyboardShortcut(",", modifiers: .command)
            // Mode-select and one-shot-fire, all command-modified: same
            // reason as ⌘F/⌘, above, a hidden button rather than onKeyPress.
            // Each checks fieldFocused itself so the shortcut only fires
            // while quick-fire's own field owns the keystroke.
            Button("", action: { selectMode(toPass: false) })
                .keyboardShortcut("1", modifiers: .command)
            Button("", action: { selectMode(toPass: true) })
                .keyboardShortcut("2", modifiers: .command)
            Button("", action: fireOtherMode)
                .keyboardShortcut(.return, modifiers: .command)
            // Q11 (slice 5): the seam Q12 left open. ⌥⏎ opens the "Remind me
            // instead" picker over the typed words -- POST /asks mode
            // "remind", an H12 hub's todo-with-a-time; a hub that has not
            // built it answers in its own words on the field's refusal line.
            // ⌘D opens the hub's desk. Same hidden-button trick, same reason:
            // onKeyPress never sees a command- or option-modified key.
            Button("", action: openRemindPicker)
                .keyboardShortcut(.return, modifiers: .option)
            Button("", action: openDesk)
                .keyboardShortcut("d", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// The ask board's own header facts, nil whenever the feed is not
    /// speaking asks -- one read so the header, the footer, and the list all
    /// agree on which menu is up.
    private var liveAskBoard: AskBoard? {
        guard let board = controller.askBoard, board.speaksAsks else { return nil }
        return board
    }

    /// Whether the menu is currently drawing ask rows (Q3) rather than the
    /// legacy task sections.
    private var asksLive: Bool { liveAskBoard != nil }

    /// The search field's count: how many rows the query kept, whichever feed
    /// is live. Sections and suggestions included, since the question is "how
    /// much is hidden", not "how much is visible".
    private var matchedRowCount: Int {
        if let board = liveAskBoard {
            return AskFilter.apply(board.rows, query: search).count
        }
        return model.records.count + model.suggestions.count
    }

    private var headerDot: Color {
        if let board = liveAskBoard {
            if board.badge > 0 { return .orange }
            if board.counts.working > 0 { return .green }
            return .secondary.opacity(0.5)
        }
        return Color(StatusPalette.color(for: controller.model.aggregate))
    }

    private var headerHeadline: String {
        if let board = liveAskBoard { return board.headline }
        return controller.model.headlineText
    }

    private var headerPreviewText: String? {
        if let board = liveAskBoard {
            let titles = board.headlinePreview()
            return titles.isEmpty ? nil : titles.joined(separator: " \u{00B7} ")
        }
        return headlinePreview
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
            // Q3's footer stub, on the ask menu only: the plan's fixed words
            // for the two things slice 5 wires (⌘F find across every ask,
            // ⌘D the desk). Saying them now, unbound, keeps the shape of the
            // footer honest while the verbs are still Q11's to land.
            if liveAskBoard != nil {
                Text(AskFooter.stub)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help("\u{2318}F finds across every ask ever; \u{2318}D opens the desk.")
            }
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

    /// The transient interaction state a fresh summon, or a closing panel,
    /// has to start clean from: no row highlighted, no suggestion mid-confirm.
    /// Without this, a highlight set on an earlier visit sat there once
    /// quick-fire's field regained focus on the next summon, and Return acted
    /// on that stale row instead of reaching the field's own `.onSubmit` --
    /// see `KeyboardNav.returnTarget`, which is the other half of the fix.
    private func resetKeyboardState() {
        highlighted = KeyboardNav.summonReset()
        confirmingSuggestion = nil
        // A move line from an earlier visit is not carried into the next
        // one: the dropdown tears down on close anyway (state lost with it),
        // so the cached summon panel starting equally clean is the same
        // rule, not a second one. Same for a row editor left open (Q9).
        askMoveLine = nil
        askEdit = nil
        askFieldFocused = false
        // And for the two Q11 overlays: no picker left half-typed, no find
        // left open on a query from some other visit.
        remindPick = nil
        remindPickError = nil
        closeFind()
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
    ///
    /// Q12: the second mode is Ask me first. It POSTs `/asks` with
    /// `{text, mode: "ask_first", door, dir}` -- the prefix parsed and
    /// stripped, the resolved directory sent along -- and a hub that answers
    /// 501/404 (creation not built yet, or a hub that predates the route)
    /// gets today's `/capture` To-Pass path with the raw unstripped text
    /// instead, byte for byte. Run now is exactly the fire it has always
    /// been; what it leaves behind is new -- the receipt, with its Undo.
    private func fire(rawText: String, toPass: Bool) {
        fireState = .firing(toPass: toPass)
        // A new fire supersedes whatever the last one left: the receipt's
        // Undo belongs to the words on screen, not the words before them.
        askReceipt = nil
        // The standalone summon panel is the only host that ever closes
        // itself on a successful fire; the real dropdown never does. This
        // is the same "am I the panel" signal `clearDraft()` already uses
        // for Escape.
        let isPanel = onEscapeExhausted != nil
        let (prefixDir, stripped) = FireResolve.parsePrefix(rawText)
        let resolved = FireResolve.runDirectory(prefixDir: prefixDir, settings: controller.settings)
        if toPass {
            let base = controller.passBase
            // The outcome travels as "route:id" -- perform's report closure
            // is typed for a plain String, and the two facts the landing
            // needs (which route, which id) are exactly these.
            controller.perform(key: "askFirst", {
                Actions.askFirst(text: stripped, rawText: rawText,
                                 dir: resolved.url, base: base).map { "\($0.route):\($0.id ?? "")" }
            }) { outcome in
                let (state, hidesPanel): (FireFieldState, Bool)
                switch outcome {
                case .failure(let problem):
                    (state, hidesPanel) = (.failure(problem.message), false)
                case .success(let tag) where tag.hasPrefix("asks:"):
                    let id = String(tag.dropFirst("asks:".count))
                    landReceipt(AskReceipt(kind: .askFirst, words: stripped,
                                           firedAt: Date(), askID: id.isEmpty ? nil : id))
                    (state, hidesPanel) = (.success(AskReceipt.askFirstLine), isPanel)
                case .success(let tag) where tag.hasPrefix("capture:"):
                    // The fallback leg lands exactly as the To-Pass fire
                    // always did -- same wording, same panel decision -- so
                    // an older hub changes nothing about what John sees.
                    let captured = String(tag.dropFirst("capture:".count))
                    (state, hidesPanel) = FireFieldOutcome.describe(
                        result: .success(captured), toPass: true,
                        displayText: rawText, isPanel: isPanel)
                case .success:
                    (state, hidesPanel) = (.failure("the ask came back unlabelled"), false)
                }
                postFireOutcome(state)
                settle(state, hidesPanel: hidesPanel)
            }
        } else {
            controller.perform(key: "fire", {
                Actions.fire(prompt: stripped, in: resolved.url,
                            origin: isPanel ? "summon" : "widget").map { "" }
            }) { outcome in
                if case .success = outcome {
                    landReceipt(AskReceipt(kind: .runNow, words: stripped,
                                           firedAt: Date(), askID: nil))
                }
                let (state, hidesPanel) = FireFieldOutcome.describe(
                    result: outcome, toPass: false, displayText: stripped, isPanel: isPanel)
                postFireOutcome(state)
                settle(state, hidesPanel: hidesPanel)
            }
        }
    }

    /// Lands a fire's receipt: holds it for the undo window, and gets the
    /// board and the Ask-again list moving so both reflect the fire that
    /// just happened (the controller's own post-action refresh covers the
    /// board; the recents are the field's own fetch).
    private func landReceipt(_ receipt: AskReceipt) {
        askReceipt = receipt
        controller.refreshAsks()
        fetchRecentAsks()
    }

    /// The receipt's Undo (Q12): stop the run if one is live, then drop the
    /// ask. For a Run-now receipt the ask id is resolved off the board at
    /// click time -- the fire knew no id, only the words -- so the board is
    /// read first; an Ask-me-first receipt already carries the id its POST
    /// created. The drop is skipped when no hub is configured (the file
    /// fallback has no move route), and the outcome says what happened in
    /// either case.
    private func undoReceipt() {
        guard let receipt = liveReceipt, !undoingReceipt else { return }
        let board = controller.askBoard
        let id = receipt.askID
            ?? board.flatMap { AskReceipt.resolveAskID(in: $0.rows.map(\.ask), words: receipt.words) }
        guard let id else {
            controller.post(kind: .error,
                            title: "Cannot undo",
                            detail: "The fired ask is not on the board to stop.")
            return
        }
        // Nothing to stop unless the board says the ask is still running or
        // queued -- an Ask-me-first ask never ran, and a Run-now ask that
        // already finished has nothing stoppable left.
        let running = board?.row(id: id)
            .map { $0.ask.state == .working || $0.ask.state == .heard } ?? false
        undoingReceipt = true
        let base = askClientBase()
        DispatchQueue.global(qos: .userInitiated).async {
            var stopMessage: String?
            if running {
                switch Actions.stopQtTask(askID: id) {
                case .success: break
                case .failure(let problem): stopMessage = problem.message
                }
            }
            var dropMessage: String?
            var dropped = false
            if let base {
                let result = AskClient(base: base).post(id: id, move: "drop")
                dropped = result.ok
                if !result.ok { dropMessage = result.message }
            }
            DispatchQueue.main.async {
                undoingReceipt = false
                if stopMessage == nil, dropMessage == nil {
                    askReceipt = nil
                    // "stopped and dropped" only when both halves ran; with
                    // no hub to drop against, stopping is the whole undo.
                    controller.post(kind: .info,
                                    title: dropped ? "Undone: stopped and dropped" : "Undone")
                } else {
                    controller.post(kind: .error, title: "Undo did not finish",
                                    detail: [stopMessage, dropMessage]
                                        .compactMap { $0 }.joined(separator: " \u{00B7} "))
                }
                controller.refreshAsks()
            }
        }
    }

    /// Q12: the Ask-again list -- recent done asks, newest first, straight
    /// off the hub (`place=done` pages newest first per 1.6). Fetched when a
    /// board appears and after every successful fire, never from a `body`
    /// read. The file fallback has no done-list endpoint, so there is
    /// nothing to fetch when the feed is not the ask API.
    private func fetchRecentAsks() {
        guard controller.askFeed?.source == .asks,
              let base = askClientBase(), !recentAsksLoading else { return }
        recentAsksLoading = true
        DispatchQueue.global(qos: .utility).async {
            let result = AskClient(base: base).list(place: "done", limit: 8)
            DispatchQueue.main.async {
                recentAsksLoading = false
                if case .success(.list(let list)) = result {
                    recentAsks = list.asks
                }
            }
        }
    }

    /// A click on an Ask-again row: the ask's own words land in the field
    /// and the field takes focus, so re-firing a recent ask's words is one
    /// more Enter -- in whichever mode the fire is set to -- rather than a
    /// blind re-run fired from a row John only meant to read.
    private func askAgain(_ ask: Ask) {
        let words = ask.words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        draft = words
        fireState = .idle
        focusQuickFireField()
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
            if hidesPanel {
                resetKeyboardState()
                onEscapeExhausted?()
            }
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

    /// Peek panel's Open result: RESULT.md off disk first (`qt open <id>``'s
    /// artifact), then the rendered report, then the Pass item page -- a
    /// dead click is never the outcome.
    private func openResult(_ record: TaskRecord) {
        if case .success = Actions.openResult(record: record,
                                              hubJobsDir: controller.config.hubJobsDir) {
            return
        }
        if record.hasReport {
            openReport(record)
        } else {
            openItem(record)
        }
    }

    private func copyResult(_ record: TaskRecord) {
        let text = (record.error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Actions.copyToPasteboard(text)
        // The field holds the error on failed rows, the result body on
        // successful ones -- name the toast accordingly (2026-11-03 review).
        let isError = record.status == .failed || record.status == .timeout
        controller.post(kind: .info, title: isError ? "Error copied" : "Result copied")
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

    /// LD-224: sends a delivered row back to Verify through `POST /revive`.
    /// Only ever called from a button gated on `record.revivable`, so a 404
    /// (an older hub with no such route) just reports as a normal error
    /// rather than needing header-line treatment the way /run's 409 does.
    private func revive(_ record: TaskRecord) {
        let base = controller.passBase
        controller.perform(key: record.id, {
            Actions.revive(record: record, base: base)
        }) { outcome in
            switch outcome {
            case .success:
                controller.post(kind: .ok, title: "Revived: \(record.title)")
            case .failure(let problem):
                controller.post(kind: .error, title: "Couldn't revive", detail: problem.message)
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

    // MARK: - yours, remind, find, desk (Q11)

    /// The yours section's rows: the feed's yours-place asks -- John's own
    /// to-dos, no live agent work -- which AskSections keeps out of the
    /// three action sections. Built from the feed the controller polled (the
    /// board holds only those sections), pure over the same rows the hub
    /// sent, by the same builder the `--ask-dump-rows` seam reports.
    private var yoursRows: [YoursRowModel] {
        guard asksLive, let feed = controller.askFeed else { return [] }
        return AskYours.rows(in: feed.asks)
    }

    /// A yours row's title click and ⏎: the ask's one address, always --
    /// the same rule every other row opens by.
    private func openYours(_ row: YoursRowModel) {
        guard let url = row.openURL else {
            controller.post(kind: .error, title: "This ask has no address",
                            detail: "The hub is down; the row shows what the ledger knows.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// One bare key against the highlighted yours row (E done, R remind,
    /// D drop), resolved the same way the action rows' keys are: the hub's
    /// own `moves` list gates every one.
    private func yoursKeyTarget(_ key: String) -> (id: String, button: AskMoveButton)? {
        guard asksLive, let id = highlighted,
              let row = yoursRows.first(where: { $0.id == id }) else { return nil }
        guard let button = YoursMoves.target(ask: row.ask, key: key) else { return nil }
        return (row.id, button)
    }

    /// Runs one yours row's button: a plain move posts straight out (the
    /// shared verdict line lands under the row), and Remind opens the same
    /// picker ⌥⏎ opens, prefilled with the reminder the row already carries.
    /// Copy/open are not offered here -- a yours row has no answer to copy,
    /// and its title already opens.
    private func performYoursButton(_ button: AskMoveButton, id: String) {
        switch button.act {
        case .post(let move):
            postAskMove(id: id, move: move)
        case .text(let move, _) where move == "remind":
            openRowRemindPicker(id: id)
        case .text:
            // No other text move is on a yours row's list (YoursMoves emits
            // none), so there is nothing here to send -- and no button to
            // dead-end, because the row never drew one.
            break
        case .copyAnswer, .openThread:
            break
        }
    }

    /// Opens the ⌥⏎ picker over the field's typed words -- the seam Q12's
    /// comment left for this unit. Same guards as the one-shot ⌘⏎ fire: the
    /// field owns the keystroke, nothing is firing, and there are words.
    private func openRemindPicker() {
        guard fieldFocused, !fireState.isFiring else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        remindPickError = nil
        remindPick = RemindPick(target: .field(text))
        remindSpecFocused = true
    }

    /// Opens the picker for one yours row's `remind` move, prefilled with
    /// the time that row already carries so adjusting a reminder is a
    /// one-keystroke edit, not a re-entry.
    private func openRowRemindPicker(id: String) {
        guard let row = yoursRows.first(where: { $0.id == id }) else { return }
        remindPickError = nil
        remindPick = RemindPick(target: .row(id),
                                spec: row.remindDate.map(RemindTime.text(for:)) ?? "")
        remindSpecFocused = true
    }

    /// The picker itself: a time field, the three presets a person means by
    /// "later", return to send, x to leave everything as it was.
    @ViewBuilder private func remindPicker(_ pick: RemindPick) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("At 3:00 PM, in 2h, tonight, tomorrow 9a\u{2026}", text: Binding(
                    get: { remindPick?.spec ?? "" },
                    set: { if remindPick != nil { remindPick?.spec = $0 } }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($remindSpecFocused)
                    .onSubmit(submitRemind)
                ForEach(Self.remindPresets, id: \.spec) { preset in
                    Button(preset.label) {
                        remindPick?.spec = preset.spec
                        remindSpecFocused = true
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                RowButton(icon: "arrow.up.circle", help: "Set the reminder (\u{23CE})") {
                    submitRemind()
                }
                RowButton(icon: "xmark", help: "Cancel (Esc)") {
                    remindPick = nil
                    remindPickError = nil
                }
            }
            if let error = remindPickError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.red)
                    .lineLimit(2)
            }
        }
        .help("Remind me instead: the words become a to-do of yours that "
              + "nudges you at the time typed here. \"none\" clears a row's "
              + "existing reminder.")
    }

    /// The picker's presets: the three distances a reminder usually means.
    private static let remindPresets: [(label: String, spec: String)] = [
        ("1h", "in 1 hour"),
        ("Tonight", "tonight"),
        ("Tomorrow 9a", "tomorrow 9a"),
    ]

    /// The picker's send. An empty time is not a refusal -- it is the
    /// default the placeholder promises, one hour from now. An unreadable
    /// one keeps the picker open and says so in place; nothing posts until
    /// a time parsed. On a yours row, "none" clears the reminder instead.
    private func submitRemind() {
        guard let pick = remindPick else { return }
        let spec = pick.spec.trimmingCharacters(in: .whitespacesAndNewlines)
        let at: Date?
        if spec.isEmpty {
            at = Date().addingTimeInterval(3600)
        } else if RemindTime.isClear(spec) {
            guard case .row = pick.target else {
                remindPickError = "Type a time, or leave it empty for one hour from now."
                return
            }
            at = nil
        } else if let parsed = RemindTime.parse(spec, now: Date()) {
            at = parsed
        } else {
            remindPickError = "Couldn't read \u{201C}\(spec)\u{201D} as a time -- "
                + "try 3p, 15:30, in 2h, tonight, tomorrow 9a."
            return
        }
        switch pick.target {
        case .field(let words): postFieldRemind(words: words, at: at ?? Date().addingTimeInterval(3600))
        case .row(let id): postRowRemind(id: id, at: at)
        }
    }

    /// The picker's write for the field's words: POST /asks mode "remind",
    /// exactly the fire's own shape -- the prefix parsed and stripped, the
    /// resolved directory sent along. A refusal lands on the field's
    /// failure line in the hub's own words, draft intact; a success lands
    /// as the receipt's honest cousin and clears the field the way a landed
    /// fire does.
    private func postFieldRemind(words: String, at: Date) {
        remindPick = nil
        remindPickError = nil
        guard let base = askClientBase() else {
            controller.post(kind: .error, title: "Cannot set a reminder",
                            detail: "The Pass feed is off; there is no hub to hold the to-do.")
            return
        }
        let isPanel = onEscapeExhausted != nil
        let (prefixDir, stripped) = FireResolve.parsePrefix(words)
        let resolved = FireResolve.runDirectory(prefixDir: prefixDir, settings: controller.settings)
        controller.perform(key: "askRemind", {
            let result = Actions.remind(text: stripped, dir: resolved.url, remindAt: at, base: base)
            return result.ok ? .success(result.ask?.id ?? "")
                             : .failure(Problem(result.message))
        }) { outcome in
            switch outcome {
            case .success:
                let line = "Got it. It will nudge you at \(RemindTime.text(for: at))."
                postFireOutcome(.success(line))
                controller.refreshAsks()
                settle(.success(line), hidesPanel: isPanel)
            case .failure(let problem):
                // The hub's own words -- a 501's "creating an ask is not
                // built yet" -- on the field's refusal line, never a dead
                // button, and no capture fallback to turn a refused
                // reminder into a silently different thing.
                postFireOutcome(.failure(problem.message))
                fireState = .failure(problem.message)
            }
        }
    }

    /// The picker's write for a yours row: the `remind` move, `{at}` -- nil
    /// clears -- landing the same verdict line every other move leaves.
    private func postRowRemind(id: String, at: Date?) {
        remindPick = nil
        remindPickError = nil
        guard let base = askClientBase() else {
            controller.post(kind: .error, title: "Cannot set a reminder",
                            detail: "The Pass feed is off; there is no hub to hold it.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Actions.remindMove(id: id, at: at, base: base)
            DispatchQueue.main.async {
                landMoveLine(id: id, move: "remind", result: result)
            }
        }
    }

    /// ⌘D: the hub's desk (H9), on the same base every ask read and write
    /// uses -- the menu and the desk can never point at different hubs.
    /// Without a hub there is nothing to open, and the outcome says so
    /// rather than a key that quietly does nothing.
    private func openDesk() {
        guard let base = askClientBase() ?? controller.config.passURL else {
            controller.post(kind: .error, title: "No Pass for the desk",
                            detail: "The desk is served by the hub; the Pass feed is off.")
            return
        }
        NSWorkspace.shared.open(Actions.deskURL(base: base))
    }

    /// ⌘F's open: the find field takes focus, and any local filter still
    /// open steps aside -- the two answer different questions and never
    /// share the panel.
    private func openFind() {
        findOpen = true
        findFocused = true
        fieldFocused = false
        if searching {
            searching = false
            search = ""
            searchFocused = false
        }
    }

    /// ⌘F's close: results, message, and any highlight on a result row go
    /// with it, so the sections come back exactly as they were.
    private func closeFind() {
        findDebounce?.cancel()
        findTick += 1
        findOpen = false
        findQuery = ""
        findResults = nil
        findMessage = nil
        findLoading = false
        findFocused = false
        // A highlight sitting on a result row must not survive into the
        // sections: the row under that id may be a different ask now.
        highlighted = nil
    }

    private var trimmedFindQuery: String {
        findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The find query, asked of the hub on a debounce (see the onChange in
    /// `body`). Stale answers cannot land: each fetch carries the tick it
    /// was issued under, and only the newest one draws.
    private func fetchFind() {
        guard let base = askClientBase() else {
            findLoading = false
            findMessage = "The Pass feed is off; there is nothing to search."
            return
        }
        let query = trimmedFindQuery
        guard !query.isEmpty else { return }
        findLoading = true
        findTick += 1
        let tick = findTick
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Actions.searchAsks(base: base, query: query)
            DispatchQueue.main.async {
                guard tick == findTick else { return }
                findLoading = false
                switch result {
                case .success(let hits):
                    findResults = hits
                    findMessage = nil
                case .failure(let problem):
                    findResults = nil
                    findMessage = problem.message
                }
            }
        }
    }

    /// Return in the find field: opens the highlighted result, or the first
    /// when no arrow has moved the highlight yet -- the same one-match-
    /// is-unambiguous rule submitSearch has always had.
    private func submitFind() {
        guard let hits = findResults, !hits.isEmpty else { return }
        let id = highlighted ?? hits.first?.id
        if let hit = hits.first(where: { $0.id == id }) {
            openFindHit(hit)
        }
    }

    private func openFindHit(_ hit: AskSearchHit) {
        guard let url = hit.ask.url.flatMap(URL.init(string:)) else { return }
        NSWorkspace.shared.open(url)
    }

    /// The eye on a find result: the same one-peek-at-a-time expand the
    /// section rows use, through the same thread cache and the same `seen`
    /// rule -- a found unseen answer stops counting toward the badge the
    /// moment it is read here too.
    private func toggleFindExpand(_ hit: AskSearchHit) {
        // The row model the expand machinery reads. The section field is
        // inert bookkeeping here -- AskSection has no find case, and none is
        // needed: nothing downstream reads it, the section a find result
        // draws in is the find list itself.
        let row = AskRowModel(ask: hit.ask, section: .needsYou)
        if expandedID == row.id {
            expandedID = nil
        } else {
            expandedID = row.id
            expand(row)
        }
    }

    /// The find results as the row list (Q11): one row per found ask, drawn
    /// in the same measured, capped scroll the sections use.
    @ViewBuilder private var findList: some View {
        if let message = findMessage {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        } else if findLoading, findResults == nil {
            Text("Searching\u{2026}")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        } else if let hits = findResults {
            if hits.isEmpty {
                Text("No ask matches \u{201C}\(trimmedFindQuery)\u{201D}")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(hits) { hit in
                            FindRowView(
                                hit: hit,
                                highlighted: highlighted == hit.id,
                                expanded: expandedID == hit.id,
                                loading: askLoadingThreads.contains(hit.id),
                                thread: askThreads[hit.id],
                                moveLine: askMoveLine?.id == hit.id ? askMoveLine?.line : nil,
                                onTitle: { openFindHit(hit) },
                                onToggleExpand: { toggleFindExpand(hit) })
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ListHeightKey.self,
                                                   value: geo.size.height)
                        }
                    )
                }
                .frame(height: renderedListHeight)
                .onPreferenceChange(ListHeightKey.self) { measured in
                    if abs(measured - listHeight) > 0.5 { listHeight = measured }
                }
            }
        }
    }

    // MARK: - asks (Q3)

    /// Spends the snapshot seam's `--expand <id-substring>` on the first
    /// board that can satisfy it: highlight the row and open its peek, so a
    /// snapshot can show the answer in place without a click. The board is
    /// the controller's (Q6); this runs when a board lands and when a view
    /// appears over one that already had.
    private func consumePreexpand() {
        guard let needle = preexpand,
              let board = controller.askBoard,
              let row = board.row(matching: needle) else { return }
        preexpand = nil
        highlighted = row.id
        expandedID = row.id
        expand(row)
    }

    /// The eye button on an ask row: one peek at a time, same gesture (and
    /// the same `expandedID`) the legacy rows' peek panel uses.
    private func toggleExpand(_ row: AskRowModel) {
        if expandedID == row.id {
            expandedID = nil
        } else {
            expandedID = row.id
            expand(row)
        }
    }

    /// Expanding a row reads the answer where it is: the thread off the hub
    /// (cached per id + updated_at by AskClient), shown in place. A row
    /// still unseen posts `seen` once its answer is actually on screen --
    /// that is the move that stops it counting toward the badge, and doing
    /// it before the text landed would clear the dot on a row that was never
    /// read.
    private func expand(_ row: AskRowModel) {
        let plan = AskExpand.plan(ask: row.ask, source: controller.askFeed?.source ?? .files)
        guard plan.fetchThread, let base = askClientBase(),
              askThreads[row.id] == nil,
              !askLoadingThreads.contains(row.id) else { return }
        askLoadingThreads.insert(row.id)
        AskClient(base: base).threadAsync(id: row.id, updatedAt: row.ask.updatedAt) { result in
            askLoadingThreads.remove(row.id)
            switch result {
            case .success(let thread):
                askThreads[row.id] = thread
                if plan.postSeen { postSeen(row) }
            case .failure:
                // The peek falls back to the row's excerpt; `seen` is not
                // posted, so the unseen dot and the badge both stay honest.
                break
            }
        }
    }

    private func postSeen(_ row: AskRowModel) {
        guard let base = askClientBase() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = AskClient(base: base).post(id: row.id, move: "seen")
        }
    }

    /// ⏎ and the title click: the ask's one address, always. Never gated,
    /// never dimmed -- reading a thread is the one thing every ask allows.
    private func openAsk(_ row: AskRowModel) {
        guard let url = row.openURL else {
            controller.post(kind: .error, title: "This ask has no address",
                            detail: "The hub is down; the row shows what the ledger knows.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Z: spends the undo token the last move left. Any row's token, not
    /// only the highlighted one's -- undoing is about the write, and the
    /// write named its row in the line.
    private func undoAsk() {
        guard let pending = askMoveLine, let token = pending.token, !token.isEmpty,
              let base = askClientBase() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AskClient(base: base).post(id: pending.id, move: "undo",
                                                    body: ["token": token])
            DispatchQueue.main.async {
                if result.ok {
                    askMoveLine = nil
                    controller.refreshAsks()
                } else {
                    askMoveLine = (pending.id, AskMoveLine.undo(result), nil)
                }
            }
        }
    }

    /// Whether the Z key currently has a token to spend.
    private var zActsOnAsk: Bool {
        guard let token = askMoveLine?.token else { return false }
        return !token.isEmpty
    }

    private func pressZ() -> KeyPress.Result {
        guard !fieldFocused, !searchFocused, !askFieldFocused, zActsOnAsk else { return .ignored }
        undoAsk()
        return .handled
    }

    // MARK: - asks: moves in the row (Q9)

    /// Resolves one bare key against the highlighted ask row: the same
    /// `AskKeys.target` the seam drives, so a key can never mean one thing
    /// in a test and another in the menu. The focus guard lives in the
    /// letter handler, which is what keeps this lookup from ever running
    /// while a field owns the keystroke.
    private func askKeyTarget(_ key: String) -> (row: AskRowModel, button: AskMoveButton)? {
        guard asksLive, let board = controller.askBoard,
              let id = highlighted, let row = board.row(id: id) else { return nil }
        guard let button = AskKeys.target(ask: row.ask, key: key, fieldHasFocus: false) else {
            return nil
        }
        return (row, button)
    }

    /// Runs one row button: a plain move posts straight out, a text move
    /// opens the row's editor, copy lands the answer on the pasteboard,
    /// open goes to the ask's one address. Every path is one click; the two
    /// that ask for words first open the field instead of posting blind.
    private func performAskButton(_ button: AskMoveButton, on row: AskRowModel) {
        switch button.act {
        case .post(let move):
            postAskMove(id: row.id, move: move)
        case .text(let move, _):
            openEditor(row: row, move: move)
        case .copyAnswer:
            copyAskAnswer(row)
        case .openThread:
            openAsk(row)
        }
    }

    /// Opens the row's editor for a text move, prefilled per the plan: a
    /// try-with-changes opens on the original words, everything else empty.
    private func openEditor(row: AskRowModel, move: String) {
        askEdit = AskEditState(id: row.id, move: move,
                               bodyKey: AskRowMoves.bodyKey(for: move),
                               text: AskRowMoves.prefill(for: row.ask, move: move) ?? "")
    }

    private func cancelEdit() {
        askEdit = nil
        askFieldFocused = false
    }

    /// Submits the open editor: its move, with the field's words under the
    /// move's own body key. An empty field submits nothing -- an empty
    /// follow-up is a slip of the return key, not a move.
    private func submitEdit(_ text: String) {
        guard let edit = askEdit else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        askEdit = nil
        askFieldFocused = false
        guard liveAskBoard?.row(id: edit.id) != nil else { return }
        postAskMove(id: edit.id, move: edit.move, text: (key: edit.bodyKey, value: trimmed))
    }

    /// Posts one move and lands its verdict line under the row -- the same
    /// line E has always left, generalized to every write: the hub's own
    /// undo token becomes "Z to undo", its refusal (409, 501, 503) becomes
    /// its own words, never a dead button. Id-keyed (Q11) so the yours
    /// section's rows -- which are not AskRowModels -- land the same line
    /// through the same code.
    private func postAskMove(id: String, move: String,
                             text: (key: String, value: String)? = nil) {
        guard let base = askClientBase() else { return }
        var body: [String: Any] = [:]
        if let text { body[text.key] = text.value }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AskClient(base: base).post(id: id, move: move, body: body)
            DispatchQueue.main.async {
                landMoveLine(id: id, move: move, result: result)
            }
        }
    }

    /// Copy C: the answer as the row can read it -- the thread's full text
    /// once it is in hand (fetching it if it is not), the excerpt as the
    /// fallback, and an honest nothing when neither exists.
    private func copyAskAnswer(_ row: AskRowModel) {
        if let thread = askThreads[row.id], !thread.answerText.isEmpty {
            Actions.copyToPasteboard(thread.answerText)
            controller.post(kind: .info, title: "Answer copied")
            return
        }
        guard let base = askClientBase() else {
            copyAskExcerpt(row)
            return
        }
        AskClient(base: base).threadAsync(id: row.id, updatedAt: row.ask.updatedAt) { result in
            switch result {
            case .success(let thread) where !thread.answerText.isEmpty:
                askThreads[row.id] = thread
                Actions.copyToPasteboard(thread.answerText)
                controller.post(kind: .info, title: "Answer copied")
            default:
                copyAskExcerpt(row)
            }
        }
    }

    private func copyAskExcerpt(_ row: AskRowModel) {
        guard let excerpt = row.ask.answerExcerpt, !excerpt.isEmpty else {
            controller.post(kind: .info, title: "No answer text to copy")
            return
        }
        Actions.copyToPasteboard(excerpt)
        controller.post(kind: .info, title: "Copied the excerpt")
    }

    /// Lands a move's verdict under the row: the undo line when the hub
    /// handed back a token, its own words when it refused. A refusal also
    /// posts to the outcome queue -- the panel can close mid-read, and a
    /// refused write is the one thing worth following the user out of the
    /// menu.
    private func landMoveLine(id: String, move: String, result: MoveResult) {
        let line = AskMoveLine.line(move: move, result: result)
        askMoveLine = (id, line, result.undo?.token)
        if result.ok {
            controller.refreshAsks()
        } else {
            controller.post(kind: .error, title: line)
        }
    }

    /// Where ask reads and writes go: the controller's own base (Q6, the
    /// rule that used to live here) -- the URL the ask feed itself was read
    /// from, so the two can never point at different hubs.
    private func askClientBase() -> URL? { controller.askBaseURL }

    // MARK: - ask list (Q3)

    /// The ask menu's row list: the plan's sections in order -- New for you
    /// (unseen answers), Needs you, Working -- inside the same measured,
    /// capped scroll the legacy list uses.
    private func askList(_ board: AskBoard) -> some View {
        Group {
            if board.sections.isEmpty || visibleIDs.isEmpty {
                Text(search.isEmpty ? "No asks yet"
                                    : "Nothing matches \u{201C}\(search)\u{201D}")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(board.sections, id: \.section) { entry in
                            AskSectionHeader(section: entry.section, count: entry.rows.count)
                            ForEach(AskFilter.apply(entry.rows, query: search)) { row in
                                // The row's open editor, when it is this
                                // row's: the move its field feeds and the
                                // binding into the field's own text.
                                let edit = askEdit?.id == row.id ? askEdit : nil
                                AskRowView(
                                    row: row,
                                    highlighted: highlighted == row.id,
                                    expanded: expandedID == row.id,
                                    loading: askLoadingThreads.contains(row.id),
                                    thread: askThreads[row.id],
                                    moveLine: askMoveLine?.id == row.id ? askMoveLine?.line : nil,
                                    editing: edit.map { (move: $0.move, bodyKey: $0.bodyKey) },
                                    editText: edit.map { _ in Binding(
                                        get: { askEdit?.text ?? "" },
                                        set: { if askEdit != nil { askEdit?.text = $0 } }) },
                                    onTitle: { openAsk(row) },
                                    onToggleExpand: { toggleExpand(row) },
                                    onButton: { button in performAskButton(button, on: row) },
                                    onAnswer: { text in
                                        postAskMove(id: row.id, move: "follow_up",
                                                    text: (key: "text", value: text))
                                    },
                                    onEditSubmit: submitEdit,
                                    onEditCancel: cancelEdit,
                                    onFieldFocus: { askFieldFocused = $0 })
                            }
                        }
                        // Q11: "Yours today" -- the feed's yours-place asks,
                        // the ones AskSections keeps out of the three action
                        // sections, in their own section under them: the
                        // plan's slice-5 addition to the menu's shape.
                        let yours = yoursRows.filter { AskFilter.matches($0.ask, query: search) }
                        if !yours.isEmpty {
                            YoursSectionHeader(count: yours.count)
                            ForEach(yours) { row in
                                YoursRowView(
                                    row: row,
                                    highlighted: highlighted == row.id,
                                    moveLine: askMoveLine?.id == row.id ? askMoveLine?.line : nil,
                                    onTitle: { openYours(row) },
                                    onButton: { button in performYoursButton(button, id: row.id) })
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
                .frame(height: renderedListHeight)
                .onPreferenceChange(ListHeightKey.self) { measured in
                    if abs(measured - listHeight) > 0.5 { listHeight = measured }
                }
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
    /// True when the section holds at least one finished/read-able row.
    var clearable: Bool = false
    let onToggle: () -> Void
    /// Slack-unread-style "mark this section read"; nil hides the affordance.
    var onClear: (() -> Void)? = nil

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
        .overlay(alignment: .trailing) {
            // A sibling of the toggle button, not a child: nested buttons
            // swallow each other's clicks. Sits left of the count, hover-only.
            if clearable, let onClear, hovering {
                Button("Clear", action: onClear)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .buttonStyle(.plain)
                    .padding(.trailing, 26)
                    .help("Mark this section read (rows stay in the ledger)")
            }
        }
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
    /// The peek panel (2026-11-03): result text + Open/Copy/Resume inline,
    /// so a finished quickfire can be read without leaving the menu.
    var expanded: Bool = false
    let onResume: () -> Void
    let onReport: () -> Void
    let onTitle: () -> Void
    let onRun: () -> Void
    let onRevive: () -> Void
    let onDecide: (_ action: String, _ comment: String) -> Void
    let onToggleExpand: () -> Void
    let onOpenResult: () -> Void
    let onCopyResult: () -> Void

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
                        // The eye is every row's first affordance: peek at
                        // the result without leaving the menu.
                        RowButton(icon: expanded ? "chevron.up" : "eye",
                                  help: expanded ? "Hide the result" : "Peek at the result",
                                  action: onToggleExpand)
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

            if expanded {
                peekPanel
            }

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

    /// The peek panel's text: the qt ledger maps a task's result body onto
    /// `error` (a naming accident worth knowing before trusting it), so
    /// quickfire rows have their full result here; Pass-feed rows carry no
    /// result text in /status.json and get the fallback line instead.
    private var peekText: String {
        (record.error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var peekPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if peekText.isEmpty {
                Text("No result text on this row -- Open result reads the artifact, or open it in The Pass.")
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(.tertiary)
            } else {
                Text(peekText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Button("Open result", action: onOpenResult)
                if !peekText.isEmpty {
                    Button("Copy", action: onCopyResult)
                }
                if record.canResume {
                    Button("Resume", action: onResume)
                }
                Spacer()
            }
            .font(.system(size: 11))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .padding(.leading, 27)
        .padding(.trailing, 12)
        .padding(.bottom, 7)
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
        // LD-224: offered only when the hub says this delivered row will
        // still take a revive -- an older hub that never sends `revivable`
        // reads as false, same as `canRun`/`canDecide`, so there is no
        // button to 404 against.
        if record.revivable {
            RowButton(icon: "arrow.uturn.backward.circle",
                      help: "Revive: send it back to Verify",
                      action: onRevive)
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

// MARK: - one ask row (Q3)

/// Q12: the plain-words reason a failed row carries under its title -- the
/// hub's `reason` field, one sentence, shown only where the plan pins it
/// ("failed rows show reason"). A reason on any other state is the hub
/// speaking ahead of its own table (blocked rows show their tool chips,
/// working rows their live line), so those keep quiet rather than drawing a
/// stale verdict. An extension rather than a field on AskRowModel so the
/// view and the `--ask-dump-rows` seam read one definition.
extension AskRowModel {
    var reasonLine: String? {
        guard ask.state == .failed,
              let reason = ask.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else { return nil }
        return reason
    }
}

/// An ask section's header. Not a toggle: slice 1 has no collapsed ask
/// sections, because the three sections are short by construction (the hub's
/// default list excludes done, and unseen answers leave "New for you" the
/// moment they are expanded). A quiet label and a count, like the reference's.
struct AskSectionHeader: View {
    let section: AskSection
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            if section == .newForYou {
                Image(systemName: "sparkle")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
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
        .help(section == .newForYou
              ? "Answers you have not read yet. Expanding one clears it from the count."
              : "Open the Pass for the full history.")
    }
}

/// One ask row: the title opens the ask's own address (always -- that is the
/// row's one guaranteed action), the eye expands the answer in place, and
/// the row's tail carries its move buttons -- from the hub's own `moves`
/// list (Q9), so a row offers exactly what the server says it can do. The
/// keyboard highlight and the peek panel are the same affordances the legacy
/// TaskRow has, so the two menus still feel like one widget.
struct AskRowView: View {
    let row: AskRowModel
    var highlighted: Bool = false
    var expanded: Bool = false
    var loading: Bool = false
    var thread: AskThread?
    /// The verdict line a move left under this row (E's undo line, or the
    /// hub's refusal), nil when there is none to draw.
    var moveLine: String?
    /// The row's open editor (Q9): the move its field feeds and that move's
    /// body key, nil when this row is not editing. The field's text itself
    /// is MenuView's `askEdit`, bound in through `editText` so one source
    /// of truth holds it.
    var editing: (move: String, bodyKey: String)? = nil
    var editText: Binding<String>? = nil
    let onTitle: () -> Void
    let onToggleExpand: () -> Void
    /// A tail button (Q9). The inline answer field's submit arrives as
    /// `onAnswer`, the editor's as `onEditSubmit`.
    let onButton: (AskMoveButton) -> Void
    /// The question's inline answer field, submitted.
    let onAnswer: (String) -> Void
    /// The editor's field, submitted.
    let onEditSubmit: (String) -> Void
    let onEditCancel: () -> Void
    /// Whether a field of this row (editor or answer box) has focus, so the
    /// root key handlers can go inert while it does.
    let onFieldFocus: (Bool) -> Void

    /// The peek's answer area: tall enough to read a real answer, short
    /// enough that a long one scrolls inside the row instead of growing the
    /// menu off the screen -- "clipped scroll, max height".
    static let expandMaxHeight: CGFloat = 170

    @State private var hovering = false
    @State private var answerDraft = ""
    @FocusState private var answerFocused: Bool
    @FocusState private var editorFocused: Bool

    /// The buttons that draw in the row's tail (the inline answer field is
    /// drawn under the title instead, so it gets the row's full width).
    private var tailButtons: [AskMoveButton] {
        row.moveButtons.filter { !$0.inline }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Button(action: onTitle) {
                    Text(row.title)
                        .font(.system(size: 12, weight: row.ask.unseen ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                if tailButtons.isEmpty {
                    Text(rightDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    // A row with moves spends its tail on them; the state
                    // word and the age stay one hover away in the tooltip,
                    // where they were always second-choice reading.
                    ForEach(tailButtons) { button in
                        RowButton(icon: button.symbol, help: button.helpText) {
                            onButton(button)
                        }
                    }
                }
                RowButton(icon: expanded ? "chevron.up" : "eye",
                          help: expanded ? "Hide the answer" : "Read the answer here",
                          action: onToggleExpand)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Color.accentColor.opacity(0.18)
                                    : (hovering ? Color.primary.opacity(0.06) : .clear))
            .onHover { hovering = $0 }
            .help(helpText)

            if let now = row.nowLine {
                Text(now)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 27)
                    .padding(.bottom, 3)
            }
            // Q12: the failed row's reason, one line under the title --
            // "Ran out of time after 30 minutes.", in the hub's own words.
            // Draw order (now_line, reason, last attempt, move line,
            // question) is the same order the `--ask-dump-rows` seam reports
            // as `lines`, so the two cannot disagree about what a row shows.
            if let reason = row.reasonLine {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 27)
                    .padding(.trailing, 12)
                    .padding(.bottom, 3)
            }
            if let attempt = row.lastAttempt {
                Text(attempt)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 27)
                    .padding(.bottom, 3)
            }
            if let line = moveLine {
                Text(line)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 27)
                    .padding(.bottom, 3)
            }
            if let question = row.ask.question, !question.isEmpty, row.ask.state == .question {
                Text(question)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 27)
                    .padding(.trailing, 12)
                    .padding(.bottom, 3)
            }
            if row.answersInline {
                answerField
            }
            if let edit = editing, let text = editText {
                editorField(edit, text)
            }
            if expanded {
                peek
            }
        }
    }

    /// A question's one affordance: the answer box right on the row, return
    /// sends it as a follow-up. Its focus makes the panel's keys inert,
    /// which is what lets the answer be typed without R, E, or Z firing
    /// under it.
    private var answerField: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            TextField("Answer it\u{2026}", text: $answerDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($answerFocused)
                .onSubmit { submitAnswer() }
            RowButton(icon: "arrow.up.circle", help: "Send the answer (\u{23CE})") {
                submitAnswer()
            }
        }
        .padding(.leading, 27)
        .padding(.trailing, 12)
        .padding(.bottom, 6)
        .onChange(of: answerFocused) { _, focused in onFieldFocus(focused) }
    }

    private func submitAnswer() {
        let text = answerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        answerDraft = ""
        onAnswer(text)
    }

    /// The editor a text move opens (Follow up, Try with changes): opens on
    /// the move's prefill (the original words, for a redo), return sends
    /// it, and the x leaves the row as it was.
    private func editorField(_ edit: (move: String, bodyKey: String),
                             _ text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            TextField(AskRowMoves.placeholder(for: edit.move), text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($editorFocused)
                .onSubmit { onEditSubmit(text.wrappedValue) }
            RowButton(icon: "arrow.up.circle", help: "Send (\u{23CE})") {
                onEditSubmit(text.wrappedValue)
            }
            RowButton(icon: "xmark", help: "Cancel (Esc)") {
                onEditCancel()
            }
        }
        .padding(.leading, 27)
        .padding(.trailing, 12)
        .padding(.bottom, 6)
        .onAppear { editorFocused = true }
        .onChange(of: editorFocused) { _, focused in onFieldFocus(focused) }
    }

    /// The state word, the age, or both: what the right-hand column says so
    /// the title can stay a title.
    private var rightDetail: String {
        if let a = row.ageText { return "\(row.detail) \u{00B7} \(a)" }
        return row.detail
    }

    /// No colour claim about a state this build cannot read (unknown draws
    /// gray, like the dot); the named states keep the palette the legacy
    /// rows trained.
    private var dotColor: Color {
        switch row.ask.state {
        case .question, .blocked, .failed: return .orange
        case .answer: return row.ask.unseen ? .accentColor : .secondary.opacity(0.6)
        case .working: return .green
        case .wantsOk: return .blue
        default: return .secondary.opacity(0.6)
        }
    }

    /// The peek panel: the thread's answer once the fetch lands, the row's
    /// excerpt when the hub cannot be reached, or an honest nothing with the
    /// way out named.
    private var peek: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Q12: a failed row's peek opens on the reason -- the mockup's
            // "why" line -- before whatever text the run did produce, so the
            // first thing read under a Failed chip is what went wrong.
            if let reason = row.reasonLine {
                Text(reason)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if loading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                    Text("Reading the answer\u{2026}")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    Text(answerText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                }
                // A fixed height, not a cap: see MenuView.listHeight for why
                // a maxHeight alone leaves a ScrollView with no floor.
                .frame(height: Self.expandMaxHeight)
            }
            Text(peekHint)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 27)
        .padding(.trailing, 12)
        .padding(.bottom, 7)
    }

    /// The peek's one-line key hint. ⏎ names what it does on *this* row
    /// (Try with changes on a failed one, the thread otherwise), so the
    /// hint never promises a key something the row overrides.
    private var peekHint: String {
        if let button = AskKeys.returnTarget(ask: row.ask, fieldHasFocus: false),
           case .text = button.act {
            return "\u{23CE} tries it with your changes"
        }
        return "\u{23CE} opens the thread" + (row.canDone ? " \u{00B7} E files it done" : "")
    }

    private var answerText: String {
        if let thread, !thread.answerText.isEmpty { return thread.answerText }
        if let excerpt = row.ask.answerExcerpt, !excerpt.isEmpty { return excerpt }
        return "No answer text on this row \u{2014} \u{23CE} opens the thread."
    }

    private var helpText: String {
        var parts = [row.title, "id: \(row.id)"]
        if let door = row.ask.door { parts.append("came in by: \(door)") }
        parts.append("state: \(row.ask.state.raw)")
        if let age = row.ageText { parts.append("\(age) old") }
        if let reason = row.ask.reason { parts.append(String(reason.prefix(200))) }
        if let question = row.ask.question { parts.append(question) }
        if let url = row.ask.url { parts.append(url) }
        parts.append("click the title (or \u{23CE}) to open the thread")
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

/// Run now / Ask me first: an NSSegmentedControl with plain string labels,
/// bound to `StatusController.fireToPass`.
///
/// This used to be SwiftUI's `Picker(.segmented)`. On macOS 26 that picker
/// hosts each segment's label in a nested SwiftUI graph, and AppKit sizes
/// and draws those labels on every update of the view around them -- every
/// poll, every ticker second, every keystroke, and in the cached summon
/// panel even while it is hidden. A sample of a widget five days up
/// (2026-09-28: 134.7 MB across ~1.08M live allocations) spent its idle
/// main-thread time inside exactly those label graphs, cancelling and
/// re-registering Observation tracking against a tracking set big enough
/// that every cancel copied and freed it -- the signature of registrations
/// that are never released, so each update left a little more behind for
/// as long as the widget ran. String labels leave AppKit nothing of
/// SwiftUI's to host, so there is nothing to register.
struct FireModeControl: NSViewRepresentable {
    @Binding var toPass: Bool

    func makeNSView(context: Context) -> NSSegmentedControl {
        // Q12: the second mode is Ask me first -- the same one-shot slot To
        // Pass held, now POSTing /asks (contract 1.6) with today's /capture
        // as the fallback on hubs that have not built it. String labels for
        // the leak reason above; nothing pins them but this line.
        let control = NSSegmentedControl(labels: ["Run now", "Ask me first"],
                                         trackingMode: .selectOne,
                                         target: context.coordinator,
                                         action: #selector(Coordinator.changed(_:)))
        control.controlSize = .small
        control.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        // Takes the row's spare width the way the SwiftUI picker did, rather
        // than hugging its two labels.
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // A click must never pull focus off the quick-fire field: Tab, Return
        // and the ⌘ shortcuts are SwiftUI onKeyPress handlers, which an
        // AppKit first responder would swallow.
        control.refusesFirstResponder = true
        control.selectedSegment = toPass ? 1 : 0
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.toPass = $toPass
        // Written only on a real change, so the poll-cadence updates that
        // move nothing leave the control alone.
        let segment = toPass ? 1 : 0
        if control.selectedSegment != segment { control.selectedSegment = segment }
        // `.disabled(...)` only reaches a representable through the
        // environment; AppKit has to be told.
        let enabled = context.environment.isEnabled
        if control.isEnabled != enabled { control.isEnabled = enabled }
    }

    func makeCoordinator() -> Coordinator { Coordinator(toPass: $toPass) }

    final class Coordinator: NSObject {
        var toPass: Binding<Bool>

        init(toPass: Binding<Bool>) { self.toPass = toPass }

        @objc func changed(_ sender: NSSegmentedControl) {
            toPass.wrappedValue = sender.selectedSegment == 1
        }
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
        // Cached on the controller, refreshed at poll cadence off the main
        // thread -- see `StatusController.recentDirs`. This used to call
        // `RecentDirs.load` straight from here, scanning and JSON-parsing
        // every task file on the main thread every time this view's body
        // ran, which is every keystroke into quick-fire's own field.
        let recents = controller.recentDirs
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

// MARK: - Yours today (Q11)

/// The ⌥⏎ picker's open state: what the reminder is for -- the field's
/// words (POST /asks mode "remind") or a yours row's ask (the `remind`
/// move) -- plus the time text being typed into it.
struct RemindPick: Equatable {
    enum Target: Equatable {
        case field(String)
        case row(String)
    }

    let target: Target
    var spec: String = ""
}

/// The yours section's rows, built pure over the feed's asks so the view and
/// the `--ask-dump-rows` seam draw the same section: the yours-place asks
/// (contract 1.2 -- John's own to-dos, no live agent work), the ones
/// `AskSections` keeps out of the three action sections. Sorted with the
/// soonest reminder first -- a section that exists to say *when* leads with
/// the nearest *when* -- then newest activity, then id.
enum AskYours {
    /// The plan's own name for the section.
    static let label = "Yours today"

    static func rows(in asks: [Ask]) -> [YoursRowModel] {
        func remindDate(_ ask: Ask) -> Date? { ask.remindAt.flatMap(Store.parseDate) }
        func activity(_ ask: Ask) -> Date {
            ask.finishedDate ?? ask.updatedDate ?? ask.createdDate ?? .distantPast
        }
        return asks.filter { $0.place == "yours" }
            .sorted { lhs, rhs in
                let l = remindDate(lhs) ?? .distantFuture
                let r = remindDate(rhs) ?? .distantFuture
                if l != r { return l < r }
                let la = activity(lhs), ra = activity(rhs)
                if la != ra { return la > ra }
                return lhs.id < rhs.id
            }
            .map(YoursRowModel.init)
    }
}

/// One yours-place ask as the menu draws it. The section's two facts are the
/// plan's two words: the title, and the time -- the reminder when one is
/// set, the coarse age otherwise.
struct YoursRowModel: Equatable, Identifiable {
    let ask: Ask

    var id: String { ask.id }
    var title: String { ask.title }
    var remindDate: Date? { ask.remindAt.flatMap(Store.parseDate) }
    var openURL: URL? { ask.url.flatMap(URL.init(string:)) }

    /// The right-hand column: when the nudge comes, or how old the to-do is.
    var timeText: String? {
        if let at = remindDate { return RemindTime.text(for: at) }
        guard let at = ask.finishedDate ?? ask.updatedDate ?? ask.createdDate else { return nil }
        return shortAge(from: at)
    }

    /// The sub-line under the title, nil without a reminder: says when in
    /// the section's own plain words.
    var remindLine: String? {
        guard let at = remindDate else { return nil }
        return "Reminds you at \(RemindTime.text(for: at))"
    }
}

/// The buttons a yours row offers (contract 1.2: done, remind, run when
/// `can_run`, drop), gated on the hub's own `moves` list exactly the way
/// `AskRowMoves` gates the action states -- a move the hub did not offer is
/// a button the row does not draw, and a refusal that comes back anyway
/// shows in the hub's words.
enum YoursMoves {
    static func buttons(for ask: Ask) -> [AskMoveButton] {
        var out: [AskMoveButton] = []
        if ask.moves.contains("done") {
            out.append(AskMoveButton(act: .post("done"), title: "Done", key: "e"))
        }
        if ask.moves.contains("remind") {
            out.append(AskMoveButton(act: .text(move: "remind", bodyKey: "at"),
                                     title: "Remind me\u{2026}", key: "r"))
        }
        if ask.canRun, ask.moves.contains("run") {
            out.append(AskMoveButton(act: .post("run"), title: "Run it", key: nil))
        }
        if ask.moves.contains("drop") {
            out.append(AskMoveButton(act: .post("drop"), title: "Drop", key: "d"))
        }
        return out
    }

    static func target(ask: Ask, key: String) -> AskMoveButton? {
        buttons(for: ask).first { $0.key == key }
    }
}

/// The yours section's header. A quiet label and a count, like the ask
/// sections' own -- the section is a standing part of the day, not an alarm.
struct YoursSectionHeader: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(AskYours.label)
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
        .help("Your own to-dos -- asks with no agent work on them. "
              + "E files one done; R sets when it should nudge you; D drops it.")
    }
}

/// One yours row: the title opens the ask's one address, the time sits where
/// every row's right-hand fact sits, and the tail carries the row's own
/// moves (Done, Remind, Run when the hub offers it, Drop). No peek panel --
/// a to-do has no answer to read; the title's page is where its thread
/// lives.
struct YoursRowView: View {
    let row: YoursRowModel
    var highlighted: Bool = false
    /// The verdict line a move left under this row, nil when there is none.
    var moveLine: String?
    let onTitle: () -> Void
    let onButton: (AskMoveButton) -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 7, height: 7)
                Button(action: onTitle) {
                    Text(row.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                if let time = row.timeText {
                    Text(time)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                ForEach(YoursMoves.buttons(for: row.ask)) { button in
                    RowButton(icon: Self.symbol(for: button), help: button.helpText) {
                        onButton(button)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Color.accentColor.opacity(0.18)
                                    : (hovering ? Color.primary.opacity(0.06) : .clear))
            .onHover { hovering = $0 }
            .help(helpText)
            if let line = row.remindLine {
                Text(line)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 27)
                    .padding(.bottom, 3)
            }
            if let line = moveLine {
                Text(line)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 27)
                    .padding(.bottom, 3)
            }
        }
    }

    /// The row's own glyphs: remind draws the clock the move is, run the
    /// play triangle a fire is -- AskMoveButton's generic table (Q9) has no
    /// cases for the yours moves, and a made-up icon would say less.
    private static func symbol(for button: AskMoveButton) -> String {
        switch button.move {
        case "done": return "checkmark.circle"
        case "remind": return "clock"
        case "run": return "play.circle"
        case "drop": return "xmark.circle"
        default: return "circle"
        }
    }

    private var helpText: String {
        var parts = [row.title, "id: \(row.id)", "state: \(row.ask.state.raw)"]
        if let at = row.remindDate { parts.append("reminds at \(RemindTime.text(for: at))") }
        if let url = row.ask.url { parts.append(url) }
        parts.append("click the title (or \u{23CE}) to open the thread")
        return parts.joined(separator: "\n")
    }
}

// MARK: - one find result (Q11)

/// One find result: a row like every other ask row -- the title opens the
/// ask's one address, the eye reads the answer in place through the same
/// thread fetch and `seen` rule the section rows use -- with where the
/// query matched and the snippet standing where a row would put its reason.
struct FindRowView: View {
    let hit: AskSearchHit
    var highlighted: Bool = false
    var expanded: Bool = false
    var loading: Bool = false
    var thread: AskThread?
    /// The verdict line a move left under this row, nil when there is none.
    var moveLine: String?
    let onTitle: () -> Void
    let onToggleExpand: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Button(action: onTitle) {
                    Text(hit.ask.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                if let label = hit.matchLabel {
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                RowButton(icon: expanded ? "chevron.up" : "eye",
                          help: expanded ? "Hide the answer" : "Read the answer here",
                          action: onToggleExpand)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Color.accentColor.opacity(0.18)
                                    : (hovering ? Color.primary.opacity(0.06) : .clear))
            .onHover { hovering = $0 }
            .help(helpText)
            if let line = moveLine {
                Text(line)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 27)
                    .padding(.bottom, 3)
            }
            Text(snippetText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .padding(.leading, 27)
                .padding(.trailing, 12)
                .padding(.bottom, 3)
            if expanded {
                peek
            }
        }
    }

    /// No colour claim about a state this build cannot read (unknown draws
    /// gray, like the dot); the named states keep the palette the rows
    /// trained. A found done ask is quiet gray -- it is history, not news.
    private var dotColor: Color {
        switch hit.ask.state {
        case .question, .blocked, .failed: return .orange
        case .answer: return hit.ask.unseen ? .accentColor : .secondary.opacity(0.6)
        case .working: return .green
        case .wantsOk: return .blue
        default: return .secondary.opacity(0.6)
        }
    }

    /// The snippet the hub matched, or the best the row itself carries.
    private var snippetText: String {
        if let snippet = hit.snippet, !snippet.isEmpty { return snippet }
        return hit.ask.answerExcerpt ?? hit.ask.words
    }

    /// The same peek the section rows draw, same capped scroll: the thread's
    /// answer once it lands, the snippet until then.
    private var peek: some View {
        VStack(alignment: .leading, spacing: 6) {
            if loading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                    Text("Reading the answer\u{2026}")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    Text(answerText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                }
                .frame(height: AskRowView.expandMaxHeight)
            }
        }
        .padding(.leading, 27)
        .padding(.trailing, 12)
        .padding(.bottom, 7)
    }

    private var answerText: String {
        if let thread, !thread.answerText.isEmpty { return thread.answerText }
        if let excerpt = hit.ask.answerExcerpt, !excerpt.isEmpty { return excerpt }
        return "No answer text on this row \u{2014} the title opens the thread."
    }

    private var helpText: String {
        var parts = [hit.ask.title, "id: \(hit.id)", "state: \(hit.ask.state.raw)"]
        if let door = hit.ask.door { parts.append("came in by: \(door)") }
        if let label = hit.matchLabel { parts.append("matched \(label)") }
        if let url = hit.ask.url { parts.append(url) }
        parts.append("click the title (or \u{23CE}) to open the thread")
        return parts.joined(separator: "\n")
    }
}
