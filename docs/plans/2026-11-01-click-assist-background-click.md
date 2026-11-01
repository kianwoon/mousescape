# Background green-ring click Implementation Plan

**Goal:** A completed plain click on a freshly confirmed green-ring target in a background app activates the intended window and performs one action.

**Architecture:** The tap uses notification-fed foreground PID state (no AX or IPC in callback). It captures the background down; a drag releases the original down to native routing. On matching up, fresh same-target evidence produces one deduplicated service request. The service activates/raises the intended app/window, verifies live Accessibility focus (rather than cached AppKit focus), live geometry, window identity and hit legitimacy, then performs exactly one AXPress for existing chrome-eligible controls or posts one marked mouse pair through the normal HID input stream after verifying the target window is focused. No retry after delivery or uncertain outcome. Foreground behavior remains unchanged.

**Validation:** Unit tests for fresh/strong/direct-hit eligibility, changed target, malformed payloads and request deduplication. All three required builds, stable signing, install after killing old binaries, verify installed hashes. Live click counts on safe controls plus Brave/OpenCode tabs, YouTube seek and MyHome. Keep prior geometry optimization uncommitted and unchanged. No automatic commit.

## Verification results

- Final runtime uses live AXFrontmost and AXFocusedWindow plus a system-wide hit/window identity check. Cached NSWorkspace activation state is diagnostic only. AXMain/AXFocused are requested when settable, preserving unsupported apps' behavior.
- Direct-to-process posting failed the actual native counter test and was replaced before completion. Final delivery posts exactly one tagged down/up pair through the normal HID stream; the tap ignores that marker. The original down/up are consumed, with no fallback/retry after an uncertain delivery. Existing chrome-eligible controls perform one AXPress instead.
- Live native counter proof, Nov 1 Singapore time: physical background requests at 16:37:48 and 16:37:55/56 each reached the receiver with marker 1296253507, active=true, key=true, followed by exactly one ACTION. Count advanced 0 -> 1 -> 2. User confirmed this version worked. Receiver trace: /tmp/mousecape-background-click-audit.log.
- User subsequently confirmed Brave tab, OpenCode tab, YouTube seek, MyHome room-row, foreground-click and slider-drag checks worked. The automated regression capture additionally recorded successful marked background requests in Brave; it does not independently prove every named app's action. Do not claim more independent coverage than the actual counter trace and user confirmations.
- 88 tests passed. Helper Debug, app Release clean and CLI Release builds succeeded. Stable signing retained; strict/deep verification passed and all installed GUI, CLI, helper, agent and resolver binaries matched the signed build. Current helper/agent/resolver processes were restarted after installation.
- Resolver target admission, legitimacy checks and ring drawing remain byte-identical to committed baseline 1020775. Prior accepted live-geometry optimization remains unchanged and uncommitted. No preference changes or browser extension reinstallation.
- Temporary audit app stopped after verification. No commit created.
