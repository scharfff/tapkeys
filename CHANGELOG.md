# Changelog

## [0.2.0] - 2026-10-31

### Added
- Settings window (menu bar → Settings…, or ⌘,) with Gestures, General and About tabs. The About tab is laid out in the style of Ice: a large icon, version, copyright and buttons to quit, see acknowledgements, contribute or report a bug.
- Configurable gestures: double tap with one finger, tap or click with three fingers, tap or click with four fingers.
- Actions: copy, paste, cut, undo, redo, select all, middle click, or any recorded keyboard shortcut.
- Timing sliders for tap length, double tap gap and allowed movement, and a Reset to Defaults button.
- Launch at login moved from the menu to Settings → General, next to an Accessibility status line.
- App icon: our own drawing of a tap point with rings on a black glossy tile. It is rendered from Resources/AppIcon.svg by scripts/make_icon.swift. Also a universal build for Apple Silicon and Intel.
- The first launch opens the settings window, so the app is visible even when a menu bar manager hides its icon.
- Opening TapKeys again from Finder, Spotlight or Launchpad brings up the settings window.
- A hint in General for a missing menu bar icon (Ice, Bartender, the notch).
- CI on every push and pull request: build on macOS 15 (Intel), self-test, DMG and zip checks; a separate informational workflow builds and tests on macOS 26 (Apple Silicon) when a hosted runner is available. Releases are published as a draft, checked, and only then made public, with a SHA256SUMS file.
- Homebrew: `brew install --cask scharfff/tap/tapkeys`.
- A DMG installer with a drag to Applications window, built by scripts/make_dmg.sh and attached to every release.

### Fixed
- Launch at login no longer switches itself off silently when TapKeys is turned off in Login Items: the toggle stays on and offers a button to open Login Items.
- Preset shortcuts follow the current keyboard layout, so Undo or Select all no longer turn into ⌘W or ⌘Q on AZERTY or Dvorak.
- A lost mouse up after a swallowed click no longer blocks the next normal click.
- Turning off or removing TapKeys in Accessibility while it runs no longer freezes clicks in every app: the click tap is removed within a second, and a multi-finger click runs its action only after the tap has returned.
- Gestures no longer stop after sleep: the system re-creates the trackpad on wake, so TapKeys lists the trackpads again after wake and whenever one is connected or disconnected.

## [0.1.0] - 2026-10-30

### Added
- Double tap with one finger copies, click with three fingers pastes.
- Menu bar item with pause, launch at login and quit.
