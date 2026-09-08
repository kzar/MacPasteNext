# Privacy Policy

## Summary

MacPasteNext is designed as a local desktop utility.

- No analytics
- No telemetry
- No external tracking service
- No cloud backend

## Data Handling

The app processes input events and clipboard interactions locally on your Mac to provide middle-click paste behavior and microphone toggle features.

It does not intentionally transmit personal data to external servers.

The PRIMARY selection is stored in a system-wide named pasteboard called `Selection` (the name GNU Emacs's Cocoa port uses), not inside the app. Like the regular clipboard, its contents can be read and overwritten by any process in your login session, and it persists until something replaces it - including after MacPasteNext quits.

The in-app debug console logs a truncated 30-character preview of each captured selection, and *Help -> Export Debug Logs* writes those previews to a file you choose. Since PRIMARY is shared, a preview may show text that was selected in another application. Nothing is written anywhere else, and the console is cleared when the app quits.

## Permissions

macOS permissions are required for core behavior:

- Accessibility permission for global input handling and key simulation

Permission state is managed by macOS and can be reset by the user.

## Release and Distribution

Project releases are built using GitHub Actions and published to GitHub Releases.

## Third-Party Services

The project repository and release pipeline are hosted on GitHub:

- Repository: `git@github.com:d0dg3r/MacPasteNext.git`

## Contact

For privacy questions, open a GitHub issue in this repository.
