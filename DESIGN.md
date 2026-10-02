---
version: alpha
name: ElegantClipbar
description: A native clipboard panel that follows ClashBar's compact menu-bar layout.
omitted:
  - section: colors
    reason: AppKit semantic colors follow the macOS appearance, accent color and accessibility settings.
typography:
  body:
    fontFamily: SF Mono, PingFang SC, monospace
    fontSize: 13px
  title:
    fontFamily: SF Mono, PingFang SC, monospace
    fontSize: 15px
  caption:
    fontFamily: SF Mono, PingFang SC, monospace
    fontSize: 11px
rounded:
  panel: 10px
  control: 6px
spacing:
  panel-width: 360px
  panel-inset: 8px
components:
  panel: {}
  history-row: {}
  icon-button: {}
---

# ElegantClipbar Design System

## Overview

This is a macOS utility for finding and reusing copied content. The user selected ClashBar as the direct reference for layout, size and interaction: a menu-bar anchored panel, fixed header and footer, compact middle scroller, system controls and no Dock window. The clipboard list remains the central surface; settings and preview use the same panel.

The interface follows the system language (Simplified Chinese or English fallback) and system light/dark appearance. It does not assume a geographic market. There are no web views, custom theme controls or decorative dashboard cards.

Runtime values are owned by `Sources/ElegantClipbar/DesignTokens.swift` (`PanelStyle`). This file mirrors those accepted values. SwiftUI views and the AppKit panel consume that one source.

## Colors

Use AppKit `windowBackgroundColor`, `controlBackgroundColor`, native label colors and the user's accent color. Selection uses accent at 12% opacity plus a visible leading indicator. Error messages include an icon and text. System colors provide light/dark and increased-contrast adaptation; no appearance override is applied in normal use.

## Typography

The body is the system monospaced font at 13 pt, captions at 11 pt, and the brand title at 15 pt semibold, matching ClashBar's density. Native fallback fonts render Chinese. Clipboard previews use the normal system body font for readability. RTF previews retain formatting; HTML previews show extracted text without loading external resources. Both formats retain their original data when pasted.

## Layout

Panel width is 360 pt, preferred height 560 pt, constrained to the available screen. The panel uses 8 pt list padding and 12 pt header/search insets; header and footer stay fixed while the active page owns one vertical scroller. The header follows ClashBar with a 40 pt original paper-sprite mascot, two-line title/status, and right-aligned pause, settings and power actions. Search is 34 pt high; a history heading separates search from rows. The 30 pt footer contains only shortcut hints. History rows reserve 60 pt for two lines of preview and source metadata. Search and status feedback reserve their own stable space. Native scroll indicators remain available.

## Elevation & Depth

Only the floating panel uses an AppKit shadow. Rows use tonal hover/selection feedback and no individual shadows. File dialogs use native sheets and suspend outside-click dismissal.

## Shapes

The panel radius is 10 pt and shared control radius 6 pt. Small icon buttons reserve 26 by 26 pt, with native keyboard focus and accessible names. Source labels and the history count use quiet tonal capsules, following ClashBar’s secondary metadata treatment. The outer panel uses a 0.65 pt separator-color border. The mascot has its own transparent silhouette without an extra tile or border.

## Components

`BrandIcon` loads the original paper-sprite mascot: two offset white note sheets, a blue curved clip, a folded corner and a small friendly face. Its white/blue shading echoes ClashBar while the paper silhouette identifies clipboard history. The source PNG is `Sources/ElegantClipbar/Resources/BrandIcon.png`; `Resources/AppIcon.icns` contains the macOS size variants. The panel uses the colored mascot in both appearances; the menu-bar item uses `Resources/StatusIconTemplate.png`, a simplified monochrome version of the same mascot with stacked pages, hooked clip, folded corner and smiling face. `BrandIcon.statusImage` sets its logical size to 18 pt and marks it as an AppKit template so macOS chooses black/white for the menu-bar appearance and selection state. The paper interiors remain transparent rather than becoming an opaque silhouette.

`PanelIconButton` owns icon-only actions, labels and tooltips. Native SwiftUI buttons, toggles and fields own standard interaction states. `PanelView` owns the header, page navigation, search clear action and persistent status feedback. `HistoryRow` exposes paste, preview and pin without relying on hover.

SF Symbols represent content type and actions. Type colors are owned by `ClipboardKind.tint`: blue text, indigo links, purple rich text, pink images, orange files. Icons retain distinct shapes so color is never the only signal. `PanelStyle` owns titleSize (15), logoSize (40), iconButtonSize (26), stroke (0.65), border and hover; header, search and history consume these shared values. Arrow keys move selection, Return pastes, Option+Return pastes plain text, and Escape hides the panel from history, preview or settings; the back button returns to history. During input-method composition or shortcut recording, Escape first cancels that operation. The power button and panel-scoped Command+Q share a native quit confirmation. Keyboard handling yields to input-method composition. Opening a preview never launches remote HTML resources; it uses native attributed text.

No decorative animation is required. Native controls follow system reduced-motion preferences. Product copy names the action and the result, and error text remains visible until dismissed or superseded.

## Do's and Don'ts

- Use the same native controls and labels across history, preview and settings.
- Keep large clipboard payloads out of list metadata and load them only when needed.
- Do not add separate floating toolbars, themes or duplicate navigation surfaces.
- Do not copy ClashBar's networking pages or helper-process architecture.
