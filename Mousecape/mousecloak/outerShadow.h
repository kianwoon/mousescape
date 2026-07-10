#import <CoreGraphics/CoreGraphics.h>

/// Applies an outer shadow effect to a cursor image.
/// Adds a soft dark halo around the cursor shape edges for contrast on light
/// backgrounds — the dark counterpart to MCApplyOuterGlow's white halo.
/// @param image The source CGImage (typically RGBA, 8-bpc)
/// @param radius Shadow radius in pixels (blur spread). Default 6.0.
/// @param intensity Shadow opacity 0.0-1.0. Default 0.5.
/// @return A new CGImage with outer shadow applied. Caller must CGImageRelease.
///         Returns NULL if the input is invalid or processing fails.
CGImageRef MCApplyOuterShadow(CGImageRef image, float radius, float intensity);
