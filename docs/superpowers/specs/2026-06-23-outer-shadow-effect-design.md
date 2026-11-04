# Outer Shadow (drop shadow) effect — design

Date: 2026-06-23

## Goal
Add a third independent cursor effect, **Outer Shadow**, alongside the existing
Inner Shadow and Outer Glow. It casts a soft dark drop shadow offset toward the
bottom-right so the cursor appears to float above the surface (3D look).

## Decisions (from brainstorming)
- Style: **classic drop shadow** — dark, offset bottom-right (light from top-left).
- Controls: **simple on/off toggle**, fixed/auto-tuned params, matching the other
  two effects (no sliders).

## Behaviour
- Applied per cursor image, in `applyCapeForIdentifier`, after Inner Shadow and
  Outer Glow. All three only paint transparent pixels *outside* the cursor shape
  and never modify the cursor pixels themselves, so they compose cleanly and do
  not affect sharpness.
- Offset and blur are computed **proportional to the image width** (offset ≈ 3%,
  blur ≈ 4%, intensity ≈ 0.5) so the shadow looks consistent at any cursor scale.
  Effects run on the already-upscaled image, so absolute px would look different
  per cursor size.

## Implementation (mirrors Outer Glow)
1. `mousecloak/outerShadow.h/.m` (new):
   `CGImageRef MCApplyOuterShadow(CGImageRef image, float radius, float intensity,
   float offsetX, float offsetY)`. Same alpha extract + 3-pass vImage box blur as
   `outerGlow.m`, then sample the blurred alpha at `(x-offsetX, y+offsetY)` and
   paint **premultiplied black** (`A=val, R=G=B=0`) where outside the shape.
2. `mousecloak/MCPrefs.h/.m`: add `MCPreferencesOuterShadowKey = @"MCOuterShadow"`.
3. `mousecloak/apply.m`: read `BOOL outerShadow = MCFlag(MCPreferencesOuterShadowKey);`
   and add an effect block after the outer-glow block.
4. SwiftUI: `UserPreferences.swift` key + `SettingsView.swift` "Outer Shadow"
   toggle/state/save+load (mirror Outer Glow).
5. `Mousecape.xcodeproj/project.pbxproj`: register `outerShadow.m` in all 3 targets
   (mirror outerGlow's PBXBuildFile / PBXFileReference / group / Sources entries
   with fresh UUIDs).

## Risk / notes
- Bitmap buffer orientation: drop-shadow direction depends on the CGBitmapContext
  row order. Best-guess is `srcX = x-offsetX, srcY = y+offsetY` for bottom-right;
  if it renders on the wrong side, it is a one-line sign flip — confirm visually.
- No changes to the apply/scale/compositor paths, so the smooth giant cape and the
  restored sharpness are unaffected.
