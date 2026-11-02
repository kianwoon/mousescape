# Click Assist ring admission: clickable + visible, no fixed size caps

**Date:** 2026-11-02
**Status:** Approved design (approach A)

## Goal

A green ring marks what the user can click and can see. It does not depend on
how large the element is. Among clickable elements under the pointer, the
smallest one wins (existing behaviour). The only size-based exclusion is an
element that fills its own window, because that is the page or panel itself,
not a control.

## Current state

- `GeometryPolicy.classify` (`ClickAssistGeometry.swift:247-326`), called once
  from `collect()` (`ClickAssistResolver.swift:1509`), drops elements by fixed
  point sizes before any other check. Rejected elements are dropped, never
  demoted.
- Clickability is a role gate plus press-action check
  (`ClickAssistResolver.swift:1436-1493`). Unchanged by this design.
- Visibility is proven by the hit-test in `LegitimacyPolicy.validate`
  (`ClickAssistLegitimacy.swift`). Unchanged by this design.
- Winner selection already prefers the smallest first-class container
  (`ClickAssistDecisionCore.swift:170-215`). Unchanged by this design.

## Changes

### 1. Remove fixed size caps (`ClickAssistGeometry.swift`)

Delete and stop using:

| Constant | Value | Class |
|---|---|---|
| `maxControlArea` / `maxControlHeight` | 150,000 / 600 | direct, non-track slider |
| `pressMaxWidth` / `pressMaxHeight` | 420 / 220 | press-capable AXGroup |
| `rowMaxHeight` / `rowMaxArea` | 200 / 120,000 | AXCell / AXRow / AXListItem |
| `tileMaxArea` | 120,000 | AXImage / AXGroup tile |
| `trackMaxMinSide` | 200 | AXSlider |

Rejection reasons `.pressTooLarge`, `.rowTooLarge`, `.tileTooLarge` are
removed. `.oversized` now means "does not fit its display, or fills its
window" (see 2). New reason `.notTrackShaped` (see 3).

### 2. Add the window-fill rule

New constant `GeometryPolicy.windowFillLimit: CGFloat = 0.9`.

`classify` gains a parameter `windowBounds: [CGRect]`: the on-screen window
frames of the target app this cycle. For every class, after the display gate:

```
reference = smallest window containing the rect's centre
            ?? union of the displays the rect intersects
covered   = area(rect ∩ reference) / area(reference)
if covered >= windowFillLimit -> reject .oversized
```

When no window contains the element, its displays are the reference, so a
display-filling element is still rejected.

### 3. Keep (visibility and shape, not size)

- Finiteness and the 4 pt / 2 pt minimum-size floor (an element that small is
  not visibly clickable).
- Display gate: the element must land on and fit inside a real display.
- Wide-thin AXGroup band (`wideThinMinWidth` 300, height 2-6): this admits a
  zoomed seek bar that has no clickable role; it is an admission path, not a cap.
- `tileMinDimension` 30: a group thinner than this is a divider sliver.
- Slider shape rule: an AXSlider is admitted only when track-shaped, i.e.
  short side ≤ `trackShortMinSide` (60) OR aspect ≥ `trackMinAspect` (8). This
  replaces the 200 pt absolute bound and the "non-track slider falls back to
  the bulk bound" path. It keeps a video player mis-exposed as a 2289 × 963
  AXSlider from ringing the whole player.
  Rejection reason `.notTrackShaped`. Accepted trade-off: a chunky
  non-track slider (e.g. 400 × 150) no longer rings.
- Tile shape rule (user decision 2026-11-02): a tile (AXImage / AXGroup with no
  press action) must have aspect ≤ `tileMaxAspect` (3). Shape, not size: it
  keeps long no-press wrapper strips (1258 × 47, 1599 × 54) from ringing
  instead of the button inside them.

### 4. Window frame lookup (`ClickAssistResolver.swift`)

Once per resolver cycle, where `cycleDisplayBounds` is set (`:647`), read the
target app's on-screen window frames with one `CGWindowListCopyWindowInfo`
call (bounds need no Screen Recording permission; CG global coordinates match
AX). No per-element AX calls. Pass them to `classify`. Remove the
`rowTooLarge` / `tileTooLarge` diagnostic counters and their
`RESOLVER_PUBLISH` fields.

## Unchanged

Role gate, press-action detection, native-row handling, enabled check,
legitimacy hit-test, smallest-container winner, overlay drawing, background
click path.

## Testing

- Rewrite `ClickAssistCoreTests.swift:421-447`:
  - 2289 × 963 AXSlider → rejected (not track-shaped).
  - 1466 × 944 page container in a 1470 × 956 window → `.oversized`.
  - 1258 × 47 / 1599 × 54 wrappers → still `.tileTooWide`.
- New `classify` cases:
  - A 1200 × 800 AXButton inside a 1440 × 900 window → admitted (74%).
  - A 1400 × 880 AXGroup with press inside a 1440 × 900 window → `.oversized`.
  - Element ≥ 90% of its display with no containing window → `.oversized`.
  - A 600 × 300 AXRow and a 500 × 300 press AXGroup → admitted.
- Update other references to removed constants/reasons
  (`ClickAssistCoreTests.swift:21`, `ClickAssistAXGeometryTests.swift:46`,
  fixture replay suites) so the full suite passes.
- Build all three targets, install (copy first, then restart agent/resolver),
  confirm the running agent started after the copy.
- Live check by the user: large web cards/thumbnails ring; empty page area does
  not ring the whole page; YouTube player does not ring as a slider; seek bar
  still rings.
