//  QuickAdd.swift — the way tasks get in, given that a widget cannot take text.
//
//  macOS gives a widget no text input at all. Not a restricted one, none: the
//  widget host draws a picture and runs App Intents, and no intent can put a caret
//  anywhere. People still need to add tasks without a terminal, so "run bangerctl in a
//  terminal" cannot be the only way in.
//
//  So the field lives in the agent app, and it is summoned rather than visited:
//
//    ⌃⌥⌘N            global, from anywhere, no Accessibility grant needed
//    the widget's +  posts a notification that lands here (QuickAddIntent)
//
//  DESIGN CONSTRAINTS, all of them load-bearing:
//
//   - Visible in well under 100 ms. The panel and its text field are built once at
//     install and kept alive; showing it is an orderFront on an existing window,
//     not a construction. Nothing is laid out, nothing is loaded, nothing is
//     animated on the critical path.
//   - No Dock icon, ever. The process is LSUIElement / .accessory and the
//     activation policy is never changed. Activating an accessory app shows no
//     Dock tile and does not replace the user's menu bar.
//   - Focus goes straight back. The frontmost application is recorded before the
//     panel opens and re-activated the moment it closes, so Enter or Escape leaves
//     them typing where they were.
//   - No window management. One borderless panel, positioned by the code, on all
//     Spaces, no title bar, no resize, nothing to arrange.
//   - Reduce Motion is respected: the entrance scale is skipped entirely.
//
//  NOTHING TYPED IS LOST. Return still closes the panel at once and the write happens
//  afterwards, off the main thread — but the text is held until the store confirms it.
//  If the save fails (a writer holding the lock past its timeout, an unreadable
//  tasks.json), the text comes back: into the field if the panel is still open, and
//  otherwise as a small notice where the panel sits, which does not take the keyboard,
//  and then in the field the next time the panel opens. Each submission carries the id
//  the task will have, so retrying one that did land after all adds nothing.
//
//  ⌃⌥⌘N was chosen because ⌘N, ⌥⌘N and ⌃⌘N are all taken by ordinary apps, and
//  because it sits next to the existing ⌃⌥⌘B demo key. Hold ⇧ on Return to add a
//  task and keep the panel open for the next one.
//
//  WIRING. `QuickAdd.shared.install()` in AppDelegate.applicationDidFinishLaunching
//  is the whole of it, and it is the one line that makes any of this reachable.

import AppKit
import Carbon.HIToolbox
import BangerKit

// MARK: - Signal

/// Kept in step by hand with the copy in Sources/BangerWidget/QuickAddIntent.swift.
enum QuickAddSignal {
    static let plain = Notification.Name("com.bangerwidget.banger.quickAdd")
    /// App Sandbox only lets the sandboxed widget extension post names carrying its
    /// group prefix, so the + posts under both and we listen on both.
    static let groupPrefixed = Notification.Name("group.com.bangerwidget.banger.quickAdd")
}

// MARK: - Draft

/// A submitted line, from Return until the store confirms it. The id is chosen at
/// submission and becomes the task's id, so a retry of the same draft finds the task
/// already in the file if an earlier attempt did land, and adds nothing.
struct QuickAddDraft: Sendable, Equatable {
    let id: String
    let text: String
}

// MARK: - QuickAdd

@MainActor
final class QuickAdd: NSObject {

    static let shared = QuickAdd()

    /// ⌃⌥⌘N.
    static let keyN = UInt32(kVK_ANSI_N)
    /// 'BNGQ' — distinct from HotKeyMonitor's 'BNGR', so the two Carbon handlers
    /// installed on the same event target ignore each other's hot keys.
    private static let signature: OSType = 0x424E_4751
    private static let hotKeyID: UInt32 = 1

    private var panel: QuickAddPanel?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var observers: [NSObjectProtocol] = []
    private var previousApp: NSRunningApplication?
    private var installed = false

    /// Drafts whose save failed, oldest first. Each comes back into the field the next
    /// time the field is free, until it saves or the user empties the field.
    private var unsaved: [QuickAddDraft] = []
    /// The failed draft sitting in the field right now, if any.
    private var restored: QuickAddDraft?
    /// Why the last save failed, in a few words, for the panel's hint line.
    private var lastFailure = "it was not saved"
    private var noticeHide: DispatchWorkItem?
    /// How long the "not saved" notice stays up when the panel was closed.
    private let noticeDuration: TimeInterval = 5

    private override init() { super.init() }

    // MARK: Install

    /// Idempotent. Call once from applicationDidFinishLaunching.
    func install() {
        guard !installed else { return }
        installed = true

        // Built now, not on first use: the whole point is that the panel is already
        // laid out and its field already exists when the key is pressed.
        panel = QuickAddPanel(onCommit: { [weak self] text, keepOpen in
            self?.commit(text, keepOpen: keepOpen)
        }, onCancel: { [weak self] in
            self?.dismiss()
        }, onNoticeClicked: { [weak self] in
            self?.present()
        })

        // Force the window server to realise the panel's surface and its layers
        // NOW, at login, rather than on the first press. A cold orderFront is far
        // slower than a warm one, and "visible in under 100 ms" is about the press,
        // so the expensive part has to happen before the press exists.
        panel?.prewarm()

        registerHotKey()

        let center = DistributedNotificationCenter.default()
        observers = [QuickAddSignal.groupPrefixed, QuickAddSignal.plain].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { QuickAdd.shared.present() }
            }
        }
    }

    func uninstall() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        let center = DistributedNotificationCenter.default()
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
        noticeHide?.cancel()
        noticeHide = nil
        panel?.orderOut(nil)
        panel = nil
        installed = false
    }

    // MARK: Present

    /// Idempotent: a second ⌃⌥⌘N while the panel is up just keeps it up, so the
    /// widget's + and the hot key cannot stack two panels.
    func present() {
        guard let panel else { return }
        if panel.isVisible && !panel.isShowingNotice {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        // Up as a "not saved" notice: become the real panel, with the draft in the field.
        endNotice(hide: false)

        // A task card left up would keep Escape, and QuickAdd's Escape would close it.
        TaskPeek.shared.dismiss()

        // Remember who had focus, so Enter and Escape both give it straight back.
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }

        panel.positionForDisplay()
        panel.prepareToShow(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        restoreNextDraftIfFree()

        // An accessory app that activates shows no Dock tile and does not take over
        // the menu bar. It is the only way a borderless panel gets the keyboard.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.focusField()
    }

    // MARK: Commit / dismiss

    private func commit(_ raw: String, keepOpen: Bool) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            // Emptying the field is how a failed draft is thrown away on purpose.
            restored = nil
            dismiss()
            return
        }

        // The failed draft, resubmitted as it was, keeps its id: that is what makes a
        // retry add exactly one task. Edited, it is a new line.
        let draft = restored.flatMap { $0.text == text ? $0 : nil }
            ?? QuickAddDraft(id: BangerTask.newID(), text: text)
        restored = nil
        panel?.showProblem(nil)

        if keepOpen {
            panel?.clearField()
            save(draft)
            restoreNextDraftIfFree()
            return
        }

        dismiss()
        save(draft)
    }

    /// On the storage queue and after the panel has gone. TaskStore takes an
    /// NSFileCoordinator write lock and the cross-process flock, which are fast but are
    /// not free, and nothing about them should be between the Return key and the panel
    /// disappearing. One queue for every add also keeps two quick ⇧Returns in order.
    private func save(_ draft: QuickAddDraft) {
        StorageQueue.shared.async {
            let result = Result<Void, Error> { try QuickAdd.persist(draft) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { QuickAdd.shared.saveFinished(draft, result) }
            }
        }
    }

    /// Appends the draft as a task whose id is the draft's, unless an earlier attempt at
    /// this same draft is already there.
    nonisolated static func persist(_ draft: QuickAddDraft, store: TaskStore = .shared) throws {
        try store.mutate { document in
            if document.tasks.contains(where: { $0.id == draft.id && $0.text == draft.text }) {
                return
            }
            var task = BangerTask(id: draft.id, text: draft.text, source: BangerSource.me)
            let existing = Set(document.tasks.map(\.id))
            while existing.contains(task.id) { task.id = BangerTask.newID() }
            document.tasks.append(task)
        }
    }

    private func saveFinished(_ draft: QuickAddDraft, _ result: Result<Void, Error>) {
        switch result {
        case .success:
            // Immediate, not coalesced: they just added it and are looking for it.
            WidgetReloader.shared.reloadNow()

        case .failure(let error):
            // The error, not the text: the task text stays out of the system log.
            NSLog("Banger: quick-add could not save a task: %@", error.localizedDescription)
            lastFailure = Self.describe(error)
            unsaved.append(draft)
            NSSound.beep()

            guard let panel else { return }
            if panel.isVisible && !panel.isShowingNotice {
                // Still in the panel (⇧Return). Back into the field if it is free;
                // otherwise say so, and it comes back once this line is added.
                restoreNextDraftIfFree()
                if restored == nil {
                    panel.showProblem("\(Self.unsavedCount(unsaved.count)) not saved (\(lastFailure))"
                                      + " — back in the field after this one")
                }
            } else {
                showNotice()
            }
        }
    }

    /// Puts the oldest failed draft back in the field, if the field is empty and nothing
    /// is there already.
    private func restoreNextDraftIfFree() {
        guard let panel, restored == nil, !unsaved.isEmpty,
              panel.fieldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let draft = unsaved.removeFirst()
        restored = draft
        panel.setFieldText(draft.text)
        var line = "not saved (\(lastFailure)) — return to try again"
        if !unsaved.isEmpty { line += "   ·   \(unsaved.count) more after it" }
        panel.showProblem(line)
    }

    /// The panel was closed when the save failed. Show it where it would be, with the
    /// text in it, but as a picture: not key, not activated, so whatever they are typing
    /// into keeps the keyboard. A click on it, or ⌃⌥⌘N, opens it for real.
    private func showNotice() {
        guard let panel, let draft = unsaved.first else { return }
        noticeHide?.cancel()
        if !panel.isShowingNotice {
            panel.setFieldText(draft.text)
            panel.positionForDisplay()
            panel.prepareToShow(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        panel.showProblem("\(Self.unsavedCount(unsaved.count)) not saved (\(lastFailure))"
                          + " — ⌃⌥⌘N to try again")
        panel.showNotice()
        // The notice never takes focus, so VoiceOver would not otherwise read it.
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: "Task not saved. Press Control Option Command N to try again.",
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
        let hide = DispatchWorkItem {
            MainActor.assumeIsolated { QuickAdd.shared.endNotice(hide: true) }
        }
        noticeHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + noticeDuration, execute: hide)
    }

    /// Leaves notice mode. The drafts stay in `unsaved` either way.
    private func endNotice(hide: Bool) {
        noticeHide?.cancel()
        noticeHide = nil
        guard let panel, panel.isShowingNotice else { return }
        panel.endNotice()
        panel.clearField()
        panel.showProblem(nil)
        if hide { panel.orderOut(nil) }
    }

    private static func unsavedCount(_ count: Int) -> String {
        count == 1 ? "1 task" : "\(count) tasks"
    }

    /// A few words a person can act on. The full error is in the log.
    nonisolated static func describe(_ error: Error) -> String {
        switch error as? TaskStoreError {
        case .coordination?:         return "the list was busy"
        case .decode?:               return "tasks.json can't be read"
        case .containerUnavailable?: return "the Banger folder can't be reached"
        default:                     return "it couldn't be written"
        }
    }

    private func dismiss() {
        // A failed draft still in the field survives Escape and a click away; only
        // emptying the field (or saving it) lets it go.
        if let restored, let panel,
           !panel.fieldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            unsaved.insert(restored, at: 0)
        }
        restored = nil
        panel?.showProblem(nil)
        panel?.clearField()
        panel?.orderOut(nil)
        // Hand focus back explicitly rather than hoping deactivate picks the right
        // window. Without this the front app changes underneath the user.
        if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate()
        } else {
            NSApp.deactivate()
        }
        previousApp = nil
    }

    // MARK: Carbon hot key

    /// RegisterEventHotKey reserves the combination with the window server. Unlike
    /// a global NSEvent monitor it is not a tap on other applications' input, so it
    /// needs no Accessibility grant and works from a background agent immediately.
    @discardableResult
    private func registerHotKey() -> Bool {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(),
                                  quickAddHotKeyHandler,
                                  1, &eventType, context, &handlerRef) == noErr else {
            return false
        }

        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        guard RegisterEventHotKey(Self.keyN, modifiers, id,
                                  GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            return false
        }
        return true
    }

    fileprivate func hotKeyFired() { present() }
}

/// Carbon wants a C function. It is dispatched on the main run loop, which is why
/// assuming main-actor isolation here is sound rather than hopeful.
private func quickAddHotKeyHandler(_ callRef: EventHandlerCallRef?,
                                   _ event: EventRef?,
                                   _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }

    var id = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr, id.signature == 0x424E_4751 else {
        return OSStatus(eventNotHandledErr)
    }

    let quickAdd = Unmanaged<QuickAdd>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { quickAdd.hotKeyFired() }
    return noErr
}

// MARK: - Panel

@MainActor
final class QuickAddPanel: NSPanel, NSTextFieldDelegate {

    private let field = QuickAddField()
    private let hint = NSTextField(labelWithString: QuickAddPanel.defaultHint)
    private let container = NSView()
    private let onCommit: (String, Bool) -> Void
    private let onCancel: () -> Void
    private let onNoticeClicked: () -> Void

    private static let defaultHint = "return to add   ·   esc to close"

    /// On screen as a "not saved" notice: visible, never key, a click opens it for real.
    private(set) var isShowingNotice = false

    private static let panelWidth: CGFloat = 560
    private static let panelHeight: CGFloat = 78

    init(onCommit: @escaping (String, Bool) -> Void,
         onCancel: @escaping () -> Void,
         onNoticeClicked: @escaping () -> Void = {}) {
        self.onCommit = onCommit
        self.onCancel = onCancel
        self.onNoticeClicked = onNoticeClicked
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
                   // .nonactivatingPanel keeps the panel from dragging a full app
                   // activation behind it; .borderless removes the title bar.
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .modalPanel
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // An accessory app has no windows in its (absent) menu; make sure this one
        // never shows up in window cycling or restoration.
        isExcludedFromWindowsMenu = true

        buildContent()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Content

    private func buildContent() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        effect.translatesAutoresizingMaskIntoConstraints = false

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = NSColor(srgbRed: 0.05, green: 0.85, blue: 0.75, alpha: 1).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 21, weight: .medium)
        field.textColor = .labelColor
        field.placeholderAttributedString = NSAttributedString(
            string: "What's the next one?",
            attributes: [.font: NSFont.systemFont(ofSize: 21, weight: .medium),
                         .foregroundColor: NSColor.tertiaryLabelColor])
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.translatesAutoresizingMaskIntoConstraints = false

        hint.font = .systemFont(ofSize: 10, weight: .medium)
        hint.textColor = .quaternaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.cell?.truncatesLastVisibleLine = true
        hint.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(effect)
        effect.addSubview(dot)
        effect.addSubview(field)
        effect.addSubview(hint)
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView = container

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            dot.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 22),
            dot.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            field.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -22),
            field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 18),

            hint.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: field.trailingAnchor),
            hint.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 4),
            hint.bottomAnchor.constraint(lessThanOrEqualTo: effect.bottomAnchor, constant: -8)
        ])
    }

    // MARK: Showing

    func positionForDisplay() {
        // The screen with the pointer on it, not the main one: they may have more than one
        // and the panel should appear where they are looking.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let x = frame.midX - Self.panelWidth / 2
        // Slightly above centre, where every summoned field on this platform sits.
        let y = frame.minY + frame.height * 0.60
        setFrame(NSRect(x: x.rounded(), y: y.rounded(),
                        width: Self.panelWidth, height: Self.panelHeight),
                 display: false)
    }

    func prepareToShow(reduceMotion: Bool) {
        contentView?.wantsLayer = true
        guard !reduceMotion else {
            contentView?.layer?.transform = CATransform3DIdentity
            alphaValue = 1
            return
        }
        alphaValue = 1
        guard let layer = contentView?.layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.frame = contentView?.bounds ?? layer.frame
        layer.transform = CATransform3DMakeScale(0.965, 0.965, 1)
        CATransaction.begin()
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 0.965
        animation.toValue = 1.0
        animation.duration = 0.13
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.transform = CATransform3DIdentity
        layer.add(animation, forKey: "quickAddIn")
        CATransaction.commit()
    }

    /// Show the panel once, far offscreen and fully transparent, so the window
    /// server allocates its backing surface and Core Animation builds its layers
    /// before anybody is waiting. Costs one frame at login and nothing after.
    func prewarm() {
        let parked = NSRect(x: -20_000, y: -20_000, width: Self.panelWidth, height: Self.panelHeight)
        setFrame(parked, display: false)
        alphaValue = 0
        orderFront(nil)
        displayIfNeeded()
        orderOut(nil)
        alphaValue = 1
    }

    func focusField() {
        makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
    }

    func clearField() {
        field.stringValue = ""
    }

    var fieldText: String { field.stringValue }

    func setFieldText(_ text: String) {
        field.stringValue = text
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }

    /// nil puts the usual hint back. A message replaces it, in a colour that reads as
    /// "this needs you" without shouting.
    func showProblem(_ message: String?) {
        hint.stringValue = message ?? Self.defaultHint
        hint.textColor = message == nil ? .quaternaryLabelColor : .systemOrange
    }

    // MARK: Notice

    /// Onscreen without becoming key and without activating the app, so the keyboard
    /// stays wherever the user is typing.
    func showNotice() {
        isShowingNotice = true
        orderFrontRegardless()
    }

    func endNotice() {
        isShowingNotice = false
    }

    override func sendEvent(_ event: NSEvent) {
        // In notice mode a click is "open it", and must not make the panel key on its own:
        // that would skip recording who had focus and activating properly.
        if isShowingNotice, event.type == .leftMouseDown || event.type == .rightMouseDown {
            onNoticeClicked()
            return
        }
        super.sendEvent(event)
    }

    // MARK: Keys

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let keepOpen = NSEvent.modifierFlags.contains(.shift)
            onCommit(field.stringValue, keepOpen)
            return true
        case #selector(NSResponder.cancelOperation(_:)),
             #selector(NSResponder.complete(_:)):
            onCancel()
            return true
        default:
            return false
        }
    }

    /// Clicking away is a cancel. Without this the panel would sit there after the user
    /// has already moved on, which is exactly the interruption it must never be.
    override func resignKey() {
        super.resignKey()
        if isVisible { onCancel() }
    }
}

/// Escape reaches a borderless panel's field as `cancelOperation:` only when the
/// window declines to treat it as a close; this makes that explicit rather than
/// depending on the default responder chain.
private final class QuickAddField: NSTextField {
    override func cancelOperation(_ sender: Any?) {
        (window as? QuickAddPanel)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    }
}
