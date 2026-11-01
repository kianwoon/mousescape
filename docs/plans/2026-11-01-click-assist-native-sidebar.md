# Native sidebar click correction

**Goal:** Restore reliable MyHome room/category clicks while preserving the existing browser/tab/slider paths and the single-owner gesture guarantee.

## Evidence

- Foreground physical MyHome clicks were passing through or using relocated mouse events without changing the view. Native UI actions did change Study room and Curtains. MyHome's room labels are real AXButtons under native selectable rows; categories use outline selection.
- MyHome returns AXRaise error -25205 even when its window is already usable. An attempted raise now falls through to the existing mandatory live AXFrontmost, AXFocusedWindow and system hit-window identity checks. An error alone never authorizes delivery.
- Writing a row's AXSelected failed. The owning outline advertises writable AXSelectedRows; selecting the exact member row through that container works. Row writes remain the alternative only when no supported owning selectedRows API exists. Failed/uncertain writes are never retried via a second click.
- Native room button delivery remains one AXPress on the verified element. No device control was changed during diagnostics; MyHome source was inspected read-only to confirm its category binding and room-button behavior.

## Implementation

- Native AXButtons are tagged AXNativeRowButton only inside already-admitted native selectable rows and after verifying AXPress plus live native list ancestry, with no AXWebArea. A same-element identity-bound delivery hint can survive transient AX queries; it carries no renewed evidence or authorization. The worker rechecks capability and live hit before acting.
- Verified native row actions share completed-click ownership in foreground/background and throughout the existing indicated tolerance. Their native API performs the action; browser AXButton/AXLink/AXSlider paths retain their prior behavior. Selection/ring scoring is unchanged.
- Native sidebar clicks ignore only the same <=2pt pointer noise already used by resolver pointer generations. Real drags still release the captured native down. Slider drag handling is unchanged.
- Foreground modifier/multi-click and secure-input gates, freshness, nearest selection, window/element/geometry validation and deduplication remain in place. No new candidate admission, preferences, permissions or browser extension.

## Verification

- 92 tests passed. Helper Debug, app Release clean and CLI Release builds passed. Stable signing retained, strict/deep verification passed and all installed GUI/CLI/helper/agent/resolver binary hashes matched the signed build. Processes restarted from /Applications.
- Actual category click at 20:42:43 Singapore: native-row-select-once code=0. Independently observed Curtains selected and the four curtain cards displayed.
- Actual room click at 20:42:58 Singapore: native-row-press-once code=0. Independently observed Study room devices including Main computer, Study Fan and Study light.
- User confirmed foreground/background and edge/boundary clicks work in MyHome; subsequently confirmed Brave tab bodies/close buttons, OpenCode tabs, YouTube seeking, background green-ring clicks and slider dragging still work. Those remaining per-app outcomes are user confirmations, not independent pixel/action-count measurements.
- Working tree remains uncommitted; prior checkpoint is 4ef1f85. No automatic commit.
