# Polish pass — Tier 1 (efficiency) + Tier 2 (refinement)

Done 2026-07-21. Verified: clean build (no warnings), self-test harnesses pass
(clipboard, close-confirm, text-commit), UI renders inspected, idle measured
(0% CPU · 12 MB · ~0–1 wakeups/2s · 0 power). The recording indicator was
attempted and **dropped** (stuck-stop bug); it lives in a git stash.

## Tier 1 — efficiency / battery / memory
- **Clipboard poll timer**: added `tolerance` (0.45s) and it now **pauses on screen
  sleep/lock** and resumes on wake — the app's main idle drain, and what let App Nap
  engage. Resume re-syncs the changeCount baseline (no missed/duplicated copies).
- **Clipboard memory**: image history now stores a **downsampled 192px thumbnail**
  (decoded once via ImageIO), not a full-res PNG re-decoded on every list render.
  History panel releases items on close; screenshot HUD releases its full-res bitmap
  on dismiss.
- **Timers**: retention purge 60s→300s (+tol); screenshot purge +tol and off the main
  thread at launch; trimmer readiness poll now **stops once ready** (+tol).
- **Display list**: cached, refreshed only on screen-parameter change — no more
  ScreenCaptureKit enumeration on every menu open.
- **Annotation undo** capped (`levelsOfUndo = 25`) so crop/rotate snapshots don't grow
  unbounded.

## Tier 2 — refinement / accessibility / native feel
- **⌘,** opens Settings (app menu + shown on the status item).
- **Notification permission** requested on first recording, not at launch.
- **Accessibility**: VoiceOver labels on icon-only buttons (HUD, history); Reduce Motion
  honored on the countdown, HUD fades, and the "Copied" toast.
- **Contrast**: selected rows (clipboard + window picker) switched from white-on-solid-
  accent (illegible on light accents) to a native soft accent tint with default text.
- **Annotation**: crop Cancel/Apply respond to Esc/Return regardless of focus; canvas
  shows crosshair/I-beam cursors per tool.
- **Copy**: consistent leading-checkmark "✓ Copied…"; "Colour" → "Color".
- Removed dead auto-dismiss code in the HUD (thumbnail is intentionally persistent).

## Tier 3 — PARKED (revisit when you want)
Recording-quality depth, inspired by BetterCapture. Not started:
- Apple's native content picker (`SCContentSharingPicker`) for window/display selection.
- Content exclusion (hide menu bar / dock / wallpaper from a recording).
- Codec + frame-rate options (H.264 for universal sharing; 30/60 fps).
- (Bigger) persist clipboard history to disk (SQLite, Maccy-style) — survives restarts,
  near-zero RAM; changes the privacy posture (history touches disk).
