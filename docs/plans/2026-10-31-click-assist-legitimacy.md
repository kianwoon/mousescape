# Click Assist legitimacy and latency implementation plan

Goal: Rings and assisted clicks require actionable, enabled targets and coherent live hit-test evidence.
Architecture: Keep one shared selection rule for the resolver, overlay and tap. Reject structural candidates before they enter the cache; require renderer confirmation and remove blocking retries. Keep cursor application code untouched.
Tech stack: Swift, Accessibility, SwiftPM, Xcode.

1. Add regression coverage for structural elements versus controls/press actions and shared evidence selection.
2. Add an actionability gate, use AXUIElementCopyActionNames, reject disabled candidates, and require coherent target hit-test evidence.
3. Select evidence with DecisionCore.resolve; reduce timer cadence to 50 ms and avoid querying distant targets.
4. Run the headless suite and all three required builds. Install the signed Release app after stopping the old processes; restart and verify runtime status.

Verification: 59 SwiftPM tests passed, replaying 413 recorded episodes. MousecapeHelper Debug, Mousecape Release clean build, and mousecloak Release all succeeded. Installed /Applications/Mousecape.app with the existing GlanceDev certificate, verified the complete signature, matched installed binaries against the build, and confirmed the restarted agent reports active with a live resolver. No website-specific visual reproduction was performed.

Follow-up regressions: Brave reports the tab close point as an AXGroup proxy with the live tab frame; accept only a live enabled press-capable chrome button linked to that exact tab ancestor. Video seek bars can similarly hit the player container; accept only an enabled, adjustable AXSlider with matching live geometry and an exact player ancestor below AXWebArea. Added negative coverage and tolerance boundary tests at 8/12/16 pt. 63 tests pass, all three required builds succeeded, and the signed update is installed and reports active. Tab-close restoration was verified in live logs and confirmed by the user. Slider restoration verified in live logs: matching live frame, adjustable=true, enabled=true, ancestor=true; overlay action=show with confirmed evidence while pointer is 4.5–5.6 pt outside the slider.
