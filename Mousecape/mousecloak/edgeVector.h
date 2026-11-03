//
//  edgeVector.h
//  Resolution-independent upscaling for hard-edged (flat-colour / low-poly) cursor art.
//
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// YES when partial-alpha pixels sit on narrow ramps between clear and opaque
/// (hard-edged art), NO for wide soft falloffs such as shadows and glows.
BOOL MCImageHasHardEdges(CGImageRef image);

/// Re-renders `image` at targetW x targetH by tracing its alpha silhouette into
/// vector polygons (sub-pixel marching squares + simplification) and filling them
/// at the target resolution, so the outline stays razor sharp at any zoom. Colour
/// is bled outward past the silhouette then smoothly resampled and clipped by the
/// vector mask (no fringes). Returns a +1 retained sRGB image, or NULL on failure
/// (caller falls back to the raster path).
CGImageRef _Nullable MCVectorUpscaleHardEdges(CGImageRef image, size_t targetW, size_t targetH) CF_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END
