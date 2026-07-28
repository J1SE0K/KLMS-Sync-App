# KLMS Sync Design System

This file codifies the visual system already implemented across the Mac, iPhone, iPad, and Windows apps. It does not introduce a redesign. The detailed product decisions remain in `docs/windows-ui-ux-design.md` and the approved responsive specifications under `docs/superpowers/specs/`.

## 1. Atmosphere & Identity

KLMS Sync is a quiet personal operations console. Its signature is Paper Graphite: warm paper surfaces, graphite actions, restrained borders, and dense information that stays calm at every window size. State and next action take priority over decoration.

## 2. Color

### Palette

| Role | Windows token | Light | Dark | Usage |
| --- | --- | --- | --- | --- |
| App surface | `--bg` | `#F7F7F4` | `#111310` | Window background |
| Panel | `--panel` | `#FFFFFF` | `#1A1D19` | Cards and panes |
| Soft panel | `--panel-soft` | `#F0F0EB` | `#222620` | Secondary controls and selection |
| Input | `--input-bg` | `#FFFFFF` | `#151815` | Fields and rows |
| Border | `--line` | `#D8D5CC` | `#444A40` | Structure and control boundaries |
| Primary text | `--text` | `#151515` | `#F1F3ED` | Headings and body |
| Secondary text | `--muted` | `#6B6760` | `#C1C6BA` | Hints and metadata |
| Primary action | `--neutral-button` | `#30343A` | `#E1E5DC` | Main actions |
| Focus | `--focus` | `#075FC8` | `#8EC5FF` | Keyboard focus |
| Success | `--green`, `--status-ok-*` | semantic green | semantic green | Completed and healthy |
| Warning | `--orange`, `--status-warn-*` | semantic amber | semantic amber | Needs attention |
| Failure | `--red`, `--status-fail-*` | semantic red | semantic red | Failed or destructive |

Rules:

- Platform-native Apple colors follow the same semantic roles and Paper Graphite contrast hierarchy.
- Accent colors communicate state or action only; they are never decorative.
- Forced-colors mode yields to system colors such as `Canvas`, `CanvasText`, `ButtonText`, `Highlight`, and `HighlightText`.

## 3. Typography

- Apple platforms use the system type family and Dynamic Type.
- Windows uses `Segoe UI`, `Apple SD Gothic Neo`, `Malgun Gothic`, then the system sans-serif.
- Body text is never smaller than 12px for secondary metadata and 14px for primary prose.
- Apple views use semantic system text styles for prose. Fixed display glyphs, badges, and
  counters use named values from `KLMSTypeSize`; view files do not introduce raw point sizes.
- Data counters use tabular figures where alignment matters.
- Korean prose uses phrase-aware wrapping. Normal prose must not split syllables or particles merely to fill a line; unbroken paths, URLs, tokens, and identifiers may use emergency wrapping in dedicated value containers.

## 4. Spacing & Layout

- The core spacing rhythm is 4px/pt. Every Apple spacing value comes from `KLMSSpacing`;
  named 1–3pt optical offsets and 5–15pt control insets preserve existing pixel geometry
  without allowing per-view literals.
- Every Apple corner radius comes from `KLMSRadius`. The 8pt small-surface radius is the
  baseline; named compact, control, card, panel, and feature-surface variants are the only
  approved exceptions.
- Mac navigation has three stable presentations: full sidebar, icon rail, hidden.
- Windows navigation has three stable presentations: full sidebar, icon rail, command drawer/hidden entry.
- iPhone and iPad content scrolls vertically beneath a safe-area-aware tab surface; Windows main content is the primary scroll owner and drawer content owns its own bounded scroll.
- Workspace layouts respond to actual content width. Fixed navigation widths are subtracted before choosing columns.
- All primary content remains horizontally contained at narrow width, 200% zoom, and 400% zoom.

## 5. Components

### Application shell

- **Structure:** stable navigation region plus a fluid, scrollable workspace.
- **States:** full, rail, hidden/drawer; light, dark, forced colors.
- **Accessibility:** navigation order is stable; icon-only controls retain labels and 44px/pt targets.

### Primary sync section

- **Structure:** section heading, optional notice-note setting, one prominent full-sync action, then narrower task actions.
- **Responsive rule:** when the workspace becomes one column, the entire sync section moves first; the button is not detached from its section.
- **States:** idle, queued, running, cancelling, completed, failed, blocked.

### Status summary

- **Structure:** phase eyebrow, title, message, actions.
- **States:** disconnected, ready, stale, running, success, warning, failure.
- **Accessibility:** the complete status message is keyboard- and touch-disclosable when the compact preview is clamped; copying status includes the complete message.
- **Layout:** status text has a bounded inline size and cannot paint into an adjacent gutter.

### List and detail

- **Structure:** searchable/sortable list, selected detail, progressive long-content disclosure.
- **States:** empty, loading, selected, stale, error, pathological long data.
- **Layout:** ordinary Korean copy keeps words together; dedicated raw-value containers use emergency wrapping and bounded scrolling.

### Buttons and icon actions

- **States:** default, hover, pressed, focus-visible, disabled, running, forced colors.
- **Accessibility:** minimum 44px/pt target; icon-only buttons have an accessible name and tooltip/title where supported; forced-colors mode preserves a visible button boundary and icon.

### Cards, pills, and rows

- **States:** default, hover, selected, success, warning, failure, hidden/read.
- **Depth:** tonal shift and one-pixel structural borders; shadows are reserved for true overlays such as drawers and toast surfaces.

## 6. Motion & Interaction

- Immediate feedback follows every action; remote completion arrives through WebSocket state changes.
- Motion communicates state only. Use opacity and transform for drawers/overlays and avoid decorative scaling on dense rows.
- Respect reduced motion. No polling animation or timer-based refresh substitutes for realtime transport.

## 7. Depth & Surface

The system uses a mixed tonal-shift and structural-border strategy. Panels are separated primarily by warm neutral surfaces and one-pixel borders. Shadows appear only on elevated overlays, never on every data row.

## 8. Accessibility Constraints & Accepted Debt

### Constraints

- Target WCAG 2.2 AA and platform accessibility conventions.
- Every action is keyboard reachable and has visible focus.
- Required controls retain visible geometry in forced-colors mode.
- Dynamic Type, 200% zoom, and 400% zoom preserve access to all functions without horizontal overflow of primary content.
- No required information is available only through hover, a native `title`, truncation, or color.
- iPhone and iPad screens respect safe areas and keep all seven sections reachable.

### Accepted debt

No visual or accessibility debt is accepted for the release candidate. Physical-device VoiceOver/Switch Control evidence and long-duration profiling are certification evidence still to be collected; they are not permission to weaken the implemented constraints.
