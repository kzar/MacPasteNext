import AppKit

struct CaptureGesture {
    let start: CGPoint?
    let end: CGPoint
    let clickCount: Int64
    let dragged: Bool

    var description: String {
        "possible selection gesture: clicks=\(clickCount), drag=\(dragged), start=\(start.map(Self.point) ?? "unknown"), end=\(Self.point(end))"
    }

    private static func point(_ point: CGPoint) -> String {
        String(format: "(%.0f,%.0f)", point.x, point.y)
    }
}

struct CaptureTrace {
    let id: Int
    let startedAt = ProcessInfo.processInfo.systemUptime

    func message(_ message: String) -> String {
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        return "PRIMARY [capture #\(id) +\(elapsed)ms]: \(message)"
    }
}

/// Optional, read-only diagnostics. AX probes never decide whether to copy.
/// Run off the event tap/main queue, bound the work, and drop overlapping probes
/// rather than building a backlog that would describe stale UI state.
final class CaptureDiagnostics {
    private let queue = DispatchQueue(label: "MacPasteNext.capture-diagnostics", qos: .utility)
    private var collecting = false // Accessed only on the main queue.

    static func application(_ app: NSRunningApplication?) -> String {
        guard let app = app else { return "none" }
        return "\(app.localizedName ?? "unnamed") (bundle=\(app.bundleIdentifier ?? "unknown"), pid=\(app.processIdentifier))"
    }

    /// Reports declared types only; never requests clipboard payloads.
    static func clipboard(_ pb: NSPasteboard) -> String {
        let types = (pb.types ?? []).map(\.rawValue).sorted().joined(separator: ",")
        return "changeCount=\(pb.changeCount), types=[\(types)]"
    }

    func record(pid: pid_t, gesture: CaptureGesture?, emit: @escaping (String) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !collecting else {
            emit("AX snapshot skipped: previous diagnostic probe still running")
            return
        }
        collecting = true
        let requestedAt = ProcessInfo.processInfo.systemUptime
        queue.async {
            let observation = AXObservation()
            let queueDelay = Int((observation.startedAt - requestedAt) * 1_000)
            let lines = observation.describe(pid: pid, gesture: gesture)
            let duration = Int((ProcessInfo.processInfo.systemUptime - observation.startedAt) * 1_000)
            DispatchQueue.main.async {
                self.collecting = false
                emit("AX snapshot (asynchronous, queueDelay=\(queueDelay)ms, duration=\(duration)ms): " + lines.joined(separator: "; "))
            }
        }
    }
}

private final class AXObservation {
    let startedAt = ProcessInfo.processInfo.systemUptime
    private let budget: TimeInterval = 0.3

    private func prepare(_ element: AXUIElement) -> String? {
        let remaining = budget - (ProcessInfo.processInfo.systemUptime - startedAt)
        guard remaining > 0 else { return "budget-exhausted" }
        // Set the timeout on this object, never globally for the process.
        let result = AXUIElementSetMessagingTimeout(element, Float(min(0.04, remaining)))
        return result == .success ? nil : "timeout-setup=\(Self.status(result))"
    }

    private func attribute(_ name: String, of element: AXUIElement) -> (CFTypeRef?, String) {
        if let problem = prepare(element) { return (nil, problem) }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success else { return (nil, Self.status(error)) }
        return (value, value == nil ? "no-value" : "success")
    }

    private static func status(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .attributeUnsupported: return "unsupported"
        case .noValue: return "no-value"
        case .cannotComplete: return "cannot-complete (timeout or unresponsive app)"
        case .apiDisabled: return "accessibility-disabled"
        case .invalidUIElement: return "invalid-element"
        case .notImplemented: return "not-implemented"
        default: return "AXError(\(error.rawValue))"
        }
    }

    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    // Roles/subroles and localized role labels describe structure. Avoid
    // element titles, descriptions, values, URLs and selected-text contents.
    private func identity(_ element: AXUIElement) -> String {
        let (role, roleStatus) = attribute(kAXRoleAttribute, of: element)
        let (subrole, subroleStatus) = attribute(kAXSubroleAttribute, of: element)
        let (roleDescription, descriptionStatus) = attribute(kAXRoleDescriptionAttribute, of: element)
        return "role=\(role as? String ?? roleStatus), subrole=\(subrole as? String ?? subroleStatus), roleDescription=\(roleDescription as? String ?? descriptionStatus)"
    }

    private func selection(_ element: AXUIElement) -> String {
        let (text, textStatus) = attribute(kAXSelectedTextAttribute, of: element)
        let textDescription: String
        if let text = text as? String {
            textDescription = text.isEmpty ? "empty" : "present (\(text.utf16.count) UTF-16 units)"
        } else {
            textDescription = textStatus == "success" ? "unexpected-type" : textStatus
        }

        let (rawRange, rangeStatus) = attribute(kAXSelectedTextRangeAttribute, of: element)
        var range = CFRange()
        let rangeDescription: String
        if let rawRange = rawRange, CFGetTypeID(rawRange) == AXValueGetTypeID(),
           AXValueGetValue(rawRange as! AXValue, .cfRange, &range) {
            rangeDescription = "location=\(range.location), length=\(range.length)"
        } else {
            rangeDescription = rangeStatus == "success" ? "unexpected-type" : rangeStatus
        }
        return "selectedText=\(textDescription), selectedRange=\(rangeDescription)"
    }

    private func describe(_ target: AXUIElement) -> String {
        var parts = [identity(target), selection(target)]
        var current = target
        // Include a short parent chain: a text leaf may actually belong to a
        // button, link, slider or media container. Never walk the whole tree.
        for depth in 1...2 {
            let (rawParent, status) = attribute(kAXParentAttribute, of: current)
            guard let parent = element(rawParent) else {
                parts.append("parent\(depth)=\(status == "success" ? "unexpected-type" : status)")
                break
            }
            parts.append("parent\(depth)={\(identity(parent))}")
            current = parent
        }
        return parts.joined(separator: ", ")
    }

    func describe(pid: pid_t, gesture: CaptureGesture?) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        var lines: [String] = []
        if let gesture = gesture {
            var points = [("end", gesture.end)]
            if let start = gesture.start, start != gesture.end { points.append(("start", start)) }
            for (label, point) in points {
                if let problem = prepare(app) {
                    lines.append("\(label)=\(problem)")
                    continue
                }
                var hit: AXUIElement?
                let result = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
                if result == .success, let hit = hit {
                    lines.append("\(label)={\(describe(hit))}")
                } else {
                    lines.append("\(label)=\(result == .success ? "no-value" : Self.status(result))")
                }
            }
        }
        let (rawFocus, status) = attribute(kAXFocusedUIElementAttribute, of: app)
        if let focus = element(rawFocus) {
            lines.append("focused={\(describe(focus))}")
        } else {
            lines.append("focused=\(status == "success" ? "unexpected-type" : status)")
        }
        return lines
    }
}
