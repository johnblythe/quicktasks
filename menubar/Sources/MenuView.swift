// MenuView.swift -- the dropdown, laid out after the status-menu reference:
// quick-fire field, aggregate header, one row per task with a status dot and a
// right-hand detail column, then a footer with refreshed-at and controls.

import SwiftUI
import AppKit

struct MenuView: View {
    @ObservedObject var controller: StatusController
    @State private var draft: String = ""
    @State private var flash: String?
    @FocusState private var fieldFocused: Bool

    private let rowWidth: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            quickFire
            Divider()
            header
            Divider()
            if controller.model.records.isEmpty {
                Text("No task runs yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(controller.model.records, id: \.id) { record in
                            TaskRow(record: record, now: controller.model.refreshedAt) {
                                act(Actions.resume(id: record.id), ok: "Resuming \(record.id)")
                            }
                        }
                    }
                }
                // Caps the panel height so a long history scrolls instead of
                // growing the menu off the bottom of the screen.
                .frame(maxHeight: 280)
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
        .frame(width: rowWidth)
        .onAppear {
            controller.refresh()
            // The panel needs to be key before a TextField will take
            // keystrokes, and opening a MenuBarExtra window does not
            // activate the app on its own.
            NSApp.activate(ignoringOtherApps: true)
            fieldFocused = true
        }
    }

    // MARK: - sections

    private var quickFire: some View {
        HStack(spacing: 7) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Fire a quick task\u{2026}", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .onSubmit(fire)
            if !draft.isEmpty {
                Button(action: fire) {
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Queue this task")
            }
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
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Refreshed \(Self.clock.string(from: controller.model.refreshedAt))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            FooterButton(icon: "list.bullet.rectangle", help: "Open The Pass") {
                Actions.openPass()
            }
            FooterButton(icon: "arrow.clockwise", help: "Refresh now") {
                controller.refresh()
            }
            FooterButton(icon: "power", help: "Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - behaviour

    private func fire() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        act(Actions.fire(prompt: text), ok: "Queued")
        draft = ""
    }

    /// Shows the outcome in the header for a couple of seconds. A failure to
    /// fire has to be visible: the alternative is a task John believes is
    /// queued and never hears about again.
    private func act(_ result: Result<Void, Problem>, ok: String) {
        switch result {
        case .success:
            flash = ok
            controller.refresh()
        case .failure(let message):
            flash = message.message
        }
        let shown = flash
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

// MARK: - one task row

private struct TaskRow: View {
    let record: TaskRecord
    let now: Date
    let onResume: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(StatusPalette.color(for: record.status)))
                .frame(width: 7, height: 7)
            Text(record.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            // The reference's external-link arrow, here meaning "reopen this
            // session". Only shown when there is a session to reopen.
            if record.canResume {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10))
                    .foregroundStyle(record.wantsResume ? .primary : .tertiary)
            } else {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10))
                    .opacity(0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering && record.canResume ? Color.accentColor.opacity(0.16) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if record.canResume { onResume() } }
        .help(helpText)
    }

    /// Live runs read as elapsed time; finished ones read as their status plus
    /// how long ago, which is the pairing the reference uses in its right column.
    private var detail: String {
        if record.status.isActive {
            if let started = record.started { return "\(record.status.detail) \(shortAge(from: started, to: now))" }
            return record.status.detail
        }
        guard let at = record.activity else { return record.status.detail }
        return "\(record.status.detail) \u{00B7} \(shortAge(from: at, to: now))"
    }

    private var helpText: String {
        var parts = [record.title, "id: \(record.id)"]
        if record.origin == .pass { parts.append("from The Pass") }
        if record.denialCount > 0 { parts.append("\(record.denialCount) permission denial(s)") }
        if let e = record.error, !e.isEmpty { parts.append(String(e.prefix(160))) }
        parts.append(record.canResume ? "click to resume in terminal" : "no session to resume")
        return parts.joined(separator: "\n")
    }
}

private struct FooterButton: View {
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
