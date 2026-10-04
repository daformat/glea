// The window updating happens in, from Subtitles (app/macos/UpdateWindow.swift
// there): one window, and the states swap inside it: checking, found,
// downloading, ready, installing, up to date, failed. Updater.swift is what
// translates Sparkle into these states, for a check asked from the menu; the
// background ones never open it (the top bar's pill says when an update is
// ready). Nothing here knows Sparkle exists.
//
// Closing the window with its red button means what the state's most cautious
// button means: Later while an update is offered, Cancel while it downloads,
// nothing at all while it installs. Each state says so by carrying the closure.

import AppKit

@MainActor
final class UpdateWindow: NSObject, NSWindowDelegate {
    enum State {
        /// A check the user asked for is in flight.
        case checking(cancel: () -> Void)
        /// An update is offered. `skip` is nil for a critical update, where
        /// skipping is not on the table.
        case found(version: String, current: String, size: String?, notes: ReleaseNotes?,
                   critical: Bool, install: () -> Void, later: () -> Void, skip: (() -> Void)?)
        /// Downloading; progress arrives through `progress(fraction:detail:)`.
        /// The version is nil on the rare update Sparkle has not named, which
        /// gets sentences of its own rather than a word in the number's place.
        case downloading(version: String?, cancel: () -> Void)
        /// Unpacking, after the download; same progress path.
        case extracting(version: String?)
        case ready(version: String?, install: () -> Void, later: () -> Void)
        /// The app is quitting so the update can be swapped in. `retry` is
        /// offered when it did not quit.
        case installing(version: String?, retry: (() -> Void)?)
        case upToDate(version: String, dismiss: () -> Void)
        case failed(title: String, message: String, retry: (() -> Void)?, dismiss: () -> Void)

        /// What the window's close button does in this state.
        var closeAction: (() -> Void)? {
            switch self {
            case .checking(let cancel): return cancel
            case .found(_, _, _, _, _, _, let later, _): return later
            case .downloading(_, let cancel): return cancel
            case .extracting: return nil
            case .ready(_, _, let later): return later
            case .installing: return nil
            case .upToDate(_, let dismiss): return dismiss
            case .failed(_, _, _, let dismiss): return dismiss
            }
        }
    }

    private static var width: CGFloat { Dialog.width }

    private var window: NSWindow?
    private var state: State?
    private var bar: NSProgressIndicator?
    private var detail: NSTextField?
    /// True while `close()` is closing the window itself, so the delegate does
    /// not mistake it for the user's red button.
    private var closingProgrammatically = false

    var isVisible: Bool { window?.isVisible ?? false }

    func show(_ state: State) {
        self.state = state
        let window = self.window ?? build()
        self.window = window

        Dialog.place(contentView(for: state), in: window)
        // The window's close button is the state's cautious choice, and there
        // is none for the states that must run to the end.
        window.standardWindowButton(.closeButton)?.isEnabled = state.closeAction != nil

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Progress for the downloading and extracting states. `fraction` nil
    /// means working, length unknown.
    func progress(fraction: Double?, detail text: String?) {
        if let bar {
            let unknown = fraction == nil
            if unknown != bar.isIndeterminate {
                bar.isIndeterminate = unknown
                if unknown { bar.startAnimation(nil) } else { bar.stopAnimation(nil) }
            }
            if let fraction { bar.doubleValue = fraction }
        }
        if let text { detail?.stringValue = text }
    }

    func close() {
        guard let window else { return }
        closingProgrammatically = true
        window.orderOut(nil)
        closingProgrammatically = false
        state = nil
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closingProgrammatically, let action = state?.closeAction else {
            return closingProgrammatically
        }
        // The action is what closes it — through Updater, which will call
        // `close()` when Sparkle has finished with the session.
        action()
        return false
    }

    // MARK: building

    private func build() -> NSWindow {
        Dialog.window(title: L("Glea Update"), delegate: self)
    }

    private func contentView(for state: State) -> NSView {
        let stack = Dialog.stack()
        bar = nil
        detail = nil

        let icon = Dialog.icon()
        stack.addArrangedSubview(icon)
        stack.setCustomSpacing(10, after: icon)

        switch state {
        case .checking(let cancel):
            Dialog.add(stack, headline: L("Checking for updates…"), blurb: nil)
            let bar = Dialog.progressBar(indeterminate: true)
            stack.addArrangedSubview(bar)
            stack.setCustomSpacing(14, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
            self.bar = bar
            Dialog.addButtons(stack, [Dialog.button(L("Cancel"), cancel)])

        case .found(let version, let current, let size, let notes, let critical, let install, let later, let skip):
            let blurb: String
            switch (critical, size) {
            case (true, let size?):
                blurb = LF("You have %1$@. This one fixes something that matters. The update is %2$@ "
                           + "and installs in place: your notes and tabs come back with it.", current, size)
            case (true, nil):
                blurb = LF("You have %@. This one fixes something that matters. It installs in place: "
                           + "your notes and tabs come back with it.", current)
            case (false, let size?):
                blurb = LF("You have %1$@. The update is %2$@ and installs in place: "
                           + "your notes and tabs come back with it.", current, size)
            case (false, nil):
                blurb = LF("You have %@. It installs in place: your notes and tabs come back with it.", current)
            }
            Dialog.add(stack, headline: LF("Glea %@ is available", version), blurb: blurb)
            if let notes, !notes.isEmpty {
                let box = Dialog.textBox(Self.attributed(notes))
                stack.addArrangedSubview(box)
                stack.setCustomSpacing(16, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
            }
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            if let skip { row.addArrangedSubview(Dialog.button(L("Skip This Version"), skip)) }
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
            row.addArrangedSubview(Dialog.button(L("Later"), later))
            row.addArrangedSubview(Dialog.button(L("Install Update"), install, default: true))
            row.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
            stack.addArrangedSubview(row)
            stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])

        case .downloading(let version, let cancel):
            Dialog.add(stack, headline: version.map { LF("Downloading %@…", $0) } ?? L("Downloading the update…"), blurb: nil)
            addProgress(stack, indeterminate: true, detail: L("Starting…"))
            Dialog.addButtons(stack, [Dialog.button(L("Cancel"), cancel)])

        case .extracting(let version):
            Dialog.add(stack, headline: version.map { LF("Unpacking %@…", $0) } ?? L("Unpacking the update…"), blurb: nil)
            addProgress(stack, indeterminate: true, detail: L("A moment."))

        case .ready(let version, let install, let later):
            Dialog.add(stack, headline: L("Ready to install"),
                blurb: version.map { LF("Glea will quit and come back as %@, with your tabs.", $0) }
                    ?? L("Glea will quit and come back updated, with your tabs."))
            Dialog.addButtons(stack, [Dialog.button(L("Later"), later),
                               Dialog.button(L("Install and Relaunch"), install, default: true)])

        case .installing(let version, let retry):
            Dialog.add(stack, headline: version.map { LF("Installing %@…", $0) } ?? L("Installing the update…"),
                blurb: retry == nil
                    ? L("Glea is quitting and will be back in a moment.")
                    : L("Glea has not quit yet. Something may be asking to keep it open."))
            if let retry {
                Dialog.addButtons(stack, [Dialog.button(L("Quit and Install"), retry, default: true)])
            } else {
                addProgress(stack, indeterminate: true, detail: nil)
            }

        case .upToDate(let version, let dismiss):
            Dialog.add(stack, headline: L("You have the latest version"),
                blurb: LF("Glea %@ · checked just now", version))
            Dialog.addButtons(stack, [Dialog.button(L("OK"), dismiss, default: true)])

        case .failed(let title, let message, let retry, let dismiss):
            Dialog.add(stack, headline: title, blurb: message)
            var buttons = [Dialog.button(L("OK"), dismiss, default: retry == nil)]
            if let retry { buttons.append(Dialog.button(L("Try Again"), retry, default: true)) }
            Dialog.addButtons(stack, buttons)
        }
        return stack
    }

    private func addProgress(_ stack: NSStackView, indeterminate: Bool, detail text: String?) {
        let bar = Dialog.progressBar(indeterminate: indeterminate)
        stack.addArrangedSubview(bar)
        stack.setCustomSpacing(14, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
        self.bar = bar
        guard let text else { return }
        let label = Dialog.label(text, size: 11, colour: .secondaryLabelColor)
        stack.addArrangedSubview(label)
        stack.setCustomSpacing(4, after: bar)
        detail = label
    }

    private static func attributed(_ notes: ReleaseNotes) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if let heading = notes.heading {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            out.append(NSAttributedString(string: heading + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ]))
        }
        for (i, item) in notes.items.enumerated() {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            style.lineSpacing = 1
            if item.bulleted {
                style.headIndent = 14
                style.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
                out.append(NSAttributedString(string: "\u{2022}\t", attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: style,
                ]))
            }
            for run in item.runs {
                let font: NSFont = run.code
                    ? .monospacedSystemFont(ofSize: 11, weight: .regular)
                    : .systemFont(ofSize: 12, weight: run.bold ? .semibold : .regular)
                out.append(NSAttributedString(string: run.text, attributes: [
                    .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
                ]))
            }
            if i < notes.items.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
            }
        }
        return out
    }
}

// Glea is in English only: the strings as they are, with LF's arguments put in.
private func L(_ key: String) -> String { key }

private func LF(_ format: String, _ args: CVarArg...) -> String {
    String(format: format, arguments: args)
}
