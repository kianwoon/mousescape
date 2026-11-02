# Native menu-bar click delivery

Failure evidence: BetterDisplay PID 768's AXMenuBarItem at (6723,3,52,24) produced repeated BACKGROUND_CLICK_CAPTURED followed by delivered=0 reason=target-changed. The background action requires an AXWindow; menu-bar items were not covered by the previous AXMenuItem exemption.

Change: exclude AXMenuBarItem from background window activation, and preserve native inside-frame coordinates by adding it to position-sensitive roles. Nearby confirmed targets still use edge-clamped tolerance. Admission, legitimacy, expiry, nearest selection and other control roles remain unchanged.

Regression: exercise center and both edges with same/different/unknown foreground PID, verify no background ownership and native direct-hit routing, and verify nearby tolerance stays inside the target. Existing supported-family test now expects edge semantics for menu-bar items. 100 tests passed. All builds and actual user clicks must be verified before reporting completion. No automatic commit.

Verification completed: all three required builds succeeded; installed signature and all five executable hashes verified and processes restarted. Live BetterDisplay clicks at (6746.6,17.4) and (6748.1,7.5) logged confirmed direct-hit PASSTHROUGH with orig==delivered; other menu-bar icons also passed through, with zero background-delivery rejections in the inspected capture. User confirmed “All worked correctly” for BetterDisplay center/edge clicks and Brave, OpenCode, YouTube seek/drag, MyHome and desktop menu regression checks.
