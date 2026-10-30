# Click Assist control audit — 2026-10-31

Scope: test other control families without changing the installed working runtime.

## Live browser checks

A separate local fixture was used in Brave with Click Assist active at 16 pt. The user swept the pointer over the fixture while live OVERLAY_STATE records were inspected.

| Control | Observed result |
| --- | --- |
| Standard button | Confirmed ring |
| Link | Confirmed ring |
| Checkbox | Confirmed ring |
| Radio button | Confirmed ring |
| Dropdown | Confirmed ring |
| Text field | Confirmed ring |
| Slider | Confirmed ring, including near misses |
| Custom ARIA button | Confirmed ring |
| Disabled button | No ring observed during sweep |
| Named decorative group / image / empty area | No ring observed during sweep |
| Button behind a non-clickable cover | No ring observed; unknown evidence suppressed |

Some early samples after moving between controls were unconfirmed and suppressed until the resolver refreshed. This audit does not prove every website's Accessibility tree behaves correctly, or that brief transitions can never occur.

## Regression checks

66 SwiftPM tests passed, including 413 recorded episodes, supported-control admission/selection, matching ring/click targets, position-sensitive snapping, 8/12/16 pt tolerance boundaries, page-furniture exclusion, browser tab-close proxies, and windowed/full-screen video-slider checks.

No production source or installed binaries were changed for this audit. Added the repeatable local fixture and two regression tests. The previously installed tab-close and video fixes remain active; no preference values were written.
