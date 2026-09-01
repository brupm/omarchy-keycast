# Changelog

## 1.0.0 — 2026-09-01

First public release.

- On-screen key-name overlay for the Omarchy (Quattro) shell, sourced from `keyd monitor`.
- Three modes — stream, chords, caption — cycled via the `keycast` IPC (`omarchy-shell -q keycast cycleMode`) and persisted to `~/.config/omarchy/keycast.json`.
- Theme-aware pills; colours follow `omarchy theme set`.
