import Foundation
import CoreGraphics
import AppKit

class EventHandler {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let settings: SettingsStore
    private let logStore: LogStore
    private let captureDiagnostics = CaptureDiagnostics()
    private var captureTraceID = 0

    private var isDragging = false
    private var mouseDownPoint: CGPoint?
    private var lastAutoCopyTriggerTime: TimeInterval = 0
    private let autoCopyDebounceSeconds: TimeInterval = 0.3

    // Click state captured on leftMouseDown. Some apps don't surface the
    // multi-click state reliably on the matching leftMouseUp, so we track it
    // ourselves from the down event.
    private var lastClickState: Int64 = 1

    // Each captureSelectionToPrimary call bumps this; pending captures check it
    // to bail out if a newer click (e.g. triple-click after double-click)
    // wants to overwrite the selection.
    private var captureGeneration: Int = 0

    // The PRIMARY selection itself is not stored here: see PrimaryPasteboard,
    // which keeps it in the system-wide "Selection" pasteboard. It is still
    // NOT the system clipboard — Cmd+C content is snapshotted and restored
    // around every capture and paste.

    // Tracks which mouse-down events we swallowed so we can also swallow the
    // matching mouse-up. Without this, the OS would see an "up without down"
    // for the intercepted side button and might still react to it.
    private var swallowedDownButtons: Set<Int64> = []

    // Apps that maintain the PRIMARY selection themselves, so we should keep
    // out of their way in both directions. GNU Emacs publishes its region via
    // select-active-regions and binds mouse-2 to mouse-yank-primary, which
    // inserts PRIMARY at the click position - both better than anything we can
    // synthesize, and both broken by us intervening. See selfManagesPrimary.
    private static let selfManagedPrimaryBundleIDs: Set<String> = [
        "org.gnu.Emacs" // Cocoa/NS port, including emacs-plus and emacs-mac
    ]

    // AX calls block the caller, and an unresponsive target would otherwise
    // stall us for the default timeout. A quarter second is plenty for a
    // healthy app.
    private static let axTimeoutSeconds: Float = 0.25

    /// Raises the clicked window within its app, then brings the app forward.
    /// Both halves matter: activating an app raises whichever window was last
    /// frontmost, which for a multi-window app is often not the one clicked.
    @discardableResult
    func focus(pid: pid_t, windowContaining point: CGPoint) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, Self.axTimeoutSeconds)

        var rawWindows: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &rawWindows) == .success,
           let windows = rawWindows as? [AXUIElement] {
            for window in windows where axFrame(of: window)?.contains(point) == true {
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                break
            }
        }

        // kAXFrontmost is the Accessibility route to the front and works from a
        // background agent like us, which is why it is tried first; we already
        // hold the permission for the event tap.
        if AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success {
            return true
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        if #available(macOS 14.0, *) {
            return app.activate()
        }
        return app.activate(options: [])
    }

    /// An AX window's frame in global top-left-origin coordinates, or nil if
    /// the app does not report a usable position and size.
    func axFrame(of window: AXUIElement) -> CGRect? {
        // Concrete types rather than a generic helper: AXValueGetValue writes
        // through a raw pointer, so the destination must be a plain struct.
        func axValue(_ attribute: String) -> AXValue? {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, attribute as CFString, &raw) == .success,
                  let raw = raw, CFGetTypeID(raw) == AXValueGetTypeID()
            else { return nil }
            return (raw as! AXValue)
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let rawOrigin = axValue(kAXPositionAttribute),
              AXValueGetValue(rawOrigin, .cgPoint, &origin),
              let rawSize = axValue(kAXSizeAttribute),
              AXValueGetValue(rawSize, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // How far above the clicked element to look for a control. Browsers hand
    // back the AXStaticText inside a link, a tab or the URL bar - all three
    // report exactly that role - and put the interactive role on an ancestor,
    // so the ancestry is the only thing that tells them apart. Very little
    // depth is needed: the interactive role has been the immediate parent in
    // every case seen so far.
    private static let controlAncestorDepth = 4

    // Controls the app has its own use for the middle button on, so the click
    // should reach it rather than paste over it: a link opens in a new tab, a
    // browser tab closes. Firefox exposes each of its tabs as an
    // AXRadioButton. Deliberately not AXTabGroup: matching the group as well
    // would add nothing - the button is always found first - while suppressing
    // paste anywhere inside a tabbed app's content.
    private static let appHandledMiddleClickRoles: Set<String> = [
        "AXLink",
        "AXRadioButton",
    ]

    /// The control at or above `point` that the app should handle the
    /// middle-click on, plus the roles walked to find it. The chain is
    /// returned either way so a control we do not yet recognise can be
    /// identified from the debug console rather than guessed at.
    ///
    /// Deliberately shallow - a hit test plus a few parent lookups, not the
    /// full descent caretTarget performs - because this runs inside the tap
    /// callback. An app exposing no accessibility tree answers nothing, so this
    /// only ever adds behaviour.
    private func appHandledControl(at point: CGPoint) -> (matched: String?, chain: [String]) {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, Self.axTimeoutSeconds)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit = hit
        else { return (nil, []) }

        var chain: [String] = []
        var current = hit
        for _ in 0..<Self.controlAncestorDepth {
            let r = role(of: current)
            chain.append(r)
            if Self.appHandledMiddleClickRoles.contains(r) { return (r, chain) }
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &raw) == .success,
                  let raw = raw, CFGetTypeID(raw) == AXUIElementGetTypeID()
            else { return (nil, chain) }
            current = raw as! AXUIElement
        }
        return (nil, chain)
    }

    /// The app owning the topmost ordinary window containing `point`, and
    /// whether that window is already the frontmost one of its app.
    ///
    /// Coordinates are global and top-left origin, matching CGEvent.location
    /// and kCGWindowBounds, so they compare directly. Only the owner name is
    /// read, never kCGWindowName, so this needs no Screen Recording
    /// permission.
    func windowOwner(
        under point: CGPoint
    ) -> (pid: pid_t, bundleID: String?, name: String, isFrontWindowOfApp: Bool)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        // The list runs front to back, so the first window containing the point
        // is the one the user clicked, and any earlier window with the same pid
        // means the clicked one is not that app's frontmost.
        var pidsSeenInFront = Set<pid_t>()
        for window in windows {
            guard let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPid,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            if frame.contains(point) {
                let app = NSRunningApplication(processIdentifier: pid)
                let name = window[kCGWindowOwnerName as String] as? String
                    ?? app?.localizedName
                    ?? "pid \(pid)"
                return (pid, app?.bundleIdentifier, name, !pidsSeenInFront.contains(pid))
            }
            pidsSeenInFront.insert(pid)
        }
        return nil
    }

    init(settings: SettingsStore, logStore: LogStore) {
        self.settings = settings
        self.logStore = logStore
    }

    func start() {
        if eventTap != nil {
            logStore.add("CGEventTap already running; start() ignored")
            return
        }
        logStore.add("Starting CGEventTap...")

        let eventMask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: EventHandler.tapCallback,
            userInfo: userInfo
        ) else {
            logStore.add("ERROR: Failed to create CGEventTap. Accessibility permission missing?")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source

        logStore.add("CGEventTap installed successfully.")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                CFRunLoopSourceInvalidate(source)
            }
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        swallowedDownButtons.removeAll()
        isDragging = false
        mouseDownPoint = nil
        lastClickState = 1
        logStore.add("CGEventTap removed.")
    }

    // C-compatible trampoline. Must not capture anything; we recover `self`
    // from the userInfo pointer we passed to tapCreate.
    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo = userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let handler = Unmanaged<EventHandler>.fromOpaque(userInfo).takeUnretainedValue()
        return handler.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logStore.add("CGEventTap disabled (type=\(type.rawValue)); re-enabling")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard settings.isEnabled else {
            return Unmanaged.passUnretained(event)
        }

        // Pass the caret clicks we synthesize ourselves straight through
        // without touching selection state, so they can never be mistaken for
        // a user selection. See clickToPlaceCaret.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticClickUserData {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            // Track the click state here: it is reliably set on mouse-down
            // across apps (the matching up event sometimes loses it).
            lastClickState = event.getIntegerValueField(.mouseEventClickState)
            mouseDownPoint = event.location
            isDragging = false
            return Unmanaged.passUnretained(event)

        case .leftMouseDragged:
            isDragging = true
            return Unmanaged.passUnretained(event)

        case .leftMouseUp:
            let isMultiClick = lastClickState >= 2
            let wasDragging = isDragging
            let triggerCopy = wasDragging || isMultiClick
            let gesture = CaptureGesture(
                start: mouseDownPoint, end: event.location,
                clickCount: lastClickState, dragged: wasDragging
            )
            isDragging = false
            mouseDownPoint = nil

            if settings.autoCopyOnSelect && triggerCopy {
                let now = Date().timeIntervalSince1970
                let withinDebounce = (now - lastAutoCopyTriggerTime) < autoCopyDebounceSeconds
                // Drags are debounced; multi-clicks always go through so
                // triple-click can overwrite a pending double-click capture.
                if !withinDebounce || isMultiClick {
                    lastAutoCopyTriggerTime = now
                    // Defer real work so the tap callback returns immediately
                    // and macOS does not disable the tap for "running too long".
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.captureSelectionToPrimary(gesture: gesture)
                    }
                } else if settings.showLogs {
                    DispatchQueue.main.async { [weak self] in
                        self?.logStore.add("PRIMARY: \(gesture.description); skipped: drag debounce")
                    }
                }
            } else if settings.showLogs && triggerCopy {
                DispatchQueue.main.async { [weak self] in
                    self?.logStore.add("PRIMARY: \(gesture.description); skipped: auto-copy disabled")
                }
            }
            return Unmanaged.passUnretained(event)

        case .otherMouseDown:
            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)

            // Mic mute on the configured side button - intercept and swallow.
            if settings.enableMicMute && Int(buttonNumber) == settings.micMuteButton {
                swallowedDownButtons.insert(buttonNumber)
                DispatchQueue.main.async { [weak self] in
                    self?.logStore.add("Action: mic mute button \(buttonNumber) intercepted")
                    self?.toggleMicrophone()
                }
                return nil
            }

            // Middle-click paste: ONLY true middle button (== 2), never the
            // configured mic button. We MUST swallow the event so apps with
            // their own middle-click paste (Terminal.app with the middle
            // paste pref enabled, X11-aware apps, etc.) do not paste a second
            // time on top of our Cmd+V (issue #1).
            if settings.middleClickPaste && buttonNumber == 2 && Int(buttonNumber) != settings.micMuteButton {
                // Emacs binds mouse-2 to mouse-yank-primary, which sets point
                // at the click position and inserts PRIMARY there. Since
                // PRIMARY is now the shared "Selection" pasteboard, letting
                // the click through gives exactly the behaviour we are trying
                // to imitate - and more precisely than we can, because Emacs
                // exposes no accessibility tree for its buffer, so our
                // synthesized caret click has nothing to aim at and the paste
                // would land at the existing point instead.
                // Keyed on the window under the pointer, not the frontmost app,
                // so this also works when the Emacs window clicked is not the
                // frontmost one. That costs a CGWindowListCopyWindowInfo call
                // inside the tap callback, which the callback otherwise avoids
                // - acceptable only because it runs on middle-clicks alone, a
                // deliberate and infrequent gesture, rather than on every
                // mouse event.
                let clickLocation = event.location
                if let target = windowOwner(under: clickLocation),
                   let bundleID = target.bundleID,
                   Self.selfManagedPrimaryBundleIDs.contains(bundleID) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.logStore.add("Action: middle-click passed through to \(target.name), which pastes PRIMARY itself")
                        // A middle-click does not activate a window on macOS,
                        // so the target would paste while staying behind.
                        // Focus it ourselves, as a left-click would have.
                        if !(target.isFrontWindowOfApp
                             && NSRunningApplication(processIdentifier: target.pid)?.isActive == true) {
                            self.focus(pid: target.pid, windowContaining: clickLocation)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }

                // A middle-click the app has its own meaning for - opening a
                // link in a new tab, closing a browser tab - is a better use of
                // the button than a paste the user never aimed at a text field.
                let control = appHandledControl(at: clickLocation)
                if let matched = control.matched {
                    DispatchQueue.main.async { [weak self] in
                        self?.logStore.add("Action: middle-click on \(matched) passed through to the app")
                    }
                    return Unmanaged.passUnretained(event)
                }
                if !control.chain.isEmpty {
                    let chain = control.chain.joined(separator: " < ")
                    DispatchQueue.main.async { [weak self] in
                        self?.logStore.add("Action: middle-click over [\(chain)], no app-handled control, pasting")
                    }
                }

                swallowedDownButtons.insert(buttonNumber)
                // pasteFromPrimary needs the click location to focus the
                // window we clicked, since swallowing the event above denied
                // it the chance.
                DispatchQueue.main.async { [weak self] in
                    self?.logStore.add("Action: middle-click intercepted -> paste from PRIMARY")
                    self?.pasteFromPrimary(at: clickLocation)
                }
                return nil
            }

            return Unmanaged.passUnretained(event)

        case .otherMouseUp:
            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            if swallowedDownButtons.remove(buttonNumber) != nil {
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Pasteboard snapshot / restore

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private func snapshotPasteboard() -> PasteboardSnapshot {
        let pb = NSPasteboard.general
        guard let items = pb.pasteboardItems else {
            return PasteboardSnapshot(items: [])
        }
        var collected: [[NSPasteboard.PasteboardType: Data]] = []
        for item in items {
            var bag: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    bag[type] = data
                }
            }
            if !bag.isEmpty {
                collected.append(bag)
            }
        }
        return PasteboardSnapshot(items: collected)
    }

    @discardableResult
    private func restorePasteboard(_ snapshot: PasteboardSnapshot) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !snapshot.items.isEmpty else { return true }
        var rebuilt: [NSPasteboardItem] = []
        for bag in snapshot.items {
            let item = NSPasteboardItem()
            for (type, data) in bag {
                item.setData(data, forType: type)
            }
            rebuilt.append(item)
        }
        return pb.writeObjects(rebuilt)
    }

    // MARK: - PRIMARY selection (Linux-style)

    func captureSelectionToPrimary(gesture: CaptureGesture? = nil) {
        captureTraceID += 1
        let trace = CaptureTrace(id: captureTraceID)
        let sourceApp = NSWorkspace.shared.frontmostApplication
        logStore.add(trace.message("\(gesture?.description ?? "capture requested without mouse coordinates"); source=\(CaptureDiagnostics.application(sourceApp)); enabled=\(settings.isEnabled), autoCopy=\(settings.autoCopyOnSelect), diagnostics=\(settings.showLogs)"))
        guard settings.isEnabled, settings.autoCopyOnSelect,
              let sourceApp = sourceApp
        else {
            logStore.add(trace.message("skipped: disabled or no frontmost app"))
            return
        }

        // Emacs publishes its own region to PRIMARY via select-active-regions,
        // so our Cmd+C is redundant there - and harmful: it runs
        // ns-copy-including-secondary, i.e. kill-ring-save, which deactivates
        // the region the user just made and adds a kill-ring entry.
        //
        // This has to stay ahead of the generation bump below. Bumping
        // invalidates any in-flight capture, and that capture then skips its
        // own restorePasteboard() on the assumption that the newer one will
        // restore instead - so returning after a bump would leave the general
        // clipboard holding whatever the previous Cmd+C copied.
        if let bundleID = sourceApp.bundleIdentifier {
            if Self.selfManagedPrimaryBundleIDs.contains(bundleID) {
                logStore.add(trace.message("skipped: \(bundleID) publishes its own selection"))
                return
            }
        }

        let sourcePID = sourceApp.processIdentifier
        if settings.showLogs {
            captureDiagnostics.record(pid: sourcePID, gesture: gesture) { [weak self] message in
                self?.logStore.add(trace.message(message))
            }
        }
        captureGeneration += 1
        let myGen = captureGeneration
        // Give the host app a few frames to finalize the selection.
        // Double-click word selection (and triple-click line selection) often
        // only completes a tick AFTER mouseUp, so sending Cmd+C immediately
        // can land before the selection exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self = self else { return }
            // A newer capture (e.g. triple-click after this double-click)
            // already supersedes us; let it do the work.
            if myGen != self.captureGeneration {
                self.logStore.add(trace.message("skipped: generation \(myGen) superseded by \(self.captureGeneration)"))
                return
            }

            // Opening a document can switch apps during this delay. Cancel
            // before touching either pasteboard if the source has lost focus.
            let currentApp = NSWorkspace.shared.frontmostApplication
            guard self.settings.isEnabled, self.settings.autoCopyOnSelect,
                  currentApp?.processIdentifier == sourcePID
            else {
                self.logStore.add(trace.message("skipped before copy: frontmost=\(CaptureDiagnostics.application(currentApp)), enabled=\(self.settings.isEnabled), autoCopy=\(self.settings.autoCopyOnSelect)"))
                return
            }

            let pb = NSPasteboard.general
            self.logStore.add(trace.message("before clipboard snapshot: \(CaptureDiagnostics.clipboard(pb))"))
            let snapshot = self.snapshotPasteboard()
            let initialChangeCount = pb.changeCount
            // Snapshotting can wait for another app to provide clipboard
            // data. Recheck focus afterwards, and address Cmd+C to the source
            // process so a subsequent app switch cannot deliver it elsewhere.
            let appAfterSnapshot = NSWorkspace.shared.frontmostApplication
            guard appAfterSnapshot?.processIdentifier == sourcePID else {
                self.logStore.add(trace.message("skipped after clipboard snapshot: frontmost=\(CaptureDiagnostics.application(appAfterSnapshot))"))
                return
            }
            self.simulateCopy(to: sourcePID)
            self.logStore.add(trace.message("Cmd+C posted to pid=\(sourcePID); savedItems=\(snapshot.items.count), changeCount=\(initialChangeCount), timeout=300ms"))
            self.pollClipboardForCapture(
                trace: trace,
                sourcePID: sourcePID,
                generation: myGen,
                initialChangeCount: initialChangeCount,
                snapshot: snapshot,
                elapsedMs: 0
            )
        }
    }

    private func pollClipboardForCapture(trace: CaptureTrace, sourcePID: pid_t, generation: Int, initialChangeCount: Int, snapshot: PasteboardSnapshot, elapsedMs: Int) {
        // A newer capture took over; the newer poll will perform its own
        // restore, so just stop polling here.
        if generation != captureGeneration {
            logStore.add(trace.message("poll stopped: generation \(generation) superseded by \(captureGeneration); restore deferred to newer capture"))
            return
        }
        let pb = NSPasteboard.general
        let timeoutMs = 300
        let stepMs = 20

        if pb.changeCount != initialChangeCount {
            // Read the string and the change count back-to-back so the
            // restore-guard below can detect if anything else writes to the
            // pasteboard between our capture and our restore.
            let captured = pb.string(forType: .string)
            let postCopyChangeCount = pb.changeCount
            let frontmost = NSWorkspace.shared.frontmostApplication
            logStore.add(trace.message("clipboard changed after \(elapsedMs)ms polling: \(initialChangeCount) -> \(postCopyChangeCount); \(CaptureDiagnostics.clipboard(pb)); frontmost=\(CaptureDiagnostics.application(frontmost)), sourceStillFrontmost=\(frontmost?.processIdentifier == sourcePID)"))
            if let s = captured, !s.isEmpty {
                // Publish before restoring below, so PRIMARY is correct even
                // if the restore guard decides to bail out.
                if PrimaryPasteboard.write(s) {
                    logStore.add(trace.message("selection updated (\(s.count) chars): \(Self.previewForLog(s))"))
                } else {
                    logStore.add(trace.message("write to the \"\(PrimaryPasteboard.name.rawValue)\" pasteboard failed"))
                }
            } else {
                logStore.add(trace.message("clipboard changed but plain text is \(captured == nil ? "unavailable" : "empty"); selection kept"))
            }
            // If something else wrote to the pasteboard between us reading
            // and us restoring, don't clobber that newer content with our
            // pre-capture snapshot.
            if pb.changeCount == postCopyChangeCount {
                let restored = restorePasteboard(snapshot)
                logStore.add(trace.message("clipboard restore \(restored ? "succeeded" : "failed"): \(CaptureDiagnostics.clipboard(pb))"))
            } else {
                logStore.add(trace.message("clipboard changed again during capture: expected=\(postCopyChangeCount), actual=\(pb.changeCount); restore skipped"))
            }
            return
        }

        if elapsedMs >= timeoutMs {
            logStore.add(trace.message("capture timed out after \(elapsedMs)ms polling; \(CaptureDiagnostics.clipboard(pb)); frontmost=\(CaptureDiagnostics.application(NSWorkspace.shared.frontmostApplication)); restoring clipboard"))
            let restored = restorePasteboard(snapshot)
            logStore.add(trace.message("clipboard restore \(restored ? "succeeded" : "failed"): \(CaptureDiagnostics.clipboard(pb))"))
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(stepMs)) { [weak self] in
            self?.pollClipboardForCapture(
                trace: trace,
                sourcePID: sourcePID,
                generation: generation,
                initialChangeCount: initialChangeCount,
                snapshot: snapshot,
                elapsedMs: elapsedMs + stepMs
            )
        }
    }

    /// Pastes the PRIMARY selection. `clickLocation` is the middle-click point
    /// in global display coordinates; pass nil to paste into whatever already
    /// has keyboard focus.
    func pasteFromPrimary(at clickLocation: CGPoint? = nil) {
        // Read live rather than from a cache: another app (e.g. Emacs) may own
        // the selection. nil means nothing has claimed the pasteboard this
        // login session, its owner disowned it, or it holds no text payload.
        guard let text = PrimaryPasteboard.read() else {
            logStore.add("PRIMARY paste skipped: no selection available")
            return
        }
        // Distinct from nil: any app can publish an empty string.
        guard !text.isEmpty else {
            logStore.add("PRIMARY paste skipped: selection empty")
            return
        }

        // Our Cmd+V lands wherever keyboard focus already is, but we swallowed
        // the middle-click, so an unfocused target never got the click that
        // would have focused it - the paste went to the previously focused app
        // instead, or nowhere visible. Linux focuses the window under the
        // pointer and pastes there, so do the focusing ourselves.
        let activationDelayMs = clickLocation.map { focusTarget(at: $0) } ?? 0

        // Linux also drops the caret where you clicked, so do that too - but
        // only over an editable text field. A left-click is not inert: a few
        // pixels off and it presses a button, follows a link or hits Send.
        var caretPoint: CGPoint?
        if settings.pasteAtPointer, let point = clickLocation {
            let target = caretTarget(at: point)
            switch target.decision {
            case .textCaret:
                caretPoint = point
            case .container:
                // The app stopped exposing its tree here, so we cannot confirm
                // a text field - but without the click there may be no focused
                // field for Cmd+V to reach at all, which is the worse outcome.
                caretPoint = point
                logStore.add("PRIMARY: \(target.description) exposes no caret; clicking the container to focus it")
            case .refused:
                logStore.add("PRIMARY: \(target.description) under the pointer is not clickable, pasting at the existing caret")
            }
        }

        let pb = NSPasteboard.general
        let snapshot = snapshotPasteboard()

        pb.clearContents()
        pb.setString(text, forType: .string)
        // Snapshot the change count AFTER we wrote the PRIMARY text. If
        // anyone (user via Cmd+C, another app) writes to the pasteboard
        // between now and the restore below, we must not overwrite their
        // newer content with our pre-paste snapshot.
        let postSetChangeCount = pb.changeCount

        if let caretPoint = caretPoint {
            // Deliberately after any app switch has settled, so the click is
            // not consumed as the window-activating first click. simulatePaste
            // adds pasteDelayMs on top, which is the gap the target gets to
            // process the click before Cmd+V arrives.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(activationDelayMs)) { [weak self] in
                guard let self = self else { return }
                self.clickToPlaceCaret(at: caretPoint)
                self.logStore.add("PRIMARY: caret placed at the pointer before pasting")
            }
        }

        simulatePaste(extraDelayMs: activationDelayMs)

        // simulatePaste posts Cmd+V after pasteDelayMs (plus any settle time we
        // asked for above). Give the receiving app a small extra window to
        // consume the paste before we restore.
        let restoreDelayMs = Int(settings.pasteDelayMs) + activationDelayMs + 250
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(restoreDelayMs)) { [weak self] in
            guard let self = self else { return }
            let currentChangeCount = NSPasteboard.general.changeCount
            if currentChangeCount == postSetChangeCount {
                self.restorePasteboard(snapshot)
                self.logStore.add("PRIMARY: clipboard restored after paste")
            } else {
                self.logStore.add("PRIMARY: clipboard changed externally during paste, restore skipped")
            }
        }
    }

    // MARK: - Log helpers

    /// Single-line preview of a captured string, suitable for the debug console.
    /// Truncates at 30 chars and replaces newlines / tabs with visible markers
    /// so multi-line selections don't blow up the log layout.
    private static func previewForLog(_ s: String) -> String {
        let cleaned = s
            .replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "→")
        let maxLen = 30
        if cleaned.count <= maxLen {
            return "\"\(cleaned)\""
        }
        let prefix = cleaned.prefix(maxLen)
        return "\"\(prefix)…\""
    }

    // MARK: - Microphone

    func toggleMicrophone() {
        let checkScript = "return (input volume of (get volume settings))"
        var error: NSDictionary?

        guard let checkAppleScript = NSAppleScript(source: checkScript) else { return }
        let currentVolResult = checkAppleScript.executeAndReturnError(&error)

        guard error == nil else {
            logStore.add("Error getting mic volume: \(String(describing: error))")
            return
        }

        let currentVol = Int(currentVolResult.int32Value)
        let targetVol: Int

        if currentVol == 0 {
            targetVol = (settings.lastMicVolume > 0) ? settings.lastMicVolume : 100
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.settings.lastMicVolume = currentVol
            }
            targetVol = 0
        }

        let setScript = "set volume input volume \(targetVol)"
        if let setAppleScript = NSAppleScript(source: setScript) {
            setAppleScript.executeAndReturnError(&error)
            if let err = error {
                logStore.add("Error setting mic volume: \(err)")
            } else {
                logStore.add("Mic toggled to: \(targetVol)% (saved previous: \(currentVol)%)")
            }
        }
    }

    // MARK: - Focusing the paste target

    // How long to let a newly activated app settle before we post Cmd+V.
    // Activation is asynchronous, and a paste that arrives first goes to the
    // outgoing app instead.
    private static let activationSettleMs = 150

    /// Brings the window under `point` to the front so our Cmd+V reaches it.
    /// Returns the extra delay (ms) the caller should add before pasting: 0
    /// when no activation was needed or possible.
    private func focusTarget(at point: CGPoint) -> Int {
        guard let target = windowOwner(under: point) else {
            logStore.add("PRIMARY: no window under the pointer, pasting into the focused app")
            return 0
        }
        let wasActive = NSRunningApplication(processIdentifier: target.pid)?.isActive == true

        // Fast path for the common case - clicking into the window you are
        // already typing in. Nothing to focus, and no AX round trips.
        if wasActive && target.isFrontWindowOfApp {
            return 0
        }

        guard focus(pid: target.pid, windowContaining: point) else {
            logStore.add("PRIMARY: could not focus \(target.name), pasting into the focused app")
            return 0
        }
        if wasActive {
            // Same app, different window: it only had to be raised, and no app
            // switch has to settle before we paste.
            logStore.add("PRIMARY: raised the \(target.name) window under the pointer")
            return 0
        }
        logStore.add("PRIMARY: focused \(target.name) under the pointer before pasting")
        return Self.activationSettleMs
    }

    // MARK: - Placing the caret at the pointer

    // Fallback for apps that report a text role but do not answer the
    // kAXSelectedTextRange query used as the primary test below.
    private static let caretClickRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole]

    // Content containers we will click into when the app exposes nothing finer
    // at the click point. Their children failing to appear is a
    // tree-completeness problem, not evidence that a control is there -
    // Electron and other web-view apps routinely stop at one of these, and
    // then a paste has no focused field to land in at all.
    //
    // AXWindow is deliberately NOT here. It is what an app reports when it
    // exposes no tree whatsoever (Firefox), and it covers the titlebar,
    // toolbar and tab strip as well as content, so clicking it blind would
    // press whatever happens to be under the pointer.
    private static let caretClickContainerRoles: Set<String> = [
        kAXScrollAreaRole,  // Electron apps, including the Claude desktop app
        kAXGroupRole,
        "AXWebArea",        // WebKit/Chromium content; no kAX constant exists
    ]

    /// What we decided about the element under the pointer.
    private enum CaretClickDecision {
        /// Exposes a text caret, so a click moves an insertion point.
        case textCaret
        /// A content container the app exposed nothing below. Clicking is a
        /// judgement call rather than a certainty.
        case container
        /// Nothing we are willing to click.
        case refused
    }

    // Tags the clicks we synthesize so our own tap can tell them from the
    // user's. A caret click cannot trigger a capture today (click state 1, no
    // drag), but if that condition ever loosened the click would fire Cmd+C
    // and feed itself, so the guard is worth having now.
    private static let syntheticClickUserData: Int64 = 0x4D50_4E58 // "MPNX"

    // Bounds on the manual hit test below. AX calls are synchronous, so the
    // walk has to be cheap enough to sit in front of a paste: at most this
    // many levels deep and this many element queries in total.
    private static let axMaxDescentDepth = 12
    private static let axHitTestBudget = 250

    /// Whether the element the user clicked is a text element we can safely
    /// click into, plus the trail of roles we walked - the caller logs that
    /// when we refuse, which is what makes an app's own limits diagnosable.
    ///
    /// The test is kAXSelectedTextRange rather than a role allowlist: anything
    /// exposing a caret and a selection range is a text element, and buttons,
    /// links, checkboxes and menu items are not. That generalises across apps
    /// far better than enumerating roles, which browsers in particular make a
    /// losing game.
    private func caretTarget(at point: CGPoint) -> (description: String, decision: CaretClickDecision) {
        let system = AXUIElementCreateSystemWide()
        // Set on the system-wide element, which applies to every AX message
        // this process sends, including the ones to elements found below.
        AXUIElementSetMessagingTimeout(system, Self.axTimeoutSeconds)

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit = hit
        else { return ("nothing", .refused) }

        // Firefox (and anything else that does not hit-test into its own
        // content) answers with the top-level AXWindow, so descend ourselves.
        var trail = [role(of: hit)]
        var element = hit
        var budget = Self.axHitTestBudget
        var depth = 0
        while depth < Self.axMaxDescentDepth, budget > 0, !hasTextCaret(element) {
            guard let child = frontmostChild(of: element, containing: point, budget: &budget) else { break }
            element = child
            trail.append(role(of: child))
            depth += 1
        }

        let description = trail.joined(separator: " > ")
        if hasTextCaret(element) { return (description, .textCaret) }
        if Self.caretClickContainerRoles.contains(role(of: element)) {
            return (description, .container)
        }
        return (description, .refused)
    }

    /// The first child of `element` whose frame contains `point`. Children
    /// that do not report a frame are skipped rather than descended into:
    /// guessing past them is what would let us click an unrelated control.
    private func frontmostChild(
        of element: AXUIElement,
        containing point: CGPoint,
        budget: inout Int
    ) -> AXUIElement? {
        var rawChildren: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &rawChildren) == .success,
              let children = rawChildren as? [AXUIElement]
        else { return nil }
        for child in children {
            if budget <= 0 { return nil }
            budget -= 1
            if axFrame(of: child)?.contains(point) == true { return child }
        }
        return nil
    }

    /// True when `element` exposes a text caret, so clicking it moves an
    /// insertion point rather than activating a control.
    private func hasTextCaret(_ element: AXUIElement) -> Bool {
        var rawRange: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rawRange
        ) == .success {
            return true
        }
        return Self.caretClickRoles.contains(role(of: element))
    }

    private func role(of element: AXUIElement) -> String {
        var rawRole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &rawRole) == .success,
              let role = rawRole as? String
        else { return "unreadable" }
        return role
    }

    /// Clicks at `point` to move the target's text cursor there before we
    /// paste. Only call this once the target window is already active: a click
    /// on an inactive window is usually consumed as the activating click
    /// (`acceptsFirstMouse` defaults to false), so the caret would not move.
    private func clickToPlaceCaret(at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for mouseType in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let click = CGEvent(
                mouseEventSource: source,
                mouseType: mouseType,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else { continue }
            click.setIntegerValueField(.mouseEventClickState, value: 1)
            click.setIntegerValueField(.eventSourceUserData, value: Self.syntheticClickUserData)
            click.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Keyboard simulation

    func simulateCopy(to pid: pid_t? = nil) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let copyKeyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // 'C'
        let copyKeyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)

        copyKeyDown?.flags = .maskCommand
        copyKeyUp?.flags = .maskCommand

        if let pid = pid {
            copyKeyDown?.postToPid(pid)
            copyKeyUp?.postToPid(pid)
        } else {
            copyKeyDown?.post(tap: .cgSessionEventTap)
            copyKeyUp?.post(tap: .cgSessionEventTap)
        }
        logStore.add("System: Sent Cmd+C")
    }

    func simulatePaste(extraDelayMs: Int = 0) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let delayMs = Int(settings.pasteDelayMs) + extraDelayMs

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) {
            let pasteKeyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // 'V'
            let pasteKeyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)

            pasteKeyDown?.flags = .maskCommand
            pasteKeyUp?.flags = .maskCommand

            pasteKeyDown?.post(tap: .cgSessionEventTap)
            pasteKeyUp?.post(tap: .cgSessionEventTap)
            self.logStore.add("System: Sent Cmd+V")
        }
    }
}
