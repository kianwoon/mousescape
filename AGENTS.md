# INCLUDE_GLOBAL_CONFIG

# AGENTS.md — Mousecape-swiftUI

Agent guide for working on Mousecape (macOS cursor manager, SwiftUI + ObjC, private CoreGraphics APIs).
Companion docs: `CLAUDE.md` (project conventions), `ARCHITECTURE.md` (detailed internals), `README.md`.

---

## 1. Build / Install / Verify (exact working sequence)

```bash
# Build all three targets (must all succeed)
xcodebuild -project Mousecape/Mousecape.xcodeproj -scheme MousecapeHelper -configuration Debug build
xcodebuild -project Mousecape/Mousecape.xcodeproj -scheme Mousecape       -configuration Release clean build
xcodebuild -project Mousecape/Mousecape.xcodeproj -scheme mousecloak     -configuration Release build

# Install to /Applications (replace, de-quarantine, verify signature)
SRC=~/Library/Developer/Xcode/DerivedData/Mousecape-*/Build/Products/Release/Mousecape.app
killall Mousecape 2>/dev/null; pkill -f MousecapeHelper 2>/dev/null; sleep 2
rm -rf /Applications/Mousecape.app && cp -R "$SRC" /Applications/Mousecape.app
xattr -dr com.apple.quarantine /Applications/Mousecape.app
codesign --verify --strict /Applications/Mousecape.app

# IMPORTANT: kill running processes BEFORE replacing, or the OLD binary keeps running.
# Helper process name is "com.sdmj76.MousecapeHelper" (pkill -f MousecapeHelper works).
```

### Binary verification traps (cost hours — memorize)

- `MMLog()`/`HLOG()` with **plain ASCII** → stored as **C strings** → check with `b'literal' in data`.
- `NSLog()`/Swift strings with **non-ASCII (em-dash etc.)** → stored as **UTF-16** → check with
  `'literal'.encode('utf-16-le') in data`. `strings` misses UTF-16 — "missing string" ≠ "stale build".
- "log show" output can be cached/stale — match **PID + lstart** when attributing log lines.

### Live cursor state inspection (compile once, reuse)

Small ObjC probe against `CGSCopyRegisteredCursorImages` + `CGSGetGlobalCursorDataSize`
(see `MEMORY/lessons/` or rebuild: include `mousecloak/CGSInternal/*.h`, link scale.m, MCPrefs.m,
MCLogger.m, MCDefs.m, apply/listen need CoreImage+Accelerate+SystemConfiguration).
Useful identifiers: `com.apple.coregraphics.Arrow`, `ArrowS`, `ArrowCtx` (pointer synonym — macOS
renders the pointer through it), `IBeam`, `com.apple.cursor.N`.

### WindowServer ground truth

```bash
/usr/bin/log show --last 5m --style compact \
  --predicate 'process == "WindowServer" AND eventMessage CONTAINS "Cursor disabled"'
```
`Cursor disabled: failed set_cursor_surface` = the compositor refused a cursor-surface upload.
NOTE: this query works from a terminal; background/launchd processes get `<private>` redaction —
never build a Helper feature that parses this log (a guardian did exactly this and was blind).

---

## 2. Architecture — the parts that matter for cursor bugs

Three targets: **Mousecape** (GUI), **MousecapeHelper** (menu-bar daemon, login item),
**mousecloak** (CLI). All apply paths converge on `applyCapeWithoutReset()` in `mousecloak/apply.m`:

```
GUI Apply (AppState.applyCape) ──┐
CLI apply / Helper wake+reconfig ─┼→ applyCapeAtPath() → applyCapeWithoutReset()
session-change callbacks         ─┘        (backup → CoreCursorUnregisterAll → extract
                                             at 8x → re-register cape cursors + system
                                             defaults → reengage compositor)
```

- **`reengageAccessibilityCursorCompositor()`** restarts `universalaccessd` after every successful
  apply. It fires when Accessibility pointer size ≠ 1.0 **OR** max per-cursor scale > 4.0
  (`kMCLargeScaleThreshold`). **This is the anti-blink mechanism for large cursors. It is REQUIRED.
  Never disable it** (disabling it was tried on 2026-08-24 and caused the blink regression).
- Wake triggers: TWO independent — `reconfigurationCallback` (per-display, 2-4 events) in
  `listen.m`, and `NSWorkspace.didWakeNotification` in `MousecapeHelperApp.swift` →
  `reapplyCapeForCurrentUser()`.
- Per-cursor scaling: custom mode registers each cursor at `nativeSize × MCPerCursorScales[idf]`;
  baseScale (CGSSetCursorScale) = 1.0 in custom mode.
- Arrow synonyms: registering `Arrow` also writes `ArrowCtx` etc. (`MCArrowSynonyms()`); the
  system-defaults re-registration loop must skip those synonyms or it stomps the custom arrow
  to an 8×8 system bitmap (fixed in all three apply loops — keep the `registeredKeys` synonym adds).

---

## 3. CFPreferences scope rules (the #1 config-corruption trap)

macOS keeps **two stores** per domain: anyHost and currentHost. Verified experimentally:

- **currentHost wins**: if a key exists in currentHost, `CFPreferencesCopyAppValue` returns it and
  the anyHost value is invisible ("user sets value, it reverts on next read").
- Mousecape's intended layout (original code):
  - `MCPerCursorScales`, `MCScaleMode` UI values, everything from Settings/AppState → **anyHost**
    (`CFPreferencesSetAppValue` / `CopyAppValue`).
  - `MCAppliedCursor` (and `MCSetDefaultFor(..., kCFPreferencesCurrentHost)` callers) → **currentHost**.
- **`defaults read` = anyHost; `defaults -currentHost read` = currentHost.** A "missing" key may
  simply live in the other scope. ALWAYS check both scopes before concluding a pref was lost.
- **Never write recovery/test values into currentHost "for safety"** — they become permanent
  shadows that silently override the UI (this broke per-cursor scales AND the Accessibility
  pointer size on 2026-08-24). If a debug script writes prefs, delete them afterwards and
  re-verify with `CFPreferencesCopyAppValue`.
- Accessibility pointer size lives in `com.apple.universalaccess`:
  `mouseDriverCursorSize` (float) is the effective value; `mouse_cursor_size` (int slider index,
  default 4 = 1.0x). System Settings writes anyHost. It multiplies ALL cursors system-wide —
  Mousecape cannot opt out, only compensate (55× × 1.37 ≈ 75×).

---

## 4. The wake bug — root cause and the shipped minimal fix (2026-08-24)

**Symptom**: after sleep/wake the Mousecape cursor disappears until manual Apply or logout.

**Root cause (log-proven)**: one wake fired TWO independent triggers that did not share state —
display reconfiguration callback (2-4 per-display events) + NSWorkspace wake handler. Each ran a
FULL `applyCapeWithoutReset()` (unregister-all 50+ cursors → re-register → kill universalaccessd).
Measured: **4 full applies + 4 uad restarts in 35 s**; the compositor never stabilized → cursor gone.
The original per-callback debounce (function-static, 3 s) only deduplicated reconfig events, not
the wake handler.

**Fix (only change vs git HEAD d4fb126, listen.m only)**: file-scope
`g_lastSuccessfulApplyTime` + `wakeApplyCooldownActive()` (15 s shared cooldown). All three apply
trigger points (reconfigurationCallback, reapplyCapeForCurrentUser, UserSpaceChanged) check the
same cooldown before applying and mark success after. One wake = exactly one apply.

If the wake bug ever reappears, FIRST capture: `log show --predicate 'process == "MousecapeHelper"'
--last 10m` and count applies per wake before touching code.

---

## 5. Hard rules — things that were tried and FAILED (do not re-try)

The 2026-08-24 session shipped and then **reverted** all of the following because each broke a
working baseline ("it was working before your changes" was the user's correct diagnosis):

1. **Surface Guardian** (background monitor that auto-downgraded full-size → capped): its probe
   (`log show` from the Helper) was blind due to redaction; it fought the user's manual Applies;
   its revert logic made the cursor invisible. REMOVED.
2. **Smart-apply / two-phase apply** (capped first, background upgrade): double applies, double
   uad restarts, blinking. REMOVED.
3. **Capped/wake-safe applies** (`MC_WAKE_SAFE_CAP` env, 2× caps): left the user stuck on a small
   cursor after wake/boot. REMOVED.
4. **Disabling the universalaccessd restart**: directly caused the move-cursor blink regression.
   RE-ENABLED — it is the original anti-blink stabilization.
5. **Compensating Accessibility 1.37× into per-cursor scale** (pointer size → 1.0, scale 55→75):
  tested while the build was broken; conclusions invalid. Baseline config is 55× + pointer 1.37×.

**Process rules that follow from this:**
- Restart/log the baseline FIRST; if the platform behavior differs between "after restart" and
  "after my change", the change is the suspect, not the platform.
- One minimal change at a time, rebuild + reinstall + verify before the next.
- Never add a second controller to a system that already has one (reengage is the controller).
- Do not leave test/recovery preference writes behind — clean up both scopes.

---

## 6. Known macOS 27-beta behaviors (context, not Mousecape bugs)

- WindowServer logs `Cursor disabled: failed set_cursor_surface` bursts during early boot (~first
  60-90 s) before any login item runs — expected churn; the original code's retry loop handles it.
- Very large cursor bitmaps (>= ~2000 pt registered) can hit persistent surface-upload failures in
  a **damaged** session; a fresh session (reboot/logout) renders the same size fine. A session gets
  "damaged" by apply storms — which is exactly what the shared debounce prevents.
- Blank-cursor state is diagnosable: `CGSGetGlobalCursorDataSize` returning **4 bytes** = 1×1
  transparent current-cursor slot (registered images still readable — registration ≠ rendering).
