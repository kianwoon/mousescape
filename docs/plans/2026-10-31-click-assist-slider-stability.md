# Click Assist intermittent-slider investigation

Rollback checkpoint: 4f56473. Follow-up work is isolated on codex/click-assist-slider-stability.

Captured rejection: AXSlider frame (3471,1822,2132,6), enabled and adjustable, with unchanged live geometry. Renderer hit was an inner AXGroup (3480,687,2115,1190), whereas the slider's outer player ancestors were (3461,687,2152,1190). Exact hit/ancestor frame equality rejected this normal inner-video / outer-controls relationship.

Correction: Compare both live ancestry chains below AXWebArea/AXWindow. Require a matching common local AXGroup frame whose width/height are at most 10% + 2 pt larger than the hit surface. Keep the existing real-slider role, enabled/hidden, adjustable, live-frame, and destination checks. Preserve existing direct-ancestor and full-screen validation paths. Generic groups are still not targets.

Second captured failure: resolver picked an overlapping same-browser window by frame containment; logs showed an unrelated AXWindow title, no slider candidates, and an idle pointer-window pass repeating with zero targets. Prefer the system-wide live hit element's AXWindow when owner PID and both hit/window frames coherently cover the pointer; retain existing CG/AX fallback when unavailable.

73 regression tests pass, including the captured inner/outer-player geometry, mismatched-container/page exclusions, hit-window ownership/coherence, tab-close, windowed/full-screen slider, stale geometry, and tolerance cases. Final runtime follow-up pending.
