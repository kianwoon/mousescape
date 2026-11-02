# Click Assist Ring Visibility (no fixed size caps) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Click Assist ring marks any clickable, visible element regardless of its size; only elements that fill their own window are excluded.

**Architecture:** `GeometryPolicy.classify` (pure) stops applying fixed point-size caps and instead rejects an element covering ≥ 90 % of its reference frame (its smallest containing app window, else its displays). The resolver supplies the target app's window frames once per cycle via `CGWindowListCopyWindowInfo`. Shape rules for sliders (track-shaped) and no-press tiles (aspect ≤ 3) stay.

**Tech Stack:** Swift, ApplicationServices (AX), CoreGraphics, XCTest via SwiftPM package `Tools/ClickAssistTests` (its sources are symlinks to the app files).

**Spec:** `docs/superpowers/specs/2026-11-02-click-assist-ring-visibility-design.md`

## Global Constraints

- Window-fill limit: `GeometryPolicy.windowFillLimit = 0.9` (fraction of reference area).
- Keep unchanged: 4 pt / 2 pt degenerate floor, display gate (`displaySlackScale` 1.05, `displaySlackPoints` 2), `wideThinMinWidth` 300, `wideThinMinHeight` 2, `wideThinMaxHeight` 6, `tileMinDimension` 30, `trackShortMinSide` 60, `trackMinAspect` 8, `tileMaxAspect` 3.
- Delete: `maxControlArea`, `maxControlHeight`, `pressMaxWidth`, `pressMaxHeight`, `rowMaxHeight`, `rowMaxArea`, `tileMaxArea`, `trackMaxMinSide`; reasons `.pressTooLarge`, `.rowTooLarge`, `.tileTooLarge`.
- New reason: `.notTrackShaped`.
- Do not touch role gate, press-action detection, legitimacy hit-test, winner selection, overlay, background-click code.
- Single file ≤ 1500 LOC rule: `ClickAssistResolver.swift` is already large — add only the minimum lines.
- Build: the three `xcodebuild` commands in `AGENTS.md` §1 must all succeed.

---

### Task 1: Window-relative admission in `GeometryPolicy`

**Files:**
- Modify: `Mousecape/Mousecape/SwiftUI/ClickAssist/ClickAssistGeometry.swift` (lines 10-16 enum, 29-46 doc table, 182-213 constants, 222-232 `allowedBounds`, 245-326 `classify`)
- Test: `Tools/ClickAssistTests/Tests/ClickAssistTests/ClickAssistCoreTests.swift` (helper at 19-23, tests A3 at 421-427, A6 at 444-449, new tests appended in the same class)

**Interfaces:**
- Produces:
  - `GeometryPolicy.classify(role: String, hasPressAction: Bool, rect: CGRect, displayBounds: [CGRect], windowBounds: [CGRect] = []) -> GeometryVerdict`
  - `GeometryPolicy.referenceFrame(for rect: CGRect, windows: [CGRect]) -> CGRect?`
  - `GeometryPolicy.windowFillLimit: CGFloat` (0.9)
  - `RejectionReason.notTrackShaped`

- [ ] **Step 1: Update the test helper and failing tests**

In `ClickAssistCoreTests.swift` replace the helper (lines 19-23):

```swift
    private func classify(_ role: String, _ r: CGRect, press: Bool = false,
                          on displays: [CGRect]? = nil,
                          windows: [CGRect] = []) -> GeometryVerdict {
        GeometryPolicy.classify(role: role, hasPressAction: press, rect: r,
                                displayBounds: displays ?? self.displays,
                                windowBounds: windows)
    }
```

Replace test A3 (lines 421-427):

```swift
    /// Guarded failure: a mis-exposed 2289x963 player CONTAINER exposed as
    /// AXSlider hijacked clicks meant for the real control. A slider must be
    /// track-shaped (a shape rule, not a size cap).
    func testA3_playerContainerIsNotTrackShaped() {
        let v = classify("AXSlider", rect(100, 200, 2289, 963))
        XCTAssertNil(v.candidateClass)
        XCTAssertEqual(v.rejection, .notTrackShaped)
    }
```

Replace test A6 (lines 444-449):

```swift
    /// Guarded failure: a page container (1466x944) passed as a tile while a real
    /// 204x290 thumbnail was rejected — exactly inverted. The container fills
    /// its window, so it is the page, not a control.
    func testA6_pageContainerVsThumbnail() {
        let window = rect(0, 0, 1470, 956)
        XCTAssertEqual(classify("AXGroup", rect(0, 0, 1466, 944), windows: [window]).rejection, .oversized)
        XCTAssertEqual(classify("AXImage", rect(500, 500, 204, 290), windows: [window]).candidateClass, .tile)
    }
```

Append inside the same test class (before its closing brace):

```swift
    // MARK: - Window-fill rule (no fixed size caps)

    func testLargeClickableBelowWindowFillIsAdmitted() {
        let window = rect(0, 0, 1440, 900)
        // 74 % of the window: a big control, still a control.
        XCTAssertEqual(classify("AXButton", rect(100, 50, 1200, 800), windows: [window]).candidateClass, .direct)
        // Former fixed caps: 600x300 row (area cap 120k), 500x300 press group (420x220 cap),
        // 1000x700 image (area cap 120k).
        XCTAssertEqual(classify("AXRow", rect(0, 0, 600, 300), windows: [window]).candidateClass, .row)
        XCTAssertEqual(classify("AXGroup", rect(0, 0, 500, 300), press: true, windows: [window]).candidateClass, .pressGroup)
        XCTAssertEqual(classify("AXImage", rect(0, 0, 1000, 700), windows: [window]).candidateClass, .tile)
    }

    func testWindowFillingElementIsOversized() {
        let window = rect(0, 0, 1440, 900)
        let v = classify("AXGroup", rect(20, 10, 1400, 880), press: true, windows: [window])
        XCTAssertNil(v.candidateClass)
        XCTAssertEqual(v.rejection, .oversized)
    }

    func testNoContainingWindowFallsBackToDisplay() {
        // mainDisplay is 7680x2160; 7600x2100 covers 96 % of it.
        XCTAssertEqual(classify("AXButton", rect(40, 30, 7600, 2100)).rejection, .oversized)
        XCTAssertEqual(classify("AXButton", rect(40, 30, 3000, 1500)).candidateClass, .direct)
    }

    func testReferenceFrameIsSmallestWindowContainingCentre() {
        let big = rect(0, 0, 2000, 1200)
        let small = rect(100, 100, 400, 300)
        XCTAssertEqual(GeometryPolicy.referenceFrame(for: rect(150, 150, 50, 20), windows: [big, small]), small)
        XCTAssertEqual(GeometryPolicy.referenceFrame(for: rect(1500, 900, 50, 20), windows: [big, small]), big)
        XCTAssertNil(GeometryPolicy.referenceFrame(for: rect(5000, 900, 50, 20), windows: [big, small]))
    }

    func testShapeRulesSurvive() {
        // Chunky non-track slider: accepted trade-off of the shape rule.
        XCTAssertEqual(classify("AXSlider", rect(0, 0, 400, 150)).rejection, .notTrackShaped)
        // Long no-press wrapper strips still never ring (user decision 2026-11-02).
        XCTAssertEqual(classify("AXGroup", rect(0, 100, 1258, 47)).rejection, .tileTooWide)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Tools/ClickAssistTests && swift test 2>&1 | grep -E "error:|failed" | head`
Expected: compile errors — `extra argument 'windowBounds'`, `type 'RejectionReason' has no member 'notTrackShaped'`, `referenceFrame` not found.

- [ ] **Step 3: Implement in `ClickAssistGeometry.swift`**

Replace the `RejectionReason` enum (lines 10-16):

```swift
/// Why an inspected element was NOT admitted (one bucket per policy row).
enum RejectionReason: String {
    case role, secure, nonFinite, degenerate
    /// Does not fit inside its displays, or fills its own window (the page itself).
    case oversized
    /// An AXSlider that is not track-shaped (e.g. a player container).
    case notTrackShaped
    case thinGroupMismatch
    case tileTooSmall, tileTooWide
    /// Rect intersects no known display: nothing can be clicked there.
    case offscreen
}
```

Replace doc table lines 29-46 (from `/// Table (first matching row wins` through `/// 9. otherwise`) with:

```swift
/// Table (first matching row wins; row 9 is the fallthrough). There is no
/// fixed point-size cap: a ring marks what is clickable and visible. After a
/// class row matches, every class passes the same FIT GATE: the rect must lie
/// inside `allowed` (union of the displays it intersects, inflated 1.05× per
/// axis + 2 pt) and must cover < `windowFillLimit` of its reference frame
/// (smallest app window containing its centre, else its displays); otherwise
/// `.oversized`. A rect that intersects no display is `.offscreen`.
/// 1. any non-finite component                         -> .nonFinite
/// 2. width < 4, or height < (width >= 300 ? 2 : 4)    -> .degenerate
/// 3. direct roles                                     -> .direct
/// 4. AXSlider: minSide ≤ 60 OR aspect ≥ 8             -> .track / .notTrackShaped
/// 5. AXGroup + AXPress                                -> .pressGroup
/// 6. AXGroup, width ≥ 300, 2 ≤ height ≤ 6             -> .wideThin
///    (AXGroup thinner than a tile and not wide-thin)   -> .thinGroupMismatch
/// 7. row roles                                        -> .row
/// 8. tile roles: sides ≥ 30, aspect ≤ 3               -> .tile / .tileTooSmall
///                                                              / .tileTooWide
/// 9. otherwise                                        -> .role
```

Replace the constants block lines 189-213 (from `/// A track is thin in ABSOLUTE terms` through `static let maxControlHeight: CGFloat = 600`) with:

```swift
    /// A slider must be track-shaped: sliver-thin or ≥ 8:1 (page zoom scales
    /// the control, so a zoomed 3195 × 76 seek bar stays admitted). A
    /// 2289 × 963 "slider" is a player container, not a track.
    static let trackShortMinSide: CGFloat = 60
    static let trackMinAspect: CGFloat = 8
    // Row 6 — wide-thin group (zoomed web seek bar collapsed to 2 pt tall).
    static let wideThinMinWidth: CGFloat = 300
    static let wideThinMinHeight: CGFloat = 2
    static let wideThinMaxHeight: CGFloat = 6
    // Row 7 — row-like containers.
    static let rowRoles: Set<String> = ["AXCell", "AXRow", "AXListItem"]
    // Row 8 — tiles / thumbnails (no press action of their own). The aspect
    // bound is a SHAPE rule: long wrapper strips (1258 × 47) are furniture.
    static let tileRoles: Set<String> = ["AXImage", "AXGroup"]
    static let tileMinDimension: CGFloat = 30
    static let tileMaxAspect: CGFloat = 3
    // FIT GATE — an element covering this fraction of its reference frame is
    // the page/panel itself, not a control.
    static let windowFillLimit: CGFloat = 0.9
```

Replace `allowedBounds` (lines 222-232) with these three functions:

```swift
    /// Union of the displays `rect` intersects. nil when it intersects none.
    static func displayUnion(for rect: CGRect, displayBounds: [CGRect]) -> CGRect? {
        let hits = displayBounds.filter { $0.intersects(rect) }
        guard var union = hits.first else { return nil }
        for d in hits.dropFirst() { union = union.union(d) }
        return union
    }

    /// The display-derived admission envelope for `rect`: union of the displays
    /// it intersects, inflated. nil when it intersects no known display.
    static func allowedBounds(for rect: CGRect, displayBounds: [CGRect]) -> CGRect? {
        guard let allowed = displayUnion(for: rect, displayBounds: displayBounds) else { return nil }
        // Centred so a control touching a display edge (or a 1 pt rounding
        // overhang) is not rejected: 1.05× total per axis, 2 pt total slack.
        let dx = (allowed.width * (displaySlackScale - 1) + displaySlackPoints) / 2
        let dy = (allowed.height * (displaySlackScale - 1) + displaySlackPoints) / 2
        return allowed.insetBy(dx: -dx, dy: -dy)
    }

    /// The window an element lives in: the smallest window containing its centre.
    static func referenceFrame(for rect: CGRect, windows: [CGRect]) -> CGRect? {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        return windows
            .filter { isValidFrame($0) && $0.width > 0 && $0.height > 0 && $0.contains(centre) }
            .min { $0.width * $0.height < $1.width * $1.height }
    }
```

Replace the whole `classify` function (lines 245-326, from `/// Classify one element.` through the closing `}` after `return GeometryVerdict(candidateClass: nil, rejection: .role)`) with:

```swift
    /// Classify one element. Pure: no AX calls, no logging, no side effects.
    /// `displayBounds` is the per-cycle display list and `windowBounds` the
    /// target app's on-screen window frames, both in AX/CG points.
    static func classify(role: String, hasPressAction: Bool, rect: CGRect,
                         displayBounds: [CGRect], windowBounds: [CGRect] = []) -> GeometryVerdict {
        func reject(_ r: RejectionReason) -> GeometryVerdict {
            GeometryVerdict(candidateClass: nil, rejection: r)
        }
        // 1. Finiteness.
        guard isValidFrame(rect) else { return reject(.nonFinite) }
        // 2. Frame floor (wide elements still admit a 2 pt sliver — zoomed bars).
        guard rect.width >= 4, rect.height >= (rect.width >= 300 ? 2 : 4) else {
            return reject(.degenerate)
        }
        guard let allowed = allowedBounds(for: rect, displayBounds: displayBounds),
              let displays = displayUnion(for: rect, displayBounds: displayBounds) else {
            return reject(.offscreen)
        }
        let minSide = min(rect.width, rect.height)
        let aspect = max(rect.width, rect.height) / max(minSide, 1)

        // 3-9. What the element is (role + shape, never size).
        let cls: CandidateClass
        if directRoles.contains(role) {
            cls = .direct
        } else if admittedTrackRoles.contains(role) {
            guard minSide <= trackShortMinSide || aspect >= trackMinAspect else {
                return reject(.notTrackShaped)
            }
            cls = .track
        } else if role == "AXGroup", hasPressAction {
            cls = .pressGroup
        } else if role == "AXGroup", rect.width >= wideThinMinWidth,
                  rect.height >= wideThinMinHeight, rect.height <= wideThinMaxHeight {
            cls = .wideThin
        } else if role == "AXGroup", minSide < tileMinDimension {
            // A group too thin to be a tile and not wide-thin is a divider sliver.
            return reject(.thinGroupMismatch)
        } else if rowRoles.contains(role) {
            cls = .row
        } else if tileRoles.contains(role) {
            guard minSide >= tileMinDimension else { return reject(.tileTooSmall) }
            guard aspect <= tileMaxAspect else { return reject(.tileTooWide) }
            cls = .tile
        } else {
            // Everything else is page furniture.
            return reject(.role)
        }

        // FIT GATE: visible on a real display, and not the window itself.
        guard allowed.contains(rect) else { return reject(.oversized) }
        let reference = referenceFrame(for: rect, windows: windowBounds) ?? displays
        let covered = rect.intersection(reference)
        if !covered.isNull,
           covered.width * covered.height >= windowFillLimit * reference.width * reference.height {
            return reject(.oversized)
        }
        return GeometryVerdict(candidateClass: cls, rejection: nil)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Tools/ClickAssistTests && swift test 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests.*seconds$" | tail -5`
Expected: no `error:`/`failed`; final line `Executed N tests, with 0 failures` (N ≥ 107).

Note: `ClickAssistResolver.swift` is not part of the test package, so it still references the removed reasons — fixed in Task 2. Do not run xcodebuild until Task 2.

- [ ] **Step 5: Commit**

```bash
git add Mousecape/Mousecape/SwiftUI/ClickAssist/ClickAssistGeometry.swift Tools/ClickAssistTests/Tests/ClickAssistTests/ClickAssistCoreTests.swift
git commit -m "feat(click-assist): admit rings by window fill instead of fixed size caps"
```

---

### Task 2: Supply window frames from the resolver

**Files:**
- Modify: `Mousecape/Mousecape/SwiftUI/ClickAssist/ClickAssistResolver.swift` (counters 236-266, cycle setup 647-659, `RESOLVER_PUBLISH` 1006-1017, `classify` call 1509-1511, helpers near 1821)

**Interfaces:**
- Consumes: `GeometryPolicy.classify(..., windowBounds:)` and the reason set from Task 1.
- Produces: nothing new for other tasks.

- [ ] **Step 1: Remove the two deleted counters**

At lines 238-247 delete these declarations (keep `tileTooSmall`, `oversized`, `tileTooWide`):

```swift
    /// Diagnostics only: row-like elements (AXCell/AXRow/AXListItem) rejected by the
    /// row-size guard this cycle. Reset per refresh; published as `rowTooLarge=`.
    private var rowTooLarge = 0
```

and

```swift
    private var tileTooLarge = 0
```

Change the doc comment above `tileTooSmall` to:

```swift
    /// Diagnostics only: tile-like elements (AXImage/AXGroup) rejected as too
    /// small, and near-identical duplicates merged, per cycle. Reset per
    /// refresh; published as `tileTooSmall=`/`deduped=`.
```

In `record(_:)` delete the lines `case .rowTooLarge: rowTooLarge += 1` and `case .tileTooLarge: tileTooLarge += 1`.

In the per-cycle reset (lines ~656-658) delete `rowTooLarge = 0` and `tileTooLarge = 0`.

- [ ] **Step 2: Remove the fields from `RESOLVER_PUBLISH`**

In the format string at line ~1006 replace the substring `rowTooLarge=%d tileTooSmall=%d tileTooLarge=%d tileTooWide=%d` with `tileTooSmall=%d tileTooWide=%d`. In the argument list (lines ~1016-1017) replace

```swift
                   rotationSkipped ? 1 : 0, rowTooLarge,
                   tileTooSmall, tileTooLarge, tileTooWide, dedupedCount, partialNoRenew, rej as NSString,
```

with

```swift
                   rotationSkipped ? 1 : 0,
                   tileTooSmall, tileTooWide, dedupedCount, partialNoRenew, rej as NSString,
```

Verify the format still pairs: `grep -n "tileTooSmall=%d tileTooWide=%d" Mousecape/Mousecape/SwiftUI/ClickAssist/ClickAssistResolver.swift` returns one line.

- [ ] **Step 3: Read window frames once per cycle**

Below `private var cycleDisplayBounds: [CGRect] = []` (line ~237) add:

```swift
    /// On-screen window frames of the target app, read once per cycle. The
    /// window-fill rule uses the smallest one containing an element.
    private var cycleWindowBounds: [CGRect] = []
```

After `cycleDisplayBounds = Self.displayBoundsAX()` (line ~647) add:

```swift
        cycleWindowBounds = Self.windowBoundsCG(pid: pid)
```

After `displayBoundsAX()` (line ~1823) add:

```swift
    /// One WindowServer query per cycle (bounds need no Screen Recording
    /// permission). CG global coordinates are the same space as AX frames.
    private static func windowBoundsCG(pid: pid_t) -> [CGRect] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: bounds as CFDictionary)
        }
    }
```

At the `classify` call (line ~1509) pass the frames:

```swift
        let verdict = GeometryPolicy.classify(role: role, hasPressAction: hasPressAction,
                                              rect: rect,
                                              displayBounds: cycleDisplayBounds,
                                              windowBounds: cycleWindowBounds)
```

- [ ] **Step 4: Confirm no stale references and build**

Run: `grep -rn "rowTooLarge\|tileTooLarge\|pressTooLarge\|maxControlArea\|pressMaxWidth\|rowMaxArea\|tileMaxArea\|trackMaxMinSide" Mousecape Tools/ClickAssistTests/Tests --include='*.swift'`
Expected: no output.

Run:

```bash
P=Mousecape/Mousecape.xcodeproj; f(){ grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -3; }
xcodebuild -project $P -scheme MousecapeHelper -configuration Debug build 2>&1 | f
xcodebuild -project $P -scheme Mousecape -configuration Release clean build 2>&1 | f
xcodebuild -project $P -scheme mousecloak -configuration Release build 2>&1 | f
```

Expected: three `** BUILD SUCCEEDED **`.

Run: `cd Tools/ClickAssistTests && swift test 2>&1 | grep -E "failed|Executed [0-9]+ tests.*seconds$" | tail -2`
Expected: `0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Mousecape/Mousecape/SwiftUI/ClickAssist/ClickAssistResolver.swift
git commit -m "feat(click-assist): feed per-cycle app window frames to ring admission"
```

---

### Task 3: Install and live verification

**Files:** none modified.

- [ ] **Step 1: Install (copy first, then restart processes)**

```bash
D=$(xcodebuild -project Mousecape/Mousecape.xcodeproj -scheme Mousecape -configuration Release -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/Mousecape.app
killall Mousecape 2>/dev/null
rm -rf /Applications/Mousecape.app.new && cp -R "$D" /Applications/Mousecape.app.new && xattr -dr com.apple.quarantine /Applications/Mousecape.app.new
rm -rf /Applications/Mousecape.app && mv /Applications/Mousecape.app.new /Applications/Mousecape.app
codesign --verify --strict /Applications/Mousecape.app && echo SIGNED_OK
pkill -f MousecapeHelper; pkill -f ClickAssistAgent; pkill -f ClickAssistResolver; sleep 4
pgrep -f ClickAssistAgent >/dev/null || open /Applications/Mousecape.app/Contents/Library/LoginItems/ClickAssistAgent.app
pgrep -f MousecapeHelper >/dev/null || open /Applications/Mousecape.app/Contents/Library/LoginItems/MousecapeHelper.app
```

Expected: `SIGNED_OK`.

- [ ] **Step 2: Confirm the running agent is the new build**

Run: `for p in $(pgrep -f "ClickAssistAgent|MousecapeHelper"); do echo "$(ps -o lstart= -p $p) $(lsof -p $p 2>/dev/null | awk '$4=="txt" && /MacOS/ {print $NF}' | head -1)"; done`
Expected: start times after the copy; paths under `/Applications/Mousecape.app`.

- [ ] **Step 3: Log check**

Hover a web page for ~10 s, then run:
`grep RESOLVER_PUBLISH ~/Library/Logs/Mousecape/ClickAssistAgent.log | tail -3 | grep -o "tileTooSmall=[0-9]* tileTooWide=[0-9]*\|rej=\[[^]]*\]"`
Expected: fields present; `rej=` may list `oversized` / `notTrackShaped`, never `rowTooLarge`/`tileTooLarge`/`pressTooLarge`.

- [ ] **Step 4: User live check (needs the user's eyes)**

Ask the user to confirm:
1. Large web cards / big thumbnails / wide list rows now ring.
2. Hovering empty page space does not ring the whole page.
3. Hovering a YouTube video does not ring the whole player; the seek bar still rings.
4. Background one-click (previous fix) still works.

- [ ] **Step 5: Update graph**

Run: `graphify update .`
