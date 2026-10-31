import AppKit
import SwiftUI

/// Settings › Keyboard: every command's shortcut, recorded by pressing it.
struct KeyboardSettingsView: View {
    var settings = ShortcutSettings.shared
    @State private var filter = ""
    @State private var recording: String?
    @State private var monitor: Any?
    /// A shortcut another command already uses, waiting for Replace or Cancel.
    @State private var pending: (command: AppCommand, shortcut: KeyShortcut, owner: AppCommand)?
    @State private var notice: String?

    private var groups: [(AppCommand.Group, [AppCommand])] {
        let text = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return AppCommand.Group.allCases.compactMap { group in
            let commands = AppCommand.all.filter { command in
                guard command.group == group else { return false }
                guard !text.isEmpty else { return true }
                return command.title.lowercased().contains(text)
                    || settings.shortcut(for: command)?.display.lowercased().contains(text) == true
            }
            return commands.isEmpty ? nil : (group, commands)
        }
    }

    private var changedCount: Int {
        AppCommand.all.filter { !$0.locked && settings.isChanged($0) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Filter commands or shortcuts", text: $filter)
                    .textFieldStyle(.roundedBorder)
                if changedCount > 0 {
                    Text("\(changedCount) changed").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 10)
            if let pending {
                banner(
                    "\(pending.shortcut.display) is already used by \(pending.owner.title).",
                    conflict: true
                )
            } else if let notice {
                banner(notice, conflict: false)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups, id: \.0) { group, commands in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.rawValue).font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary).textCase(.uppercase)
                                .accessibilityAddTraits(.isHeader)
                            VStack(spacing: 0) {
                                ForEach(
                                    Array(commands.enumerated()),
                                    id: \.element.id
                                ) { index, command in
                                    if index > 0 {
                                        Divider()
                                    }
                                    row(command)
                                }
                            }
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 16)
            }
            Divider()
            HStack {
                Text(
                    "Shortcuts work while Gleanary is active. The menus and the command palette show what you set here."
                )
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") {
                    stopRecording()
                    settings.restoreDefaults()
                }
                .disabled(changedCount == 0)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
        .onDisappear { stopRecording() }
    }

    private func row(_ command: AppCommand) -> some View {
        let shortcut = settings.shortcut(for: command)
        let isRecording = recording == command.id
        return HStack(spacing: 10) {
            Label(command.title, systemImage: command.symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
            if command.locked {
                Label(shortcut?.display ?? "", systemImage: "lock")
                    .foregroundStyle(.secondary).font(.callout)
                    .help("Set by macOS or the screen it belongs to")
                    .accessibilityLabel(
                        "\(command.title) shortcut, \(shortcut?.spoken ?? "none"), can't be changed"
                    )
            } else {
                if settings.isChanged(command) {
                    Button("Reset \(command.title)", systemImage: "arrow.uturn.backward") {
                        stopRecording()
                        settings.reset(command)
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Reset to \(command.defaultShortcut?.display ?? "none")")
                }
                Button {
                    isRecording ? stopRecording() : startRecording(command)
                } label: {
                    Text(isRecording ? "Type shortcut…" : shortcut?.display ?? "Record Shortcut")
                        .monospacedDigit()
                        .foregroundStyle(isRecording ? Color.accentColor
                            : shortcut == nil ? .secondary : .primary)
                        .frame(minWidth: 120)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
                .overlay {
                    if isRecording {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(
                            Color.accentColor,
                            lineWidth: 1.5
                        )
                    }
                }
                .accessibilityLabel("\(command.title) shortcut")
                .accessibilityValue(isRecording ? "Recording. Press keys, or Escape to cancel."
                    : shortcut?.spoken ?? "None")
                .accessibilityHint(isRecording ? "" : "Records a new shortcut")
                Button("Remove shortcut for \(command.title)", systemImage: "xmark") {
                    stopRecording()
                    settings.set(nil, for: command)
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .disabled(shortcut == nil)
            }
        }
        .frame(minHeight: 30)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func banner(_ text: String, conflict: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: conflict ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(conflict ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            Text(text).font(.callout)
            Spacer()
            if conflict, let pending {
                Button("Cancel") { self.pending = nil }
                Button("Replace") {
                    settings.set(pending.shortcut, for: pending.command)
                    self.pending = nil
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("OK") { notice = nil }
            }
        }
        .controlSize(.small)
        .padding(10)
        .background(
            (conflict ? Color.orange : Color.primary).opacity(0.1),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .padding(.horizontal, 24).padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }

    // MARK: Recording

    private func startRecording(_ command: AppCommand) {
        stopRecording()
        pending = nil
        notice = nil
        recording = command.id
        // A local monitor sees the press before menus do, so recording ⌘N doesn't make a note.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            record(event, for: command)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recording = nil
    }

    private func record(_ event: NSEvent, for command: AppCommand) {
        guard let shortcut = KeyShortcut(event: event) else { return }
        if shortcut.key == "escape", shortcut.modifiers.isEmpty {
            stopRecording()
            return
        }
        switch Self.validate(shortcut, for: command, in: settings) {
        case .accepted:
            settings.set(shortcut, for: command)
        case let .refused(reason):
            notice = reason
            // A bare letter keeps recording, so the next press can add a modifier.
            if !shortcut.modifiers.isDisjoint(with: [.command, .option, .control])
                || shortcut.isFunctionKey
            {
                break
            }
            return
        case let .conflict(owner):
            pending = (command, shortcut, owner)
        }
        stopRecording()
    }

    enum Validation: Equatable {
        case accepted
        case refused(String)
        case conflict(AppCommand)
    }

    /// Whether a recorded shortcut can be used: it needs ⌘, ⌥ or ⌃ (or a function key), mustn't
    /// be one macOS or text editing uses, and may already belong to another command.
    static func validate(
        _ shortcut: KeyShortcut, for command: AppCommand, in settings: ShortcutSettings
    ) -> Validation {
        guard shortcut.isFunctionKey
            || !shortcut.modifiers.isDisjoint(with: [.command, .option, .control])
        else { return .refused("Add ⌘, ⌥ or ⌃ so typing a letter doesn’t run a command.") }
        if let use = ShortcutSettings.reserved[shortcut] {
            return .refused("\(shortcut.display) is reserved for \(use).")
        }
        if let owner = settings.owner(of: shortcut, excluding: command.id) {
            return owner.locked
                ? .refused("\(shortcut.display) is used by \(owner.title), which can’t change.")
                : .conflict(owner)
        }
        return .accepted
    }
}
