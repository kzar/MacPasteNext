import AppKit

/// Linux-style PRIMARY selection, stored in a system-wide *named* pasteboard
/// rather than in a process-local variable.
///
/// "Selection" is the name GNU Emacs's Cocoa port uses for its PRIMARY
/// emulation (`NXPrimaryPboard`, assigned in emacs/src/nsselect.m), and named
/// pasteboards are shared by every process in the login session. Using the
/// same name buys bidirectional interop: Emacs's `select-enable-primary` yanks
/// what we capture, and an Emacs region is what middle-click pastes. It also
/// means PRIMARY now outlives MacPasteNext — the pasteboard server owns the
/// storage.
enum PrimaryPasteboard {
    static let name = NSPasteboard.Name("Selection")

    private static var pasteboard: NSPasteboard { NSPasteboard(name: name) }

    /// Publishes `text` as the current PRIMARY selection. Returns false if the
    /// write was rejected.
    ///
    /// Unconditional on purpose, even when `text` already equals the current
    /// contents: `clearContents()` bumps the change count, and the change count
    /// is how other owners learn they lost the selection. Emacs's
    /// `deactivate-mark` deliberately does NOT re-publish its region once
    /// another program owns PRIMARY (Bug#11772) — bumping is what makes that
    /// guard protect our selection.
    @discardableResult
    static func write(_ text: String) -> Bool {
        let pb = pasteboard
        pb.clearContents()
        return pb.setString(text, forType: .string)
    }

    /// The current PRIMARY selection, whoever wrote it last. nil when nothing
    /// has claimed the pasteboard this login session, when its owner disowned
    /// it (Emacs's `ns-disown-selection-internal` leaves it with no declared
    /// types), or when it holds no plain-text payload.
    ///
    /// Deliberately a single `string(forType:)` call — it returns an immutable
    /// copy, so no other process can invalidate a half-read value. Do not
    /// rewrite this to walk `pasteboardItems`: those go stale as soon as the
    /// change count moves and silently start returning nil.
    static func read() -> String? {
        pasteboard.string(forType: .string)
    }
}
