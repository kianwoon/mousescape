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
| `tileMaxArea` / `tileMaxAspect` | 120,000 / 3 | AXImage / AXGroup tile |
| `trackMaxMinSide` | 200 | AXSlider |

Rejection reasons `.pressTooLarge`, `.rowTooLarge`, `.tileTooLarge`,
`.tileTooWide` are removed. `.oversized` is kept and re-meant as
"fills its window" (see 2).

### 2. Add the window-fill rule

New constant `GeometryPolicy.windowFillLimit: CGFloat = 0.9`.

`classify` gains a parameter `referenceFrame: CGRect?`: the frame of the
element's own AX window. For every class, after the display gate:

```
reference = referenceFrame ?? allowed            // allowed = display gate bounds
covered   = area(rect ∩ reference) / area(reference)
if covered >= windowFillLimit -> reject .oversized
```

When the window frame cannot be read, the element's display bounds are the
reference, so a display-filling element is still rejected.

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
  Accepted trade-off: a chunky non-track slider (e.g. 400 × 150) no longer
  rings.

### 4. Window frame lookup (`ClickAssistResolver.swift`)

In `collect()`, before `classify`, read the element's `kAXWindowAttribute` and
that window's frame. Cache per resolver cycle keyed by window element
(`CFEqual`), cleared where `cycleDisplayBounds` is set (`:647`), so cost is one
frame read per window per cycle. Lookup failure passes `nil` (rule 2 fallback).

## Unchanged

Role gate, press-action detection, native-row handling, enabled check,
legitimacy hit-test, smallest-container winner, overlay drawing, background
click path.

## Testing

- Rewrite `ClickAssistCoreTests.swift:421-447`:
  - 2289 × 963 AXSlider → rejected (not track-shaped).
  - Former `tileTooLarge` / `tileTooWide` cases → admitted when below the
    window-fill limit.
- New `classify` cases:
  - A 1200 × 800 AXButton inside a 1440 × 900 window → admitted (74%).
  - A 1400 × 880 AXGroup with press inside a 1440 × 900 window → `.oversized`.
  - Element 95% of its display with `referenceFrame == nil` → `.oversized`.
  - A 600 × 300 AXRow and a 500 × 300 press AXGroup → admitted.
- Update other references to removed constants/reasons
  (`ClickAssistCoreTests.swift:21`, `ClickAssistAXGeometryTests.swift:46`,
  fixture replay suites) so the full suite passes.
- Build all three targets, install (copy first, then restart agent/resolver),
  confirm the running agent started after the copy.
- Live check by the user: large web cards/thumbnails ring; empty page area does
  not ring the whole page; YouTube player does not ring as a slider; seek bar
  still rings.
