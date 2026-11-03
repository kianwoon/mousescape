//
//  edgeSVG.m
//
#import "edgeSVG.h"
#import <AppKit/AppKit.h>

CGImageRef MCRenderSVGCursor(NSString *svg, size_t side, BOOL mirror) {
    @autoreleasepool {
        NSData *data = [svg dataUsingEncoding:NSUTF8StringEncoding];
        if (!data.length || side == 0) return NULL;
        NSImage *image = [[NSImage alloc] initWithData:data];
        if (!image || image.size.width <= 0 || image.size.height <= 0) return NULL;

        CGFloat side_f = (CGFloat)side;
        CGFloat scale = fmin(side_f / image.size.width, side_f / image.size.height);
        CGFloat dw = image.size.width * scale, dh = image.size.height * scale;
        NSRect dest = NSMakeRect((side_f - dw) / 2, (side_f - dh) / 2, dw, dh);

        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate(NULL, side, side, 8, side * 4, cs,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(cs);
        if (!ctx) return NULL;
        CGContextSetShouldAntialias(ctx, true);
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        if (mirror) {
            CGContextTranslateCTM(ctx, side_f, 0);
            CGContextScaleCTM(ctx, -1, 1);
        }
        NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:gc];
        [image drawInRect:dest fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                 fraction:1.0 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        [NSGraphicsContext restoreGraphicsState];
        CGImageRef result = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        return result;
    }
}
