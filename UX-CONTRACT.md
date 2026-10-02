# Native clipboard behavior

The agreed product scope is recorded in [the migration decision](docs/adr/0001-native-macos.md); visual values live in [DESIGN.md](DESIGN.md).

## Canonical UI Map

| Capability | Canonical owner | Source of truth | Allowed variants | Verification |
|---|---|---|---|---|
| List selection | PanelView + AppState | This contract | one selected history record | keyboard and filtered-list checks |
| Form | SettingsView + Preferences | This contract | native fields, switches and file panels | invalid retention values, cancel and save |
| Scrollbar | Native SwiftUI ScrollView | DESIGN.md | active page owns scrolling | history, preview and settings |
| Toast | PanelView status area | This contract | success, warning, error | permission failure and persistence error |
| Panel lifecycle | PanelController | This contract | history / settings / preview; native modal sheets | outside click, Esc, scoped Command+Q, cancel and reopen |
| CRUD | AppState + ClipboardStore | Migration decision | pin, delete one, import merge | store tests and native UI |

## History and search

History is loaded in pages of 100 metadata records, pinned first and then most recently copied. Search covers full text and file names, uses a clear button, ignores stale responses and resets paging. Search is transient and never put in URLs or logs. The selection stays on its record when possible and otherwise moves to the first result. Loading, empty, no-results, error and more-results states stay inside the list footprint.

Exact supported content and format determine deduplication; source and time do not. Re-copying an identical payload moves the existing entry to the newest position and preserves pinning. The default limit is 1,000 ordinary records and 30 days since last copy; pinned entries are exempt. Files are references only; a missing file produces an actionable error before changing the clipboard.

## Paste and permission

Click or Return selects a record for immediate paste into the app active before the panel opened. The service verifies the target and waits for modifier release. It never dispatches to another foreground app after the target changes. Without Accessibility permission, copying still works and the panel explains how to enable paste. Permission prompts occur only after a user action. Option+Return is the plain-text variant.

## Data changes and recovery

Pinning is reversible and requires no confirmation. Deleting a history record requires a named confirmation and affects only local history. Native backup export includes stored clipboard data; import validates the archive and merges transactionally, retaining current data if it fails. Old Windows backups are unsupported. Retention settings validate positive integers before committing or pruning. Errors stay visible with retry where useful; clipboard payloads never appear in diagnostic logs.

## Panel and system

The panel anchors under the menu-bar icon in the current Space, closes on outside click, and suspends that behavior for dialogs. Escape hides history, preview and settings directly; their back button returns to history. Input-method composition and shortcut recording consume Escape first to cancel the pending input. Settings stays in the top-right header beside the power button; there is no More menu or footer settings button. The power button and Command+Q open the same native quit confirmation, with Cancel as the default action. Command+Q is handled only for key events belonging to the visible panel. Mouse/key monitors are installed on show and removed on hide; outside left, right and middle clicks, loss of key focus, or app deactivation hide the panel. These rules also apply to demo mode. Confirmation and file dialogs suspend dismissal until they finish. The default hotkey is Option+Command+V; a shortcut conflict keeps the prior valid binding. Capture and paste sounds have separate switches, both initially off. Native launch-at-login follows the explicit toggle. Source exclusion uses selected application bundle identifiers.

## Verification limits

Unit tests use temporary stores and private pasteboards. A demo launch uses an isolated data directory and disables background capture, so visual inspection does not read existing clipboard history. A native build and test pass do not prove Accessibility permission or paste acceptance by every target application; report observed coverage.
