//  TaskPeek.swift — the whole of a task, next to the widget, for as long as you look at it.
//
//  A widget row is one line, so a long task ends in "…". Tapping the words sends
//  PeekTaskIntent (Sources/BangerWidget/PeekTaskIntent.swift), and this puts the full
//  text up in a small card beside the widget. A widget cannot draw outside its own
//  rectangle, which is why the card lives here, in the agent — the same arrangement as
//  QuickAdd's field.
//
//  HOW THE TAP GETS HERE. Two routes, first one wins, and a request id makes sure a tap
//  that arrives both ways is still one tap:
//
//   - peek-request.json, written beside tasks.json by the widget extension. This is the
//     one that is known to work: the sandboxed extension can write into that folder (it
//     already writes the check-off there) and this process is not sandboxed. A vnode
//     source on the folder sees the file land. It is a second watch on the same folder
//     as TaskFileWatcher's rather than a hook into it, because that engine exists to
//     diff the task list and is careful about exactly when it reads it; a request file
//     has nothing to do with either.
//   - the distributed notification the widget also posts, as the + does. A sandboxed
//     extension with no app group is probably not allowed to post it (README.md), but
//     where it does get through it is a few milliseconds sooner.
//
//  Only the task's id travels. The text is read from tasks.json here, off the main
//  thread, so it is the current text and it is never in a notification or a log.
//
//  DESIGN CONSTRAINTS:
//
//   - It never takes focus. Unlike QuickAdd there is nothing to type, so the card is a
//     non-activating panel that never becomes key and never activates Banger: whatever
//     the user was typing into keeps the keyboard the whole time, and there is nothing
//     to hand back when it closes.
//   - It goes away on its own terms: a click anywhere else, a click on the card, or
//     Escape. Escape is a Carbon hot key held only while the card is up, because a
//     window that is never key never sees a key press and a global key monitor would
//     need an Accessibility grant. While the card is up, Escape closes the card and
//     nothing else.
//   - Tapping the same task again closes it; tapping another task shows that one.
//     A click on the widget is also "a click somewhere else", and it arrives before
//     the tap's intent does, so the card has already closed by the time the request
//     lands. The request is therefore compared with what just closed: the same task
//     within a moment of a click-away means the tap was the click that closed it, and
//     it stays closed; a different task opens straight away, with no entrance, so it
//     reads as the card changing rather than as one card leaving and another arriving.
//   - It sits beside the widget, not in the middle of the screen. The desktop widgets
//     are ordinary windows belonging to the system's widget host, and their frames are
//     public, so the card finds the one under the pointer — the one just tapped — and
//     sits to its left with its first line level with the row. With no widget found it
//     falls back to the pointer, on the pointer's screen, as QuickAdd does.
//   - Nothing on it but the words. No edit, no delete, no buttons.

import AppKit
import Carbon.HIToolbox
import SwiftUI
import BangerKit

// MARK: - Signal

/// Kept in step by hand with the copy in Sources/BangerWidget/PeekTaskIntent.swift.
enum TaskPeekSignal {
    static let plain = Notification.Name("com.bangerwidget.banger.peek")
    static let groupPrefixed = Notification.Name("group.com.bangerwidget.banger.peek")
    static let requestFileName = "peek-request.json"

    struct Request: Codable, Sendable, Equatable {
        var id: String
        var taskID: String
        var at: Double
    }

    /// The notification's `object`: "<request id> <task id>". Task ids never contain a
    /// space (BangerTask.newID), so one split is unambiguous.
    static func request(fromNotificationObject object: Any?) -> Request? {
        guard let string = object as? String else { return nil }
        let parts = string.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return Request(id: parts[0], taskID: parts[1], at: Date().timeIntervalSince1970)
    }
}

// MARK: - TaskPeek

@MainActor
final class TaskPeek {

    static let shared = TaskPeek()

    private var panel: TaskPeekPanel?
    private var observers: [NSObjectProtocol] = []
    private var watcher: PeekRequestWatcher?
    private let escape = HotKeyMonitor()
    private var clickMonitors: [Any] = []
    /// While the card is up: another app coming to the front closes it, so Escape is
    /// not held system-wide after the user has moved on. See armDismissal.
    private var activationObserver: NSObjectProtocol?
    private var frontAtShow: pid_t?
    private var installed = false

    /// The task on the card right now.
    private var showing: String?
    /// What a click elsewhere last closed, and when. See "Tapping the same task again".
    private var clickedAway: (taskID: String, at: Date)?
    /// How long after a click-away a tap on the same task still counts as that click.
    /// Measured to the tap's own time stamp (`Request.at`, taken by the intent), not to
    /// when the request is finally handled, so a slow storage read cannot turn a
    /// closing tap into a reopening one. Wide enough for a cold widget extension.
    private let clickAwayWindow: TimeInterval = 3
    /// Requests found this late are left alone: the moment for them has passed.
    private let staleAfter: TimeInterval = 10

    /// Request ids already acted on, newest last. A tap arrives up to twice.
    private var handled: [String] = []

    private init() {}

    // MARK: Install

    /// Idempotent. Call once from applicationDidFinishLaunching.
    func install(store: TaskStore = .shared) {
        guard !installed else { return }
        installed = true

        let panel = TaskPeekPanel { [weak self] in self?.close(clickedAway: false) }
        panel.prewarm()
        self.panel = panel

        let center = DistributedNotificationCenter.default()
        observers = [TaskPeekSignal.groupPrefixed, TaskPeekSignal.plain].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let request = TaskPeekSignal.request(fromNotificationObject: note.object)
                MainActor.assumeIsolated {
                    if let request { TaskPeek.shared.received(request) }
                }
            }
        }

        let watcher = PeekRequestWatcher(
            url: store.containerURL.appendingPathComponent(TaskPeekSignal.requestFileName,
                                                           isDirectory: false),
            onBaseline: { id in
                // Whatever request is already on disk at launch is from before: never
                // replay it. Arrives on main before any later request can.
                MainActor.assumeIsolated { TaskPeek.shared.remember(id) }
            },
            onRequest: { request in
                MainActor.assumeIsolated { TaskPeek.shared.received(request) }
            })
        self.watcher = watcher
        watcher.start()
    }

    func uninstall() {
        close(clickedAway: false)
        let center = DistributedNotificationCenter.default()
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
        watcher?.stop()
        watcher = nil
        panel?.orderOut(nil)
        panel = nil
        installed = false
    }

    // MARK: Requests

    private func remember(_ id: String) {
        handled.append(id)
        if handled.count > 32 { handled.removeFirst(handled.count - 32) }
    }

    private func received(_ request: TaskPeekSignal.Request) {
        guard !handled.contains(request.id) else { return }
        remember(request.id)
        guard Date().timeIntervalSince1970 - request.at < staleAfter else { return }

        // The text comes from the list itself, on the storage queue like every other
        // read the agent makes of it.
        let taskID = request.taskID, requestedAt = request.at
        StorageQueue.shared.async {
            let task = (try? TaskStore.shared.peek())?.tasks.first { $0.id == taskID }
            guard let task else { return }   // gone since the widget drew it: nothing to show
            let text = task.text, done = task.done
            DispatchQueue.main.async {
                MainActor.assumeIsolated { TaskPeek.shared.toggle(taskID: taskID, text: text, done: done,
                                                               requestedAt: requestedAt) }
            }
        }
    }

    private func toggle(taskID: String, text: String, done: Bool, requestedAt: Double) {
        guard let panel else { return }

        if panel.isVisible {
            if showing == taskID {
                close(clickedAway: false)
            } else {
                show(taskID: taskID, text: text, done: done, entrance: false)
            }
            return
        }

        // Closed. If a click elsewhere closed it a moment ago, that click was very likely
        // this very tap on the widget, on its way here.
        var entrance = true
        // The tap is stamped a little after its own mouse-down closed the card, never
        // much before it; a small negative lag allows for the two clocks' rounding.
        if let away = clickedAway {
            clickedAway = nil
            let lag = requestedAt - away.at.timeIntervalSince1970
            if lag > -0.25 && lag < clickAwayWindow {
                if away.taskID == taskID { return }
                entrance = false
            }
        }
        show(taskID: taskID, text: text, done: done, entrance: entrance)
    }

    // MARK: Show / close

    private func show(taskID: String, text: String, done: Bool, entrance: Bool) {
        guard let panel else { return }
        showing = taskID
        panel.setContent(text: text, done: done)
        panel.place(near: NSEvent.mouseLocation)
        panel.present(animated: entrance && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        frontAtShow = NSWorkspace.shared.frontmostApplication?.processIdentifier
        armDismissal()

        // Never key, so VoiceOver would not otherwise know it arrived.
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
    }

    /// Closes the card without any tap bookkeeping. QuickAdd calls it as it opens, so
    /// its Escape cancels QuickAdd instead of closing a card left up behind it.
    func dismiss() {
        close(clickedAway: false)
    }

    private func close(clickedAway away: Bool) {
        guard let panel, panel.isVisible || showing != nil else { return }
        // Only a click on a desktop widget can be a tap on its way here. A click on the
        // desktop or in another app just closes the card; recording it would swallow a
        // deliberate tap on the same task a moment later.
        if away, let showing, TaskPeekPanel.widgetFrame(containing: NSEvent.mouseLocation) != nil {
            clickedAway = (showing, Date())
        }
        showing = nil
        panel.orderOut(nil)
        disarmDismissal()
    }

    /// Only while the card is up: a click anywhere, and Escape.
    private func armDismissal() {
        guard clickMonitors.isEmpty else { return }
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other applications, the widget included. Mouse events need no
        // Accessibility grant to be observed; only key events do.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouseDown, handler: { _ in
            MainActor.assumeIsolated { TaskPeek.shared.close(clickedAway: true) }
        }) {
            clickMonitors.append(global)
        }
        // Clicks in this app's other windows (QuickAdd's field). A click on the card
        // itself is the panel's, and closes it through onClick.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouseDown, handler: { event in
            MainActor.assumeIsolated {
                let peek = TaskPeek.shared
                if event.window !== peek.panel { peek.close(clickedAway: true) }
            }
            return event
        }) {
            clickMonitors.append(local)
        }
        escape.register(keyCode: UInt32(kVK_Escape), modifiers: []) {
            TaskPeek.shared.close(clickedAway: false)
        }
        // Escape is a system-wide hot key while the card is up. Cmd-Tab to another app
        // and the card goes, and Escape with it, instead of the first Escape typed
        // there being swallowed. The app in front when the card appeared does not count.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            MainActor.assumeIsolated {
                let peek = TaskPeek.shared
                if pid != peek.frontAtShow { peek.close(clickedAway: false) }
            }
        }
    }

    private func disarmDismissal() {
        for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
        clickMonitors.removeAll()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        frontAtShow = nil
        escape.unregister()
    }
}

// MARK: - Request file watcher

/// Watches the container folder for peek-request.json being written. Everything here
/// runs on `StorageQueue.shared` and nowhere else, which is what the `@unchecked
/// Sendable` rests on — the same arrangement as TaskFileWatchEngine.
final class PeekRequestWatcher: @unchecked Sendable {

    private let url: URL
    private let queue: DispatchQueue
    private let onBaseline: @Sendable (String) -> Void
    private let onRequest: @Sendable (TaskPeekSignal.Request) -> Void

    private var source: (any DispatchSourceFileSystemObject)?
    private var retry: DispatchWorkItem?
    private var lastStamp: TaskFileStamp?
    private var stopped = true

    /// Delivers on the main queue.
    init(url: URL,
         queue: DispatchQueue = StorageQueue.shared,
         onBaseline: @escaping @Sendable (String) -> Void,
         onRequest: @escaping @Sendable (TaskPeekSignal.Request) -> Void) {
        self.url = url
        self.queue = queue
        self.onBaseline = onBaseline
        self.onRequest = onRequest
    }

    func start() {
        queue.async { [self] in
            guard stopped else { return }
            stopped = false
            // The request already on disk is the baseline, never a tap.
            lastStamp = TaskFileStamp.read(path: url.path)
            if let existing = read() {
                let baseline = onBaseline
                DispatchQueue.main.async { baseline(existing.id) }
            }
            arm()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            retry?.cancel(); retry = nil
            source?.cancel(); source = nil
        }
    }

    private func arm() {
        source?.cancel(); source = nil
        guard !stopped else { return }
        let directory = url.deletingLastPathComponent()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            // Not there yet (a fresh install before the first task). Look again shortly.
            let again = DispatchWorkItem { [weak self] in self?.arm() }
            retry = again
            queue.asyncAfter(deadline: .now() + 5, execute: again)
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            if !src.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                // The folder itself moved or went away: watch whatever is there now.
                self.arm()
            }
            self.check()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    /// Every file in the folder moving lands here (the list, the lock, the receipts), so
    /// the request file's stamp is checked first and nothing is read unless it moved.
    private func check() {
        let stamp = TaskFileStamp.read(path: url.path)
        guard let stamp, stamp != lastStamp else { return }
        lastStamp = stamp
        guard let request = read() else { return }
        let deliver = onRequest
        DispatchQueue.main.async { deliver(request) }
    }

    private func read() -> TaskPeekSignal.Request? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(TaskPeekSignal.Request.self, from: data)
    }
}

// MARK: - Panel

@MainActor
final class TaskPeekPanel: NSPanel {

    private let host = NSHostingView(rootView: TaskPeekCard(text: "", done: false))
    /// Measures the card. The hosting view is sized by this window, not the other way
    /// round, so it is not asked.
    private let measure = NSHostingController(rootView: TaskPeekCard(text: "", done: false))
    private let onClick: () -> Void

    /// Between the card and the widget's edge.
    private static let gap: CGFloat = 10
    /// From the card's top edge to the middle of its first line: 12 of padding plus
    /// half a line of 14-point text.
    private static let firstLineMiddle: CGFloat = 21

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(contentRect: NSRect(x: 0, y: 0, width: TaskPeekCard.maxWidth, height: 44),
                   // Non-activating and never key: see canBecomeKey.
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isExcludedFromWindowsMenu = true
        host.sizingOptions = []
        contentView = host
    }

    /// The whole point: whatever the user is typing into keeps the keyboard.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setContent(text: String, done: Bool) {
        host.rootView = TaskPeekCard(text: text, done: done)
        measure.rootView = host.rootView
    }

    /// Beside the widget under `point` (Cocoa global coordinates), first line level with
    /// the pointer. Left of the widget by preference — the widget sits top right — then
    /// right of it, then over it.
    func place(near point: NSPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = measure.sizeThatFits(in: CGSize(width: TaskPeekCard.maxWidth,
                                                   height: CGFloat.greatestFiniteMagnitude))
        let height = min(size.height, visible.height - 16)
        let width = size.width
        let anchor = Self.widgetFrame(containing: point)
            ?? NSRect(x: point.x - 12, y: point.y, width: 24, height: 0)

        var x = anchor.minX - Self.gap - width
        if x < visible.minX + 8 { x = anchor.maxX + Self.gap }
        if x + width > visible.maxX - 8 { x = anchor.midX - width / 2 }
        x = min(max(x, visible.minX + 8), visible.maxX - 8 - width)

        let top = point.y + Self.firstLineMiddle
        var y = top - height
        y = min(max(y, visible.minY + 8), visible.maxY - 8 - height)

        setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height), display: true)
    }

    /// The desktop widget the pointer is over. Desktop widgets are windows of the
    /// system's widget host drawn just above the desktop, so: not ours, below the normal
    /// window level (or owned by the widget host, for when the desktop is revealed and
    /// they come forward), widget-sized, and containing the point. Frames need no
    /// permission to read; only window titles would, and they are not used.
    static func widgetFrame(containing point: NSPoint) -> NSRect? {
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        var best: NSRect?
        for window in list {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"],
                  let left = bounds["X"], let topY = bounds["Y"],
                  w >= 100, h >= 100, w <= 820, h <= 820 else { continue }
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            guard layer < 0 || owner == "Notification Center" else { continue }
            // Window-server frames are top-left of the primary display, y down.
            let frame = NSRect(x: left, y: primary.frame.maxY - topY - h, width: w, height: h)
            guard frame.contains(point) else { continue }
            if best == nil || frame.width * frame.height < best!.width * best!.height { best = frame }
        }
        return best
    }

    func present(animated: Bool) {
        guard animated else {
            alphaValue = 1
            orderFrontRegardless()
            return
        }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// Shown once far offscreen at launch so the first tap does not pay for the window
    /// server building its surface. The same trick as QuickAddPanel.prewarm.
    func prewarm() {
        setFrame(NSRect(x: -20_000, y: -20_000, width: TaskPeekCard.maxWidth, height: 44), display: false)
        alphaValue = 0
        orderFrontRegardless()
        displayIfNeeded()
        orderOut(nil)
        alphaValue = 1
    }

    override func sendEvent(_ event: NSEvent) {
        // A click on the card closes it. Nothing on it does anything else.
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            onClick()
            return
        }
        super.sendEvent(event)
    }
}
