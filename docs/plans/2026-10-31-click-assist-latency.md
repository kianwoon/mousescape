# Click Assist latency implementation plan

Goal: Reduce first-ring delay while retaining the confirmed tab-close and windowed/full-screen slider validation.

Change: When the fresh pointer-area walk already produces an unambiguous in-tolerance winner using DecisionCore.resolve, skip the rotating global walk and proceed to the existing merge/validation/publication path. Preserve the frontier so missing, distant and ambiguous targets continue normal discovery. Never use union-held candidates for this scheduling decision.

Checks: Add regressions for tab close, windowed/full-screen sliders, absent targets, out-of-tolerance targets and ambiguity. Run the complete SwiftPM suite and three required builds. Sign with the existing GlanceDev identity, install after stopping old processes, verify signature/runtime, and compare fresh live cycle timing. Do not modify legitimacy policy or ring/click geometry.

Discovery deferral is bounded to four consecutive local cycles, then the rotating frontier resumes even if a local winner exists. This prevents a partially discovered parent from suppressing discovery of its child controls. 69 tests pass, including that bounded-discovery regression.

Verification completed: all three required builds succeeded, followed by a final incremental Release build. Signed with the existing GlanceDev identity, installed after stopping old processes, verified the complete signature and matching installed hashes, and confirmed runtime Active at 16 pt. Live logs after restart show confirmed rings for Close, the windowed Seek slider, and the full-screen 7638 pt Seek slider. Initial measured local cycles: n=59, median 41.7 ms, p95 54.67 ms; wider scans still run periodically and can take about 250 ms. These are resolver cycle timings, not an end-to-end first-visible-ring benchmark. Baseline browser near-target cycles had median 108.23 ms (different interaction sample).
