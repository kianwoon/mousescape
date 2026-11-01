# Faster live geometry reads Implementation Plan

**Goal:** Reduce ring discovery time without changing target admission, nearest-target selection, validation or expiry.

**Architecture:** Replace two accessibility position/size requests with one live multiple-attribute request. Decode with the existing finite geometry policy; retry the original separate reads if the batch is unsupported or incomplete. No values survive a read, and no cache is added.

**Tech Stack:** Swift, ApplicationServices, Xcode, SwiftPM.

1. Capture baseline CB_TRACE and visible overlay on the installed checkpoint 1020775. Benchmark separate and batch reads against the same live Brave/OpenCode nodes.
2. Modify only ClickAssistAXGeometry.swift. Add a closure-based reader seam and tests for batch success, unsupported/partial batch fallback, invalid types/nonfinite geometry, and negative/8K coordinates. Leave role, identity, hit-test, nearest and evidence policies unchanged.
3. Run SwiftPM regression tests and build helper Debug, app Release clean, CLI Release. Sign with the existing certificate, stop old processes, replace /Applications/Mousecape.app, verify signatures/binary equality and restart helper/agent.
4. Capture comparable live CB_TRACE and actual visible rings across Brave tabs, OpenCode tabs, YouTube seek slider and MyHome. Include blank/disabled/covered areas. Report measured scope and any missing visual checks accurately; no automatic commit.

## Results

- Paired live probe (alternating read order, same AX nodes): Brave 480 pairs, OpenCode 480 pairs, MyHome 412 pairs; zero geometry mismatches. Median separate/batch request time: Brave 0.065/0.043 ms, OpenCode 0.039/0.026 ms, MyHome 0.053/0.032 ms (about 33–40% lower median geometry-read time). MyHome mean had large outliers and did not improve; do not infer uniform latency improvement from the medians.
- A preceding probe also compared 960 Brave/OpenCode pairs with zero geometry mismatches.
- Existing CB_TRACE measures resolver-cycle start to accepted snapshot, not physical pointer arrival to displayed pixels. Baseline and post-install sweeps used different controls/window states; the resulting aggregate timings were mixed and are not a controlled end-to-end speedup measurement. Do not claim a percentage reduction in ring appearance time.
- Baseline trace capture: /tmp/mousecape-latency-baseline.log. Post-install captures: /tmp/mousecape-latency-after-live.log and /tmp/mousecape-latency-verification.log.
- Actual overlay screenshots inspected before/after installation. Post-install OpenCode tab ring visible; live overlay decisions included confirmed Brave tab and MyHome rows, and blank-area suppression. User subsequently confirmed rings still work on Brave tabs, OpenCode tabs, YouTube progress bar and MyHome. YouTube normal/full-screen were included in the requested check; their exact displayed pixels were not independently captured after installation.
- All 83 tests passed. Helper Debug, app Release clean, CLI Release builds succeeded. Stable signing identity retained; strict/deep signature verification passed. Installed GUI/CLI/agent/resolver binaries matched the signed build. Helper, agent and resolver restarted from /Applications.
- Runtime change is confined to ClickAssistAXGeometry.swift. No target role, nearest-selection, hit validation, tolerance, evidence age, cursor apply or preference changes. Browser bridge remains removed. No commit created.
