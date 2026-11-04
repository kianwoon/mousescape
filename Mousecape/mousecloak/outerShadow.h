#import <CoreGraphics/CoreGraphics.h>

/// Applies an outer (drop) shadow effect to a cursor image.
/// Casts a soft dark shadow offset behind the cursor shape so the cursor appears
/// to float above the surface (3D look). Only transparent pixels OUTSIDE the
/// cursor shape are painted — the cursor pixels themselves are left untouched.
/// @param image The source CGImage (typically RGBA, 8-bpc)
/// @param radius Shadow blur radius in pixels (blur spread).
/// @param intensity Shadow opacity 0.0-1.0.
/// @param offsetX Horizontal shadow offset in pixels (positive = shadow to the right).
/// @param offsetY Vertical shadow offset in pixels (positive = shadow downward on screen).
/// @return A new CGImage with the drop shadow applied. Caller must CGImageRelease.
///         Returns NULL if the input is invalid or processing fails.
CGImageRef MCApplyOuterShadow(CGImageRef image, float radius, float intensity, float offsetX, float offsetY);
