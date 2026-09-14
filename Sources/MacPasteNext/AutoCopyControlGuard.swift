import AppKit

/// Rejects positively identified menu/button gestures. Missing accessibility
/// information never counts as evidence that the app cannot select text.
enum AutoCopyControlGuard {
    enum Target: Equatable {
        case text
        case control(String)
        case unknown
    }

    struct Result {
        let target: Target
        let detail: String

        var blocksCopy: Bool {
            if case .control = target { return true }
            return false
        }
    }

    private static let controlRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole,
        kAXPopUpButtonRole, kAXMenuButtonRole,
        kAXMenuBarRole, kAXMenuBarItemRole, kAXMenuRole, kAXMenuItemRole,
    ]

    /// Nearest element first. Editable fields inside menus remain selectable;
    /// static labels inside buttons are still part of the button.
    static func classify(_ roles: [String]) -> Target {
        for role in roles {
            if role == kAXTextFieldRole || role == kAXTextAreaRole { return .text }
            if controlRoles.contains(role) { return .control(role) }
        }
        return roles.contains(kAXStaticTextRole) ? .text : .unknown
    }

    /// Runs only after the event-tap callback has returned. Reads roles and a
    /// short ancestry, with a total 100ms budget and at most 20ms per AX call.
    /// Unlike optional diagnostic snapshots, this check precedes Cmd+C.
    static func check(pid: pid_t, gesture: CaptureGesture?) -> Result {
        guard let gesture = gesture else {
            return Result(target: .unknown, detail: "no mouse coordinates; keeping copy fallback")
        }
        let probe = Probe(pid: pid)
        if let start = gesture.start {
            let result = probe.target(at: start, label: "start")
            // A drag beginning in identifiable text is still a selection if
            // the pointer ends outside that text (including over a control).
            if result.target != .unknown || start == gesture.end { return result }
            let end = probe.target(at: gesture.end, label: "end")
            return Result(target: end.target, detail: result.detail + "; " + end.detail)
        }
        return probe.target(at: gesture.end, label: "end")
    }

    private final class Probe {
        private let app: AXUIElement
        private let deadline = ProcessInfo.processInfo.systemUptime + 0.1

        init(pid: pid_t) { app = AXUIElementCreateApplication(pid) }

        private func prepare(_ element: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            // Never change the timeout globally: paste and diagnostics have
            // their own AX queries and may run concurrently.
            return AXUIElementSetMessagingTimeout(element, Float(min(0.02, remaining))) == .success
        }

        private func read(_ name: String, from element: AXUIElement) -> CFTypeRef? {
            guard prepare(element) else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }

        func target(at point: CGPoint, label: String) -> Result {
            guard prepare(app) else {
                return Result(target: .unknown, detail: "\(label): AX budget/timeout unavailable; keeping copy fallback")
            }
            var hit: AXUIElement?
            let error = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
            guard error == .success, let hit = hit else {
                return Result(target: .unknown, detail: "\(label): AX hit test unavailable (\(error.rawValue)); keeping copy fallback")
            }

            var current = hit
            var roles: [String] = []
            for depth in 0..<4 {
                guard let role = read(kAXRoleAttribute, from: current) as? String else { break }
                roles.append(role)
                // Do not mistake an empty AXSelectedTextRange for a text
                // element: menus can expose that attribute too.
                if controlRoles.contains(role) || role == kAXTextFieldRole || role == kAXTextAreaRole { break }
                guard depth < 3, let parent = read(kAXParentAttribute, from: current),
                      CFGetTypeID(parent) == AXUIElementGetTypeID()
                else { break }
                current = parent as! AXUIElement
            }
            let target = classify(roles)
            let detail = "\(label): [\(roles.joined(separator: " < "))]"
                + (target == .unknown ? "; unidentified content, keeping copy fallback" : "")
            return Result(target: target, detail: detail)
        }
    }
}
