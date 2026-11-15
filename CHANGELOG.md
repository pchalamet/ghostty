# Ttyrex changelog

Changes on Ttyrex’s `main` branch since it forked from Ghostty at `6d9577708`.

## Unreleased

### Terminal and scrollback

- Applications can move the cursor into retained primary-screen scrollback and
  edit earlier output. The viewport can scroll independently. Saved cursor
  positions are tracked through reflow and history eviction, and scrollback
  changes refresh search results. (`25a8d3375`)
- With full-screen scroll margins, primary-screen output is edited by logical
  line. Relative cursor moves and line erases account for soft wraps.
  Replacement text can add or remove continuation rows while preserving
  neighboring output. This fixes progress display redraws after a resize. (`7704e2977`)
- Shell prompts and input marked by shell integration use screen rows. Resizing
  clears stale wrapped prompt text so the shell can redraw cleanly. (`7704e2977`)
- Writable scrollback and logical-line editing are enabled by default.
  (`25a8d3375`, `7704e2977`)
- Fixed window resizing erasing the start of a Bash prompt while the shell
  was still drawing it or leaving fragments after a redraw at very narrow widths.

### macOS interface and defaults

- Added the `compact-tabs` title bar style, backed by native window tab
  groups. Tabs show a foreground command icon and name with the working
  directory. The title bar includes a divider, a Command Palette button, and a
  New Tab button. Tabs can be reordered, renamed, detached, or closed, with a
  close button appearing on hover. (`ea09c0cc6`)
- The selected tab’s highlight slides to the next selection, including when
  closing the selected tab. Inactive tabs highlight on hover. Unfocused windows
  dim the tabs and terminal content. Clicking the title bar restores focus to
  the selected tab’s terminal. (`ea09c0cc6`)
- The macOS defaults are the bundled Whitby Bay theme for both system
  appearances, Menlo at 13 pt, compact tabs, window state restoration set to
  `always`, and terminal padding of 10 pt horizontally and 8 pt vertically.
  (`ea09c0cc6`)
- Scrollbar drags and precise trackpad gestures move the viewport by pixels and
  can stop partway through a row. New output animates upward when following the
  bottom. Pointer hit testing follows the rendered text. (`c8a9af971`)
- Dragging the compact title bar where macOS shows a resize cursor resizes the
  window. The rest of the title bar remains draggable. (`892b03213`)

### Branding and configuration

- Shell integration no longer overrides the cursor style by default, so shell
  prompts preserve `cursor-style`, which defaults to `block`. Set
  `shell-integration-features = cursor` to opt in to a bar cursor at the prompt.
- Rebranded the app as Ttyrex with a dinosaur terminal icon and a `ttyrex`
  executable. The About dialog and README credit Ghostty. Launchers, shell
  completions, build artifacts, and package metadata use the Ttyrex name
  where applicable. (`808cc61b0`)
- Ttyrex reads Ghostty’s existing macOS configuration at
  `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`, with
  support for the legacy `config` file and the existing XDG configuration
  paths. (`808cc61b0`)
- The macOS updater uses a separately configured feed for Ttyrex releases.
  (`808cc61b0`)

### Removed

- Removed Quick Terminal from macOS and GTK, including its menu entry,
  configuration options, keybinding action, CLI command, and macOS Shortcuts
  action. (`ae2d85d23`)

### Build

- Added `make release` to build an optimized Apple Silicon app on an arm64
  macOS host. It uses ReleaseFast and a native XCFramework, and outputs
  `zig-out/Ttyrex.app`. (`10a173042`)
