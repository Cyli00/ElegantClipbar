# ElegantClipbar

English | [中文](README.md)

A macOS menu bar clipboard app. Its layout and window behavior follow ClashBar: a native panel, 360 pt wide, anchored below the menu bar icon, with the system light or dark appearance.

Built with Swift, SwiftUI, and a small amount of AppKit. Data stays on your Mac. Supports macOS 13 or later on Apple Silicon and Intel, with **0 remote Swift package dependencies**.

## Everyday use

- Press **⌥⌘V (Option + Command + V)** or click the menu bar icon to open clipboard history.
- Search, preview, and pin frequently used items. Supports text, links, HTML/RTF rich text, images, and files.
- Click an item or press Return to close the panel, return to the previous app, and paste. Automatic paste requires permission in **System Settings → Privacy & Security → Accessibility**. Without permission, the item is still copied to the system clipboard so you can press ⌘V yourself.
- File history stores paths only. If an original file is moved or deleted, the item is marked unavailable.
- Items with identical content and formats are deduplicated and moved to the top. Identical text with different formatting remains separate.

Ordinary history defaults to **1,000 items and 30 days**. An item is removed when either limit applies; both limits are configurable. Pinned items are exempt from automatic cleanup.

Settings include launch at login, source app information, app exclusions, local backup import/export, and separate sounds for recording and pasting. Both sounds are off by default and can be previewed.

The Swift version starts with empty history and supports backups in its new native format only. Translation, WebDAV sync, custom themes, groups, separate favorites, and toolbar customization are outside this native version's scope. The repository now contains the native project; the previous implementation remains available in Git history.

## Build and run

Requires macOS and an Xcode toolchain with Swift 6.0 or later. The resulting app runs on macOS 13 or later.

```sh
make check       # Compile the native app
make test        # Run Swift tests
make build       # Package a release app for this Mac
make universal   # Package Apple Silicon + Intel
make run         # Package and open a debug app
```

Tests use Swift Testing: `make test` runs `swift test --disable-xctest --enable-swift-testing`, which also works with Xcode Command Line Tools.

Build outputs:

| Command | Output |
| --- | --- |
| `make build` / `make run` | `build/ElegantClipbar.app` |
| `make universal` | `build/universal/ElegantClipbar.app` |

The packaging script applies an ad-hoc signature for local use. Distribution to other Macs still requires developer signing and notarization. On repeated builds, the previous `.app` is moved to a system temporary directory, and its recovery path is printed.

The default version is `0.1.0`; override it when packaging:

```sh
APP_VERSION=0.1.0 BUILD_NUMBER=1 ./scripts/package-app.sh --universal
```

GitHub Actions CI compiles, tests, and packages both architectures. Pushing a `v*` tag matching the version in `Resources/Info.plist` (for example, `v0.1.0`) triggers `Build macOS release`: tests, universal packaging, signature verification, and a GitHub Release with the app ZIP and SHA-256 checksum. The workflow can also be manually run against an existing version tag.

## Source layout

- `Sources/ElegantClipbar/`: Swift app, SwiftUI views, and system integration.
- `Sources/CSQLite/`: Module declaration for macOS system SQLite.
- `Tests/ElegantClipbarTests/`: Native data and behavior tests.
- `Resources/Info.plist`: App identity and minimum macOS version.
- `scripts/package-app.sh`: Compile, assemble, and sign the `.app`.

[MIT License](LICENSE)
