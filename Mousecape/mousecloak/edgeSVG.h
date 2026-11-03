//
//  edgeSVG.h
//  Renders a cape cursor's optional vector (SVG) source at an exact pixel size.
//
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Renders `svg` into a square `side` x `side` sRGB bitmap, aspect-fit and centred
/// exactly like CursorImageScaler.scaleImageToStandardSize (so the cape hotspot
/// stays valid). `mirror` flips horizontally for left-handed mode.
/// Returns a +1 retained image, or NULL if the markup cannot be rendered.
CGImageRef _Nullable MCRenderSVGCursor(NSString *svg, size_t side, BOOL mirror) CF_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END
