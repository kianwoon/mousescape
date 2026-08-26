//
//  apply.m
//  Mousecape
//
//  Created by Alex Zielenski on 2/1/14.
//  Copyright (c) 2014 Alex Zielenski. All rights reserved.
//

#import "create.h"
#import "backup.h"
#import "restore.h"
#import "MCPrefs.h"
#import "NSBitmapImageRep+ColorSpace.h"
#import "MCDefs.h"
#import "innerShadow.h"
#import "outerGlow.h"
#import "outerShadow.h"
#import "scale.h"
#import <unistd.h>
#import <pthread.h>
#import <math.h>
#import <CoreImage/CoreImage.h>

// Re-entry guard: prevents concurrent apply/refresh calls.
// Without this, a display reconfiguration during extraction reads the boosted
// scale as "saved" and restores to it permanently.
// Declared extern so listen.m callbacks can also check it.
volatile BOOL g_refreshingSystemDefaults = NO;

// ---------------------------------------------------------------------------
// Names actually written by cape registrations in this apply pass.
// SINGLE SOURCE OF TRUTH for synonym protection: MCRegisterImagesForCursorName
// records every name it successfully registers (a cape entry like ArrowS
// writes itself AND its synonyms ArrowCtx/Arrow/…; resize cursors write their
// whole synonym set, etc.).  The system-defaults re-registration loop (Step 5)
// consults this set instead of hand-maintained prefix lists — any name a cape
// touched is protected from being overwritten by an 8x8 system bitmap.
// Reset at the start of each applyCapeWithoutReset pass.
// ---------------------------------------------------------------------------
static NSMutableSet<NSString *> *g_capeRegisteredNames = nil;

static BOOL MCRegisterImagesForCursorName(NSUInteger frameCount, CGFloat frameDuration, CGPoint hotSpot, CGSize size, NSArray *images, NSString *name) {
    char *cursorName = (char *)name.UTF8String;
    int seed = 0;
    CGSConnectionID cid = CGSMainConnectionID();

    MMLog("--- Registering cursor ---");
    MMLog("  Name: %s", cursorName);
    MMLog("  CGSConnectionID: %d", cid);
    MMLog("  Size: %.1fx%.1f points", size.width, size.height);
    MMLog("  HotSpot: (%.1f, %.1f)", hotSpot.x, hotSpot.y);
    MMLog("  Frames: %lu, Duration: %.4f sec", (unsigned long)frameCount, frameDuration);
    MMLog("  Images array count: %lu", (unsigned long)[images count]);

#ifdef DEBUG
    // Log detailed image info in DEBUG mode
    for (NSUInteger i = 0; i < images.count; i++) {
        CGImageRef img = (__bridge CGImageRef)images[i];
        if (img) {
            MMLog("    Image[%lu]: %zux%zu pixels, %zu bpc, %zu bpp",
                  (unsigned long)i,
                  CGImageGetWidth(img),
                  CGImageGetHeight(img),
                  CGImageGetBitsPerComponent(img),
                  CGImageGetBitsPerPixel(img));
        }
    }
#endif

    // Validate and clamp hot spot to valid range to prevent CGError=1000
    // Hot spot coordinates must be within the cursor's actual registration size
    // (0 <= hotSpot < size). For standard 32x32 cursors this is effectively 31.99,
    // but custom-scaled cursors may register at larger point sizes (e.g. 640x640 at 20x).
    CGFloat maxX = (size.width > 0) ? size.width - 0.01 : MCMaxHotspotValue;
    CGFloat maxY = (size.height > 0) ? size.height - 0.01 : MCMaxHotspotValue;
    BOOL clamped = NO;
    if (hotSpot.x < 0) {
        hotSpot.x = 0;
        clamped = YES;
    } else if (hotSpot.x > maxX) {
        hotSpot.x = maxX;
        clamped = YES;
    }
    if (hotSpot.y < 0) {
        hotSpot.y = 0;
        clamped = YES;
    } else if (hotSpot.y > maxY) {
        hotSpot.y = maxY;
        clamped = YES;
    }

    if (clamped) {
        MMLog(YELLOW "  Hot spot was out of bounds, clamped to (%.1f, %.1f)" RESET, hotSpot.x, hotSpot.y);
    }

    MMLog("  Calling CGSRegisterCursorWithImages...");

    CGError err = CGSRegisterCursorWithImages(cid,
                                              cursorName,
                                              true,
                                              true,
                                              size,
                                              hotSpot,
                                              frameCount,
                                              frameDuration,
                                              (__bridge CFArrayRef)images,
                                              &seed);

    MMLog("  Result: %s (CGError=%d, seed=%d)",
          (err == kCGErrorSuccess) ? "SUCCESS" : "FAILED", err, seed);

    if (err == kCGErrorSuccess && g_capeRegisteredNames) {
        // Record for Step 5 synonym protection (see g_capeRegisteredNames).
        [g_capeRegisteredNames addObject:name];
    }
    return (err == kCGErrorSuccess);
}

BOOL applyCursorForIdentifier(NSUInteger frameCount, CGFloat frameDuration, CGPoint hotSpot, CGSize size, NSArray *images, NSString *ident, NSUInteger repeatCount, BOOL skipSynonyms) {
    MMLog("=== applyCursorForIdentifier ===");
    MMLog("  Identifier: %s", ident.UTF8String);
    MMLog("  Skip synonyms: %s", skipSynonyms ? "YES" : "NO");

    if (frameCount > 24 || frameCount < 1) {
        MMLog(BOLD RED "Frame count of %s out of range [1...24]", ident.UTF8String);
        return NO;
    }

    // When skipSynonyms is set, register only for this exact identifier.
    // This prevents system default cursors (e.g. ArrowCtx) from overwriting
    // related cursors that have custom images (e.g. ArrowS).
    if (skipSynonyms) {
        BOOL success = MCRegisterImagesForCursorName(frameCount, frameDuration, hotSpot, size, images, ident);
        MMLog("  Direct registration result: %s", success ? "SUCCESS" : "FAILED");
        return success;
    }

    // Special handling for Arrow on newer macOS where the underlying name may have changed.
    // NOTE: ArrowS must be here too — this cape (and real-world capes) may
    // contain ArrowS WITHOUT a separate Arrow entry.  If ArrowS skips synonym
    // registration, ArrowCtx (the name macOS actually renders the pointer
    // through) never receives the custom image and stays an 8x8 system
    // bitmap → blinking/vanishing pointer after re-applies (2026-08-26).
    BOOL isArrow = ([ident hasPrefix:@"com.apple.coregraphics.Arrow"]);
    BOOL isIBeam = ([ident hasPrefix:@"com.apple.coregraphics.IBeam"]);

    MMLog("  Is Arrow: %s, Is IBeam: %s", isArrow ? "YES" : "NO", isIBeam ? "YES" : "NO");

    if (isArrow) {
        BOOL anySuccess = NO;
        NSArray *synonyms = MCArrowSynonyms();
        MMLog("  Arrow synonyms to register: %lu", (unsigned long)synonyms.count);
        for (NSString *syn in synonyms) {
            MMLog("    - %s", syn.UTF8String);
        }

        // Register for all discovered Arrow-related names.
        for (NSString *name in synonyms) {
            if (name.length == 0) {
                continue;
            }
            if (MCRegisterImagesForCursorName(frameCount, frameDuration, hotSpot, size, images, name)) {
                anySuccess = YES;
            }
        }
        // Also try the legacy identifier if it wasn't in the discovered set.
        if (![synonyms containsObject:ident]) {
            MMLog("  Trying legacy identifier: %s", ident.UTF8String);
            if (MCRegisterImagesForCursorName(frameCount, frameDuration, hotSpot, size, images, ident)) {
                anySuccess = YES;
            }
        }

        // Reduce the chance of the Dock overriding the cursor immediately after registration.
        CGSSetDockCursorOverride(CGSMainConnectionID(), false);
        MMLog("  Arrow registration result: %s", anySuccess ? "SUCCESS" : "FAILED");
        return anySuccess;
    }

    // Special handling for I-beam (text cursor) on newer macOS
    if (isIBeam) {
        BOOL anySuccess = NO;
        NSArray *synonyms = MCIBeamSynonyms();
        MMLog("  IBeam synonyms to register: %lu", (unsigned long)synonyms.count);
        for (NSString *syn in synonyms) {
            MMLog("    - %s", syn.UTF8String);
        }

        for (NSString *name in synonyms) {
            if (name.length == 0) {
                continue;
            }
            if (MCRegisterImagesForCursorName(frameCount, frameDuration, hotSpot, size, images, name)) {
                anySuccess = YES;
            }
        }
        if (![synonyms containsObject:ident]) {
            MMLog("  Trying legacy identifier: %s", ident.UTF8String);
            if (MCRegisterImagesForCursorName(frameCount, frameDuration, hotSpot, size, images, ident)) {
                anySuccess = YES;
            }
        }
        CGSSetDockCursorOverride(CGSMainConnectionID(), false);
        MMLog("  IBeam registration result: %s", anySuccess ? "SUCCESS" : "FAILED");
        return anySuccess;
    }

    // Check if this is a resize cursor that needs synonym expansion
    NSArray *resizeSynonyms = MCResizeSynonyms(ident);
    if (resizeSynonyms) {
        MMLog("  Resize synonyms to register: %lu", (unsigned long)resizeSynonyms.count);
        for (NSString *syn in resizeSynonyms) {
            MMLog("    - %s", syn.UTF8String);
        }
        BOOL anySuccess = NO;
        for (NSString *name in resizeSynonyms) {
            if (MCRegisterImagesForCursorName(frameCount, frameDuration, hotSpot, size, images, name)) {
                anySuccess = YES;
            }
        }
        MMLog("  Resize registration result: %s", anySuccess ? "SUCCESS" : "FAILED");
        return anySuccess;
    }

    // Default behavior for all other cursors.
    MMLog("  Using default registration");
    return MCRegisterImagesForCursorName(frameCount, frameDuration, hotSpot, size, images, ident);
}

// Read system cursor data directly, bypassing the MCIsCursorRegistered check.
// This is needed because CoreCursorUnregisterAll() unregisters cursors, but
// system built-in cursors (com.apple.cursor.*) are still readable via CoreCursorCopyImages.
// Unlike capeWithIdentifier, this skips the MCIsCursorRegistered check and also
// calls CoreCursorSet first to activate the cursor before reading (required by CoreCursorCopyImages).
static NSDictionary * _Nullable systemCapeWithIdentifier(NSString *identifier) {
    NSUInteger frameCount;
    CGFloat frameDuration;
    CGPoint hotSpot;
    CGSize size;
    CFArrayRef representations = NULL;

    CGError error = 0;
    if (![identifier hasPrefix:@"com.apple.cursor"]) {
        // For named cursors (com.apple.coregraphics.*), CGSCopyRegisteredCursorImages
        // should work without activation
        error = CGSCopyRegisteredCursorImages(CGSMainConnectionID(), (char *)identifier.UTF8String, &size, &hotSpot, &frameCount, &frameDuration, &representations);

        // Fallback: if CGSCopyRegisteredCursorImages fails (e.g., cursor was unregistered),
        // scan numeric IDs to find the matching system cursor and read via CoreCursorCopyImages.
        // This is needed after resetAllCursors() unregisters named cursors but CoreCursorSet
        // restores numeric cursors — macOS doesn't auto-fallback for named cursors.
        if (error || !representations || !CFArrayGetCount(representations)) {
            MMLog("  systemCape: CGSCopyRegisteredCursorImages failed for %s (err=%d), trying numeric fallback",
                  identifier.UTF8String, (int)error);
            for (int cursorID = 0; cursorID < 128; cursorID++) {
                char *cname = CGSCursorNameForSystemCursor((CGSCursorID)cursorID);
                if (!cname) continue;
                NSString *sysName = [NSString stringWithUTF8String:cname];
                if ([sysName isEqualToString:identifier]) {
                    MMLog("  systemCape: Found match at cursor ID %d for %s", cursorID, cname);
                    error = CoreCursorSet(CGSMainConnectionID(), cursorID);
                    if (error == noErr) {
                        error = CoreCursorCopyImages(CGSMainConnectionID(), cursorID, &representations, &size, &hotSpot, &frameCount, &frameDuration);
                        MMLog("  systemCape: CoreCursorCopyImages result: %d, reps=%lu",
                              (int)error, (unsigned long)(representations ? CFArrayGetCount(representations) : 0));
                    }
                    break;
                }
            }
        }
    } else {
        // For numbered cursors (com.apple.cursor.N), CoreCursorCopyImages reads the
        // ACTIVE cursor. We must call CoreCursorSet first to activate it, just like
        // dumpCursorsToFile does before reading.
        CGSCursorID cursorID = [[identifier pathExtension] intValue];
        MMLog("  systemCape: CoreCursorSet(%d) for %s", (int)cursorID, identifier.UTF8String);
        error = CoreCursorSet(CGSMainConnectionID(), cursorID);
        MMLog("  systemCape: CoreCursorSet result: %d", (int)error);
        if (error == noErr) {
            error = CoreCursorCopyImages(CGSMainConnectionID(), cursorID, &representations, &size, &hotSpot, &frameCount, &frameDuration);
            MMLog("  systemCape: CoreCursorCopyImages result: %d, reps=%lu", (int)error, (unsigned long)(representations ? CFArrayGetCount(representations) : 0));
        }
    }

    if (error || !representations || !CFArrayGetCount(representations)) {
        MMLog(YELLOW "  systemCape FAILED for %s: error=%d, reps=%p" RESET, identifier.UTF8String, (int)error, representations);
        return nil;
    }

    // Determine the base point size for this cursor.
    // CoreCursorCopyImages may return size={0,0} for numbered cursors, or a scaled
    // size when CGSSetCursorScale is boosted for high-res extraction.
    // We always want the NATIVE base point size (32×32 for standard cursors) so
    // that applyCapeForIdentifier can scale it by the per-cursor ratio.
    if (size.width < 1.0 || size.height < 1.0 || size.width > 64.0 || size.height > 64.0) {
        CGFloat origW = size.width;
        CGFloat origH = size.height;
        CGPoint origHotSpot = hotSpot;
        // Normalize hotspot from the API-returned coordinate space to 32×32 base
        if (origW > 1.0 && origH > 1.0) {
            hotSpot = CGPointMake(hotSpot.x * (32.0 / origW), hotSpot.y * (32.0 / origH));
        }
        size = CGSizeMake(32.0, 32.0);
        MMLog("  Normalized size/hotspot for %s: (%.0fx%.0f, hs=%.1f,%.1f) → (32x32, hs=%.1f,%.1f)",
              identifier.UTF8String,
              origW, origH, origHotSpot.x, origHotSpot.y,
              hotSpot.x, hotSpot.y);
    }

    NSDictionary *dict = @{MCCursorDictionaryFrameCountKey: @(frameCount), MCCursorDictionaryFrameDuratiomKey: @(frameDuration), MCCursorDictionaryHotSpotXKey: @(hotSpot.x), MCCursorDictionaryHotSpotYKey: @(hotSpot.y), MCCursorDictionaryPointsWideKey: @(size.width), MCCursorDictionaryPointsHighKey: @(size.height), MCCursorDictionaryRepresentationsKey: (__bridge NSArray *)representations};

    CFRelease(representations);
    return dict;
}

// Shared CIContext for all upscale+sharpen operations (heavyweight GPU object,
// creating one per frame per cursor is wasteful).
static CIContext *MCSharedCIContext() {
    static CIContext *ctx = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    });
    return ctx;
}

// Apply unsharp mask sharpening to enhance cursor edge crispness after upscaling.
// Upscale + sharpen using Core Image for high quality.
// Uses Lanczos resampling (much sharper than bicubic) + CISharpenLuminance
// for perceptual edge enhancement. Falls back to CGContext if CIImage fails.
static CGImageRef _Nullable MCUpscaleAndSharpen(CGImageRef original, NSUInteger targetW, NSUInteger targetH, CGFloat sharpness) {
    @autoreleasepool {
        CIImage *ciImg = [CIImage imageWithCGImage:original];
        if (!ciImg) return NULL;

        CGFloat scaleW = (CGFloat)targetW / (CGFloat)CGImageGetWidth(original);
        CGFloat scaleH = (CGFloat)targetH / (CGFloat)CGImageGetHeight(original);

        // Lanczos scale transform — significantly sharper than CGContext bicubic
        CIFilter *lanczos = [CIFilter filterWithName:@"CILanczosScaleTransform"];
        [lanczos setDefaults];
        [lanczos setValue:ciImg forKey:kCIInputImageKey];
        [lanczos setValue:@(scaleW) forKey:@"inputScale"];
        [lanczos setValue:@(scaleH / scaleW) forKey:@"inputAspectRatio"];
        CIImage *scaled = lanczos.outputImage;

        // Sharpen luminance — perceptual edge enhancement
        if (sharpness > 0.01) {
            CIFilter *sharpen = [CIFilter filterWithName:@"CISharpenLuminance"];
            [sharpen setDefaults];
            [sharpen setValue:scaled forKey:kCIInputImageKey];
            [sharpen setValue:@(sharpness) forKey:@"inputSharpness"];
            scaled = sharpen.outputImage;
        }

        // Render to CGImage (release CGColorSpace to avoid leak)
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGImageRef result = [MCSharedCIContext() createCGImage:scaled fromRect:CGRectMake(0, 0, targetW, targetH)
                                                        format:kCIFormatBGRA8
                                                     colorSpace:cs];
        CGColorSpaceRelease(cs);
        return result;
    }
}

BOOL applyCapeForIdentifier(NSDictionary *cursor, NSString *identifier, BOOL restore, BOOL customScaleMode, BOOL skipSynonyms, BOOL isSystemDefault, float baseScale) {
    MMLog("=== applyCapeForIdentifier ===");
    MMLog("  Identifier: %s", identifier.UTF8String);
    MMLog("  Restore mode: %s", restore ? "YES" : "NO");

    if (!cursor || !identifier) {
        MMLog(BOLD RED "  Invalid cursor or identifier (bad seed)" RESET);
        return NO;
    }

    BOOL lefty = MCFlag(MCPreferencesHandednessKey);
    BOOL innerShadow = MCFlag(MCPreferencesInnerShadowKey);
    BOOL outerGlow = MCFlag(MCPreferencesOuterGlowKey);
    BOOL outerShadow = MCFlag(MCPreferencesOuterShadowKey);
    BOOL pointer = MCCursorIsPointer(identifier);
    NSNumber *frameCount    = cursor[MCCursorDictionaryFrameCountKey];
    NSNumber *frameDuration = cursor[MCCursorDictionaryFrameDuratiomKey];

    MMLog("  Lefty mode: %s", lefty ? "YES" : "NO");
    MMLog("  Is pointer: %s", pointer ? "YES" : "NO");
    MMLog("  FrameCount: %s", frameCount.description.UTF8String);
    MMLog("  FrameDuration: %s", frameDuration.description.UTF8String);
    //    NSNumber *repeatCount   = cursor[MCCursorDictionaryRepeatCountKey];
    
    CGPoint hotSpot         = CGPointMake([cursor[MCCursorDictionaryHotSpotXKey] doubleValue],
                                          [cursor[MCCursorDictionaryHotSpotYKey] doubleValue]);
    CGSize size             = CGSizeMake([cursor[MCCursorDictionaryPointsWideKey] doubleValue],
                                         [cursor[MCCursorDictionaryPointsHighKey] doubleValue]);
    NSArray *reps           = cursor[MCCursorDictionaryRepresentationsKey];
    NSMutableArray *images  = [NSMutableArray array];

    MMLog("  HotSpot: (%.1f, %.1f)", hotSpot.x, hotSpot.y);
    MMLog("  Size: %.1fx%.1f", size.width, size.height);
    MMLog("  Representations count: %lu", (unsigned long)[reps count]);

    if (lefty && !restore) {
        MMLog("Lefty mode for %s", identifier.UTF8String);
        hotSpot.x = size.width - hotSpot.x - 1;
    }

    // Always select the highest resolution representation available.
    // Starting from the highest quality source ensures the system can scale
    // down cleanly rather than upscaling from a low-res rep (which causes pixelation).
    NSBitmapImageRep *bestRep = nil;
    NSUInteger bestPixelCount = 0;
    for (id object in reps) {
        CFTypeID type = CFGetTypeID((__bridge CFTypeRef)object);
        NSBitmapImageRep *rep;
        if (type == CGImageGetTypeID()) {
            rep = [[NSBitmapImageRep alloc] initWithCGImage:(__bridge CGImageRef)object];
        } else {
            rep = [[NSBitmapImageRep alloc] initWithData:object];
        }
        rep = rep.retaggedSRGBSpace;

        NSUInteger pixelCount = (NSUInteger)rep.pixelsWide * (NSUInteger)rep.pixelsHigh;
        if (pixelCount > bestPixelCount) {
            bestPixelCount = pixelCount;
            bestRep = rep;
        }
    }
    MMLog("  Selected highest resolution representation: %lupx (%lux%lu)",
          (unsigned long)bestPixelCount, (unsigned long)bestRep.pixelsWide, (unsigned long)bestRep.pixelsHigh);

    if (bestRep) {
        if (!lefty || restore) {
            images[images.count] = (__bridge id)[bestRep CGImage];
        } else {
            NSBitmapImageRep *newRep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                               pixelsWide:bestRep.pixelsWide
                                                                               pixelsHigh:bestRep.pixelsHigh
                                                                            bitsPerSample:8
                                                                          samplesPerPixel:4
                                                                                 hasAlpha:YES
                                                                                 isPlanar:NO
                                                                           colorSpaceName:NSCalibratedRGBColorSpace
                                                                              bytesPerRow:4 * bestRep.pixelsWide
                                                                             bitsPerPixel:32];
            NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:newRep];
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext setCurrentContext:ctx];
            NSAffineTransform *transform = [NSAffineTransform transform];
            [transform translateXBy:bestRep.pixelsWide yBy:0];
            [transform scaleXBy:-1 yBy:1];
            [transform concat];

            [bestRep drawInRect:NSMakeRect(0, 0, bestRep.pixelsWide, bestRep.pixelsHigh)
                       fromRect:NSZeroRect
                      operation:NSCompositingOperationSourceOver
                       fraction:1.0
                respectFlipped:NO
                         hints:nil];
            [NSGraphicsContext restoreGraphicsState];
            images[images.count] = (__bridge id)[newRep CGImage];
        }
    }

    // Per-cursor custom scaling — compute the ratio and effective registration
    // size FIRST so the upscale logic below knows the true pixel requirements.
    // Previously this ran after upscale, so the upscale target was based on the
    // pre-scaling size (32pt) and 2048×2048 was deemed "enough" — but at 35x
    // custom scale the cursor registers at 1120pt (2240px on Retina), far beyond
    // 2048px, causing pixelation.
    CGFloat customRatio = 1.0;
    if (customScaleMode) {
        NSDictionary *perCursorScales = MCDefault(MCPreferencesPerCursorScalesKey);
        MMLog("SCALE DEBUG per-cursor %s: perCursorScales=%@, customMode=YES, skipSynonyms=%s",
              identifier.UTF8String, perCursorScales, skipSynonyms ? "YES" : "NO");
        float desiredScale = [perCursorScales[identifier] floatValue];
        if (desiredScale <= 0.0f) desiredScale = 1.0f;

        float maxScale = baseScale;
        if (maxScale <= 0.0f) maxScale = 1.0f;
        customRatio = (maxScale > 0) ? desiredScale / maxScale : 1.0f;
        MMLog("SCALE DEBUG per-cursor %s: desired=%.2f, baseScale=%.2f, ratio=%.3f",
              identifier.UTF8String, desiredScale, maxScale, customRatio);
    }

    // Compute the FINAL registration size (after custom scaling) so the upscale
    // knows the true pixel budget needed.
    CGSize effectiveSize = CGSizeMake(size.width * customRatio, size.height * customRatio);

    // Upscale + sharpen low-resolution images when the source has significantly
    // fewer pixels than needed for crisp rendering at the target scale.
    // Uses Core Image Lanczos resampling (much sharper than bicubic) followed by
    // CISharpenLuminance for perceptual edge enhancement.
    // Since we always select the highest resolution representation, this primarily
    // helps system default cursors whose native images may be small (e.g. 64×64)
    // and cape cursors at very high custom scales (e.g. 35x → 1120pt).
    if (images.count > 0 && bestRep) {
        NSUInteger srcPixels = (NSUInteger)bestRep.pixelsWide * (NSUInteger)bestRep.pixelsHigh;

        // Calculate minimum pixels needed for crisp rendering at the FINAL
        // registration size (after custom scaling).  On Retina (2x), a cursor
        // registered at S pt needs S*2 pixels per dimension.  Add 1.5x safety.
        // We work in LINEAR pixels first, then square for the area comparison.
        CGFloat maxNeededPt = fmax(effectiveSize.width, effectiveSize.height);
        NSUInteger minNeededLinear = (NSUInteger)(maxNeededPt * 2.0 * 1.5);
        if (minNeededLinear < 2048) minNeededLinear = 2048;
        if (minNeededLinear > 4096) minNeededLinear = 4096;
        NSUInteger minNeededPixels = minNeededLinear * minNeededLinear;

        MMLog("  Upscale check: src=%lupx, minNeeded=%lupx (linear=%lu, effectiveSize=%.1fx%.1fpt, ratio=%.1f)",
              (unsigned long)srcPixels, (unsigned long)minNeededPixels,
              (unsigned long)minNeededLinear, effectiveSize.width, effectiveSize.height, customRatio);

        if (srcPixels < minNeededPixels) {
            NSUInteger targetPixelCount = minNeededPixels;

            if (targetPixelCount > srcPixels) {
                CGFloat scaleFactor = sqrt((CGFloat)targetPixelCount / (CGFloat)srcPixels);
                NSUInteger newWidth = (NSUInteger)(bestRep.pixelsWide * scaleFactor + 0.5);
                NSUInteger newHeight = (NSUInteger)(bestRep.pixelsHigh * scaleFactor + 0.5);
                CGFloat sharpness = 0.3 + (scaleFactor - 1.0) * 0.2;
                if (sharpness < 0.0) sharpness = 0.0;
                if (sharpness > 1.5) sharpness = 1.5;
                MMLog("  Upscale+sharpen: %lux%lu → %lux%lu (%.1fx), sharpness=%.2f",
                      (unsigned long)bestRep.pixelsWide, (unsigned long)bestRep.pixelsHigh,
                      (unsigned long)newWidth, (unsigned long)newHeight, scaleFactor, sharpness);

                NSMutableArray *processed = [NSMutableArray arrayWithCapacity:images.count];
                for (id imgObj in images) {
                    CGImageRef original = (__bridge CGImageRef)imgObj;
                    NSUInteger w = CGImageGetWidth(original);
                    NSUInteger h = CGImageGetHeight(original);
                    NSUInteger tw = (NSUInteger)(w * scaleFactor + 0.5);
                    NSUInteger th = (NSUInteger)(h * scaleFactor + 0.5);
                    CGImageRef result = MCUpscaleAndSharpen(original, tw, th, sharpness);
                    [processed addObject:(__bridge id)(result ?: original)];
                    if (result && result != original) CGImageRelease(result);
                }
                if (processed.count > 0) {
                    images = processed;
                }
            }
        }
    }

    // Apply inner shadow effect if enabled
    if (innerShadow && images.count > 0) {
        float radius = 32.0f;
        float intensity = 0.6f;
        MMLog("Applying inner shadow effect (radius=%.1f, intensity=%.1f)", radius, intensity);
        NSMutableArray *processed = [NSMutableArray arrayWithCapacity:images.count];
        for (id imgObj in images) {
            CGImageRef original = (__bridge CGImageRef)imgObj;
            CGImageRef shadowed = MCApplyInnerShadow(original, radius, intensity);
            [processed addObject:(__bridge id)(shadowed ?: original)];
            if (shadowed) CGImageRelease(shadowed);
        }
        images = processed;
    }

    // Apply outer glow effect if enabled
    if (outerGlow && images.count > 0) {
        float radius = 40.0f;
        float intensity = 0.7f;
        MMLog("Applying outer glow effect (radius=%.1f, intensity=%.1f)", radius, intensity);
        NSMutableArray *processed = [NSMutableArray arrayWithCapacity:images.count];
        for (id imgObj in images) {
            CGImageRef original = (__bridge CGImageRef)imgObj;
            CGImageRef glowing = MCApplyOuterGlow(original, radius, intensity);
            [processed addObject:(__bridge id)(glowing ?: original)];
            if (glowing) CGImageRelease(glowing);
        }
        images = processed;
    }

    // Apply outer shadow effect if enabled — the dark counterpart to outer glow
    if (outerShadow && images.count > 0) {
        float radius = 40.0f;
        float intensity = 0.7f;
        MMLog("Applying outer shadow effect (radius=%.1f, intensity=%.1f)", radius, intensity);
        NSMutableArray *processed = [NSMutableArray arrayWithCapacity:images.count];
        for (id imgObj in images) {
            CGImageRef original = (__bridge CGImageRef)imgObj;
            CGImageRef shadowed = MCApplyOuterShadow(original, radius, intensity);
            [processed addObject:(__bridge id)(shadowed ?: original)];
            if (shadowed) CGImageRelease(shadowed);
        }
        images = processed;
    }

    // Per-cursor custom scaling
    if (customScaleMode) {
        NSDictionary *perCursorScales = MCDefault(MCPreferencesPerCursorScalesKey);
        MMLog("SCALE DEBUG per-cursor %s: perCursorScales=%@, customMode=YES, skipSynonyms=%s",
              identifier.UTF8String, perCursorScales, skipSynonyms ? "YES" : "NO");
        float desiredScale = [perCursorScales[identifier] floatValue];
        if (desiredScale <= 0.0f) desiredScale = 1.0f;

        float maxScale = baseScale;
        if (maxScale <= 0.0f) maxScale = 1.0f;
        float ratio = (maxScale > 0) ? desiredScale / maxScale : 1.0f;
        MMLog("SCALE DEBUG per-cursor %s: desired=%.2f, baseScale=%.2f, ratio=%.3f",
              identifier.UTF8String, desiredScale, maxScale, ratio);

        if (ratio < 0.99f || ratio > 1.01f) {
            // Scale registration size and hotspot by ratio.
            // Images are NOT scaled — the representation selection (effectiveScale)
            // already picks the appropriate resolution. The system handles
            // image-to-registration-size mapping internally.
            size = CGSizeMake(size.width * ratio, size.height * ratio);
            MMLog("Custom scaling %s: desired=%.2f, ratio=%.3f, newSize=%.1fx%.1fpt",
                  identifier.UTF8String, desiredScale, ratio, size.width, size.height);

            hotSpot = CGPointMake(hotSpot.x * ratio, hotSpot.y * ratio);
            MMLog("Hotspot scaled by ratio %.3f: (%.1f, %.1f)", ratio, hotSpot.x, hotSpot.y);
        }
    }

    return applyCursorForIdentifier(frameCount.unsignedIntegerValue, frameDuration.doubleValue, hotSpot, size, images, identifier, 0, skipSynonyms);
}

BOOL applyCape(NSDictionary *dictionary) {
    @autoreleasepool {
        NSDictionary *cursors = dictionary[MCCursorDictionaryCursorsKey];
        NSString *name = dictionary[MCCursorDictionaryCapeNameKey];
        NSNumber *version = dictionary[MCCursorDictionaryCapeVersionKey];

        MMLog("========================================");
        MMLog("=== APPLYING CAPE ===");
        MMLog("========================================");
        MMLog("Cape name: %s", name.UTF8String);
        MMLog("Cape identifier: %s", [dictionary[MCCursorDictionaryIdentifierKey] UTF8String]);
        MMLog("Cape version: %.2f", version.floatValue);
        MMLog("Total cursors: %lu", (unsigned long)cursors.count);
        MMLog("Cursor identifiers:");
        for (NSString *key in cursors) {
            MMLog("  - %s", key.UTF8String);
        }

        // Derive the target scale from preferences, NOT from cursorScale().
        // cursorScale() reads the WindowServer which can return corrupted values.
        float savedScale;
        {
            BOOL mode = customScaleMode();
            if (mode) {
                savedScale = [MCDefault(@"MCCustomMaxScale") floatValue];
                if (savedScale <= 0.0f) savedScale = 1.0f;
            } else {
                savedScale = [MCDefault(@"MCGlobalCursorScale") floatValue];
                if (savedScale < 0.5f || savedScale > 96.0f) savedScale = 1.0f;
            }
        }
        MMLog("Target scale (from prefs): %.2f (WindowServer reports: %.2f)",
              savedScale, cursorScale());

        MMLog("--- Calling resetAllCursors ---");
        resetAllCursors();
        MMLog("--- Calling backupAllCursors ---");
        backupAllCursors();

        // Read scale mode from direct C variable (not CFPreferences)
        BOOL isCustomMode = customScaleMode();

        // baseScaleForRegistration: the CGSSetCursorScale value set BEFORE cursor registration.
        // Used by applyCapeForIdentifier to compute per-cursor ratio without reading WindowServer.
        float baseScaleForRegistration = isCustomMode ? 1.0f : savedScale;

        if (isCustomMode) {
            float minScale = 96.0f;
            float maxScale = 1.0f;
            NSDictionary *perCursorScales = MCDefault(MCPreferencesPerCursorScalesKey);
            if (perCursorScales) {
                for (NSNumber *val in perCursorScales.allValues) {
                    float s = val.floatValue;
                    if (s > 0.0f && s < minScale) minScale = s;
                    if (s > maxScale) maxScale = s;
                }
            }
            // Custom mode: CGSSetCursorScale = 1.0, each cursor registers at its
            // desired point size directly (nativeSize × desiredScale).
            // Cape cursors use high-res images from the cape file (effectiveScale-based
            // representation selection picks the right resolution).
            // System defaults use native images with modest upscaling (acceptable ≤2x).
            float baseScale = 1.0f;
            MMLog("SCALE DEBUG: custom mode, maxScale=%.2f, baseScale=%.2f (direct registration)", maxScale, baseScale);
            setCursorScale(baseScale);
            // Save for listen.m to restore on session change
            MCSetDefault(@(baseScale), @"MCCustomMaxScale");
        } else {
            // Global mode: restore the exact scale that was active before reset
            MMLog("SCALE DEBUG: global mode, restoring to %.2f", savedScale);
            if (savedScale >= 0.5f && savedScale <= 96.0f) {
                setCursorScale(savedScale);
            } else {
                setCursorScale(defaultCursorScale());
            }
        }

        MMLog("--- Applying cursors ---");

        NSUInteger successCount = 0;
        NSUInteger skippedCount = 0;
        NSUInteger failedCount = 0;

        for (NSString *key in cursors) {
            NSDictionary *cape = cursors[key];
            MMLog("Hooking for %s", key.UTF8String);

            // Check if cursor has valid image data before attempting to apply
            NSArray *reps = cape[MCCursorDictionaryRepresentationsKey];
            if (!reps || reps.count == 0) {
                // System default cursors with no cape images are left alone
                // after resetAllCursors() — they are re-registered below with
                // per-cursor scaling via the MCEnumerateAllCursorIdentifiers loop.
                MMLog(YELLOW "  Skipping cursor %s - no image data (system default, re-registered below)" RESET, key.UTF8String);
                skippedCount++;
                continue;
            }

            BOOL success = applyCapeForIdentifier(cape, key, NO, isCustomMode, NO, NO, baseScaleForRegistration);
            if (!success) {
                MMLog(YELLOW "  Failed to apply cursor %s - continuing with remaining cursors..." RESET, key.UTF8String);
                failedCount++;
            } else {
                successCount++;
            }
        }

        // Re-register system default cursors not covered by the cape.
        // In custom mode: per-cursor scale is applied via the ratio in applyCapeForIdentifier.
        // In global mode: CGSSetCursorScale handles uniform scaling, but we still need to
        // register the defaults explicitly — otherwise the WindowServer caches stale images
        // and CGSSetCursorScale alone causes pixelation for unregistered cursor types.
        {
            MMLog("--- Re-registering system defaults (%s mode) ---", isCustomMode ? "custom" : "global");
            // Only include cursors that were SUCCESSFULLY applied (have images).
            // Skipped cursors (no image data in cape) must still be handled.
            NSMutableSet *registeredKeys = [NSMutableSet set];
            for (NSString *key in cursors) {
                NSArray *reps = cursors[key][MCCursorDictionaryRepresentationsKey];
                if (reps && reps.count > 0) {
                    [registeredKeys addObject:key];
                }
            }
            MMLog("  registeredKeys count (successfully applied): %lu of %lu total cape entries",
                  (unsigned long)registeredKeys.count, (unsigned long)cursors.count);

            // Temporarily boost cursor scale so CoreCursorCopyImages returns
            // high-resolution system cursor images (same trick as dumpCursorsToFile).
            // At scale=1.0, system cursors come back as tiny 64×64 bitmaps.
            // At scale=64.0, the system renders them at 64× native → ~2048px images.
            float extractScale = 64.0f;
            MMLog("  Boosting cursor scale to %.1f for high-res extraction", extractScale);
            CGSSetCursorScale(CGSMainConnectionID(), extractScale);
            CGSHideCursor(CGSMainConnectionID());

            __block NSUInteger systemDefaultCount = 0;
            __block NSUInteger skippedByRegisteredKeys = 0;
            MCEnumerateAllCursorIdentifiers(^(NSString *name) {
                if ([registeredKeys containsObject:name]) {
                    skippedByRegisteredKeys++;
                    return; // Already registered as cape cursor
                }
                NSDictionary *systemData = systemCapeWithIdentifier(name);
                if (!systemData) {
                    return; // No system cursor data available
                }
                BOOL ok = applyCapeForIdentifier(systemData, name, NO, isCustomMode, YES, YES, baseScaleForRegistration);
                if (ok) {
                    systemDefaultCount++;
                } else {
                    MMLog(YELLOW "  Failed to re-register system default %s" RESET, name.UTF8String);
                }
            });

            // Restore the original scale (savedScale from line 539, before resetAllCursors)
            MMLog("  Restoring cursor scale to %.1f after extraction", savedScale);
            CGSSetCursorScale(CGSMainConnectionID(), savedScale);
            CGSShowCursor(CGSMainConnectionID());

            MMLog("  Re-registered %lu system default cursors (skipped %lu by registeredKeys)", (unsigned long)systemDefaultCount, (unsigned long)skippedByRegisteredKeys);
        }

        MMLog("--- Application Summary ---");
        MMLog("  Total cursors: %lu", (unsigned long)cursors.count);
        MMLog("  Successfully applied: %lu", (unsigned long)successCount);
        MMLog("  Skipped (no images): %lu", (unsigned long)skippedCount);
        MMLog("  Failed: %lu", (unsigned long)failedCount);

        // Consider the cape application successful if at least one cursor was applied
        if (successCount == 0) {
            MMLog(BOLD RED "No cursors were successfully applied!" RESET);
            return NO;
        }

        MCSetDefault(dictionary[MCCursorDictionaryIdentifierKey], MCPreferencesAppliedCursorKey);

        if (skippedCount > 0 || failedCount > 0) {
            MMLog(BOLD GREEN "Applied %s with warnings (success: %lu, skipped: %lu, failed: %lu)" RESET,
                  name.UTF8String, (unsigned long)successCount, (unsigned long)skippedCount, (unsigned long)failedCount);
        } else {
            MMLog(BOLD GREEN "Applied %s successfully! (all %lu cursors)" RESET, name.UTF8String, (unsigned long)successCount);
        }
        return YES;
    }
}

// On macOS 27, registering a cape on a running session (ANY apply — manual,
// wake, session-change, display-reconfig) detaches the cursor from the
// Accessibility pointer-enlargement compositor (universalaccessd). When
// pointer enlargement is on, the cursor then falls back to software
// rendering and blinks/vanishes while moving — CGSRegisterCursorWithImages()
// itself succeeds, so this is invisible to the apply's own success/failure
// checks. Restarting universalaccessd (a user LaunchAgent; launchd relaunches
// it in ~1s) makes it re-engage the compositor on the just-applied cape —
// the same thing dragging System Settings > Accessibility > Pointer size does
// by hand. This must run after EVERY apply, not just wake/reconfig — a prior,
// unmerged fix (branch kianwoon/heuristic-banach-ddf1c0, commits 372c259 /
// d93d427) validated exactly this and shipped it as v1.0.3-v1.0.5. An earlier
// attempt here scoped this to wake-only recovery paths on the mistaken
// assumption that the restart itself caused flicker; it didn't — the flicker
// is inherent to any re-registration, and removing the reengage from manual
// applies just removed the cure.
//
// Only skipped when NEITHER trigger is active — universalaccessd also serves
// Zoom/VoiceOver/Switch Control and restarting it when there's nothing to
// recompose is needless. Two independent triggers, checked separately:
//
// 1. Accessibility pointer enlargement (mouseDriverCursorSize > 1) — the
//    documented case: macOS routes ALL cursor compositing through
//    universalaccessd once this preference is on, at any size.
//
// 2. A large Mousecape per-cursor/global scale is in effect, REGARDLESS of
//    the accessibility preference. CGSAccessibility.h's own comment on
//    CGSSetCursorScale notes "the largest the Universal Access prefpane
//    allows you to go is 4.0" — i.e. any cursor rendered beyond ~4x is
//    already outside what the standard hardware cursor plane supports and
//    is composited the same enlarged-cursor way universalaccessd handles,
//    even if the user never touched the Accessibility "Pointer size" UI
//    toggle. Confirmed 2026-07-11: a 70x custom per-cursor Arrow scale
//    (mouseDriverCursorSize left at the 1.0 default, so trigger 1 didn't
//    fire) still blinked/vanished mid-session apply, solid again only
//    after a full restart — same signature as trigger 1, different gate.
// See project_macos27_large_cursor_blink memory for the confirmed-vs-guessed history here.
#define kMCLargeScaleThreshold 4.0f
void reengageAccessibilityCursorCompositor(void) {
    CFPropertyListRef sizeRef = CFPreferencesCopyValue(
        CFSTR("mouseDriverCursorSize"),
        CFSTR("com.apple.universalaccess"),
        kCFPreferencesCurrentUser,
        kCFPreferencesCurrentHost
    );
    float cursorSize = sizeRef ? [(__bridge_transfer NSNumber *)sizeRef floatValue] : 1.0f;
    BOOL enlargementActive = cursorSize > 1.01f;

    float maxAppliedScale = 1.0f;
    if (customScaleMode()) {
        NSDictionary *perCursorScales = MCDefault(MCPreferencesPerCursorScalesKey);
        for (NSNumber *scale in perCursorScales.allValues) {
            maxAppliedScale = MAX(maxAppliedScale, scale.floatValue);
        }
    } else {
        maxAppliedScale = [MCDefault(@"MCGlobalCursorScale") floatValue];
        if (maxAppliedScale <= 0.0f) maxAppliedScale = 1.0f;
    }
    BOOL largeScaleActive = maxAppliedScale > kMCLargeScaleThreshold;

    if (!enlargementActive && !largeScaleActive) {
        MMLog("reengageAccessibilityCursorCompositor: pointer size normal (%.2f) and max applied scale (%.2f) <= %.1f, skipping",
              cursorSize, maxAppliedScale, kMCLargeScaleThreshold);
        return;
    }
    MMLog("reengageAccessibilityCursorCompositor: engaging (pointer size=%.2f, enlargementActive=%d, maxAppliedScale=%.2f, largeScaleActive=%d)",
          cursorSize, enlargementActive, maxAppliedScale, largeScaleActive);

    @try {
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/usr/bin/killall";
        task.arguments = @[@"universalaccessd"];
        task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
        [task launch];
        [task waitUntilExit];
        NSLog(@"[MousecapeHelper] reengageAccessibilityCursor: restarted universalaccessd (status=%d)",
              task.terminationStatus);
    } @catch (NSException *exception) {
        NSLog(@"[MousecapeHelper][ERROR] reengageAccessibilityCursor exception: %@", exception);
    }
}

// ---------------------------------------------------------------------------
// SURGICAL APPLY (2026-08-26)
//
// The full pipeline (unregister-all -> scale ramp -> re-register 50+ cursors
// -> restart uad) is a REBUILD designed for cape switches.  For a mere scale
// tweak it destroys the stable render state.  Surgical path: when the SAME
// cape is already applied in custom mode, re-register ONLY entries whose
// geometry changed, in place.  No unregister-all, no ramp, no uad restart.
// ---------------------------------------------------------------------------
BOOL applyCapeSurgical(NSDictionary *dictionary) {
    NSDictionary *cursors = dictionary[MCCursorDictionaryCursorsKey];
    NSString *name = dictionary[MCCursorDictionaryCapeNameKey];
    MMLog("========================================");
    MMLog("=== SURGICAL APPLY: %s ===", name.UTF8String);
    MMLog("========================================");

    if (!customScaleMode()) {
        MMLog("Surgical: global scale mode — falling back to full apply");
        return NO;
    }
    NSString *applied = [MCDefault(MCPreferencesAppliedCursorKey) copy];
    NSString *ident = dictionary[MCCursorDictionaryIdentifierKey];
    if (!applied || !ident || ![applied isEqualToString:ident]) {
        MMLog("Surgical: different/none cape applied — falling back to full apply");
        return NO;
    }

    CGSConnectionID cid = CGSMainConnectionID();
    float baseScale = 1.0f;
    NSUInteger changed = 0, unchanged = 0, failed = 0;

    for (NSString *key in cursors) {
        NSDictionary *cape = cursors[key];
        NSArray *reps = cape[MCCursorDictionaryRepresentationsKey];
        if (!reps || reps.count == 0) continue;

        NSDictionary *scales = MCDefault(MCPreferencesPerCursorScalesKey);
        float desired = [scales[key] floatValue];
        if (desired <= 0.0f) desired = 1.0f;
        CGSize desiredSize = CGSizeMake([cape[MCCursorDictionaryPointsWideKey] floatValue] * desired,
                                        [cape[MCCursorDictionaryPointsHighKey] floatValue] * desired);

        CGSize curSize = CGSizeZero; CGPoint curHot = CGPointZero;
        NSUInteger frames = 0; CGFloat dur = 0; CFArrayRef arr = NULL;
        CGError e = CGSCopyRegisteredCursorImages(cid, (char *)key.UTF8String,
                                                  &curSize, &curHot, &frames, &dur, &arr);
        if (arr) CFRelease(arr);

        if (e == kCGErrorSuccess &&
            fabsf(curSize.width - desiredSize.width) < 0.5f &&
            fabsf(curSize.height - desiredSize.height) < 0.5f) {
            unchanged++;
            continue;
        }

        MMLog("Surgical: %s %.0fx%.0f -> %.0fx%.0f — re-registering",
              key.UTF8String, curSize.width, curSize.height,
              desiredSize.width, desiredSize.height);
        BOOL ok = applyCapeForIdentifier(cape, key, NO, YES, NO, NO, baseScale);
        if (ok) { changed++; } else { failed++; }
    }

    // ---- Phase 2: per-cursor scales for cursors WITHOUT cape images ----
    // The cape file only carries entries with custom images (typically 5).
    // The other cursors (com.apple.cursor.N etc.) get their size from
    // MCPerCursorScales applied to the SYSTEM default image — the full
    // pipeline handles them in its Step 5 loop.  Surgical must handle them
    // too, or their scale changes silently stop taking effect (bug found
    // 2026-08-26: only Arrow/IBeam-family sizes worked after surgical).
    {
        NSDictionary *scales = MCDefault(MCPreferencesPerCursorScalesKey);
        NSSet *capeKeys = [NSSet setWithArray:cursors.allKeys];
        // Synonym-aware skip (2026-08-26): if a scale key belongs to a family
        // whose PRIMARY entry is already handled by the cape loop above
        // (e.g. prefs has "Arrow"=65 while the cape only carries ArrowS=40),
        // honouring both would register conflicting sizes for names that are
        // aliases of each other — they must share one image and one size.
        // The cape's own entry wins; synonyms of that key are protected by it.
        NSMutableSet *synonymOwned = [NSMutableSet set];
        for (NSString *ck in capeKeys) {
            if ([ck hasPrefix:@"com.apple.coregraphics.Arrow"]) {
                [synonymOwned addObjectsFromArray:MCArrowSynonyms()];
            } else if ([ck hasPrefix:@"com.apple.coregraphics.IBeam"]) {
                [synonymOwned addObjectsFromArray:MCIBeamSynonyms()];
            }
        }
        for (NSString *name in scales) {
            if ([capeKeys containsObject:name]) continue;   // handled above
            if ([synonymOwned containsObject:name]) {
                MMLog("Surgical(sys): skip %@ — synonym of a cape-owned cursor", name.UTF8String);
                continue;
            }

            // Desired: system native size x scale (same as Step 5 semantics:
            // applyCapeForIdentifier with isSystemDefault=YES in custom mode
            // registers at nativeSize x desiredScale).
            float desired = [scales[name] floatValue];
            if (desired <= 0.0f) desired = 1.0f;

            // Fetch HIGH-RESOLUTION system data.  Plain reads return the
            // CURRENT registration (possibly a poisoned 8x8 bitmap from an
            // earlier damaged session) — the clean built-in art only comes
            // back at high resolution when the cursor scale is boosted during
            // the read, exactly like the full pipeline's extraction step.
            // Boost → read → restore takes milliseconds; the transient scale
            // blip is the same one the full apply has always produced.
            float scaleBefore = cursorScale();
            CGSSetCursorScale(CGSMainConnectionID(), 8.0f);
            NSDictionary *sysData = systemCapeWithIdentifier(name);
            CGSSetCursorScale(CGSMainConnectionID(), scaleBefore);
            if (!sysData) continue;

            CGSize curSize = CGSizeZero; CGPoint curHot = CGPointZero;
            NSUInteger frames = 0; CGFloat dur = 0; CFArrayRef arr = NULL;
            CGError e = CGSCopyRegisteredCursorImages(cid, (char *)name.UTF8String,
                                                      &curSize, &curHot, &frames, &dur, &arr);
            // Damaged-registration detection: a registered cursor whose payload
            // is tiny (e.g. 8x8 bitmaps left over from a poisoned session)
            // renders as visible pixelation at any scale.  Any real cursor art
            // is far larger; < 64px on the longest side = garbage → replace.
            BOOL payloadDamaged = NO;
            if (e == kCGErrorSuccess && arr && CFArrayGetCount(arr) > 0) {
                CGImageRef curImg = (CGImageRef)CFArrayGetValueAtIndex(arr, 0);
                if (curImg) {
                    size_t w = CGImageGetWidth(curImg), h = CGImageGetHeight(curImg);
                    if (w < 64 && h < 64) payloadDamaged = YES;
                }
            }
            if (arr) CFRelease(arr);

            float nativeW = [sysData[MCCursorDictionaryPointsWideKey] floatValue];
            float nativeH = [sysData[MCCursorDictionaryPointsHighKey] floatValue];
            CGSize wantSize = CGSizeMake(nativeW * desired, nativeH * desired);

            // NOT registered (err=1007) means it needs registration — never skip!
            BOOL notRegistered = (e == 1007 || e != kCGErrorSuccess);
            BOOL sizeMismatch = (e == kCGErrorSuccess) &&
                (fabsf(curSize.width - wantSize.width) >= 0.5f ||
                 fabsf(curSize.height - wantSize.height) >= 0.5f);

            if (!notRegistered && !sizeMismatch && !payloadDamaged) {
                continue;   // already correct
            }

            MMLog("Surgical(sys): %s %s (%.0fx%.0f) -> %.0fx%.0f — re-registering",
                  name.UTF8String,
                  payloadDamaged ? "DAMAGED-PAYLOAD" : (notRegistered ? "UNREGISTERED" : "resize"),
                  curSize.width, curSize.height,
                  wantSize.width, wantSize.height);
            BOOL ok = applyCapeForIdentifier(sysData, name, NO, YES, YES, YES, baseScale);
            if (ok) { changed++; } else { failed++; }
        }
    }

    MMLog("Surgical result: %lu changed, %lu unchanged, %lu failed",
          (unsigned long)changed, (unsigned long)unchanged, (unsigned long)failed);
    if (changed == 0 && failed == 0) {
        MMLog("Surgical: nothing to do — stable state untouched");
        return YES;
    }
    if (failed > 0 && changed == 0) {
        MMLog("Surgical: all re-registrations failed — falling back to full apply");
        return NO;
    }
    MCSetDefault(dictionary[MCCursorDictionaryIdentifierKey], MCPreferencesAppliedCursorKey);
    MMLog(BOLD GREEN "Surgical apply complete — no unregister/ramp/uad-kill performed" RESET);
    return YES;
}

BOOL applyCapeWithoutReset(NSDictionary *dictionary) {
    // Re-entry guard: prevent concurrent apply calls (e.g. multiple display
    // reconfiguration events in quick succession on wake).
    if (g_refreshingSystemDefaults) {
        MMLog(YELLOW "applyCapeWithoutReset: another apply/refresh is in progress, skipping" RESET);
        return NO;
    }
    g_refreshingSystemDefaults = YES;

    @try {
    @autoreleasepool {
        NSDictionary *cursors = dictionary[MCCursorDictionaryCursorsKey];
        NSString *name = dictionary[MCCursorDictionaryCapeNameKey];

        MMLog("========================================");
        MMLog("=== APPLYING CAPE (main app) ===");
        MMLog("========================================");
        MMLog("Cape name: %s", name.UTF8String);
        MMLog("Cape identifier: %s", [dictionary[MCCursorDictionaryIdentifierKey] UTF8String]);
        MMLog("Total cursors: %lu", (unsigned long)cursors.count);

        // Derive the target scale from preferences, NOT from cursorScale().
        // cursorScale() reads the WindowServer's current scale, which can be
        // corrupted by a previous race condition (e.g. stuck at 64.0 from a
        // failed refreshSystemDefaultCursors).  Reading from preferences ensures
        // we always restore the user's intended scale, breaking the
        // self-reinforcing loop where cursorScale() returns a wrong value,
        // we save it, and then can't restore because setCursorScale() rejects >16
        // while CGSSetCursorScale() (called directly for restore) accepts anything.
        float savedScale;
        {
            BOOL mode = customScaleMode();
            if (mode) {
                savedScale = [MCDefault(@"MCCustomMaxScale") floatValue];
                if (savedScale <= 0.0f) savedScale = 1.0f;
            } else {
                savedScale = [MCDefault(@"MCGlobalCursorScale") floatValue];
                if (savedScale < 0.5f || savedScale > 96.0f) savedScale = 1.0f;
            }
        }
        MMLog("Target scale (from prefs): %.2f (WindowServer reports: %.2f)",
              savedScale, cursorScale());

        // Step 0: Create cursor registration backups before clearing.
        // backupAllCursors() saves current cursor data as registrations under
        // backup names (com.alexzielenski.mousecape.*). Only runs once —
        // subsequent calls skip if backups already exist. This must happen
        // BEFORE CoreCursorUnregisterAll() so the current state is captured.
        MMLog("--- Backing up cursors ---");
        backupAllCursors();

        // Step 1: Unregister ALL cursors to force the WindowServer to fall
        // back to its built-in native defaults (vector/high-res).  This is
        // the only way to get clean system cursor images on a running system.
        MMLog("--- CoreCursorUnregisterAll (clear cache) ---");
        CGError err = CoreCursorUnregisterAll(CGSMainConnectionID());
        MMLog("CoreCursorUnregisterAll result: %d", (int)err);

        // Reset scale to 1.0 to trigger additional cache clearing in WindowServer
        CGSSetCursorScale(CGSMainConnectionID(), 1.0f);

        // Brief pause for WindowServer to settle
        usleep(100000); // 100 ms

        // Step 2: Extract ALL system default cursors at a moderate scale.
        // On a running system, extreme 64x extraction can degrade quality due to
        // WindowServer's internal bitmap caching.  A moderate 8x extraction
        // produces cleaner images, and the Lanczos upscaler in
        // applyCapeForIdentifier handles the rest.
        float extractScale = 8.0f;
        MMLog("--- Extracting system defaults at %.1fx ---", extractScale);
        CGSSetCursorScale(CGSMainConnectionID(), extractScale);
        CGSHideCursor(CGSMainConnectionID());

        NSMutableDictionary *systemDefaults = [NSMutableDictionary dictionary];
        MCEnumerateAllCursorIdentifiers(^(NSString *name) {
            NSDictionary *sysData = systemCapeWithIdentifier(name);
            if (sysData) {
                systemDefaults[name] = sysData;
            }
        });

        // Restore scale immediately after extraction
        CGSSetCursorScale(CGSMainConnectionID(), savedScale);
        CGSShowCursor(CGSMainConnectionID());
        MMLog("Extracted %lu system default cursors, scale restored to %.2f",
              (unsigned long)systemDefaults.count, savedScale);

        // Step 3: Set up scale mode
        BOOL isCustomMode = customScaleMode();

        // baseScaleForRegistration: the CGSSetCursorScale value set BEFORE cursor registration.
        // Used by applyCapeForIdentifier to compute per-cursor ratio without reading WindowServer.
        float baseScaleForRegistration = isCustomMode ? 1.0f : savedScale;

        if (isCustomMode) {
            float baseScale = 1.0f;
            MMLog("SCALE DEBUG: custom mode, baseScale=%.2f", baseScale);
            setCursorScale(baseScale);
            MCSetDefault(@(baseScale), @"MCCustomMaxScale");
        } else {
            MMLog("SCALE DEBUG: global mode, scale=%.2f", savedScale);
            if (savedScale >= 0.5f && savedScale <= 96.0f) {
                setCursorScale(savedScale);
            } else {
                setCursorScale(defaultCursorScale());
            }
        }

        // Step 4: Apply cape cursors
        NSUInteger successCount = 0;
        NSUInteger skippedCount = 0;
        NSUInteger failedCount = 0;
        NSMutableSet *registeredKeys = [NSMutableSet set];

        // Reset the synonym-protection set for this pass.  From here until
        // Step 5 completes, MCRegisterImagesForCursorName records EVERY name
        // cape registrations write (cursor itself + all synonym families:
        // Arrow→ArrowCtx/…, IBeam→IBeamXOR/…, resize sets, …).  Step 5 then
        // protects all of them — no hand-maintained per-family lists.
        g_capeRegisteredNames = [NSMutableSet set];

        for (NSString *key in cursors) {
            NSDictionary *cape = cursors[key];
            NSArray *reps = cape[MCCursorDictionaryRepresentationsKey];
            if (!reps || reps.count == 0) {
                skippedCount++;
                continue;
            }
            BOOL success = applyCapeForIdentifier(cape, key, NO, isCustomMode, NO, NO, baseScaleForRegistration);
            if (success) {
                successCount++;
                [registeredKeys addObject:key];
            } else {
                failedCount++;
            }
        }
        MMLog("Cape cursors: %lu applied, %lu skipped, %lu failed (wrote %lu names incl. synonyms)",
              (unsigned long)successCount, (unsigned long)skippedCount, (unsigned long)failedCount,
              (unsigned long)g_capeRegisteredNames.count);

        // Step 5: Register system defaults NOT covered by the cape.
        // Protection = anything the cape registrations actually WROTE this
        // pass (g_capeRegisteredNames) plus the cape's own keys.  A name in
        // either set is NOT re-registered as a system default — otherwise the
        // system loop overwrites custom cursors (incl. synonyms like ArrowCtx
        // that macOS renders the pointer through) with tiny system bitmaps.
        [registeredKeys unionSet:g_capeRegisteredNames];
        // EXPERIMENT (2026-08-26): MC_SKIP_SYSDEFAULTS=1 skips re-registering
        // system defaults — isolates whether this re-registration pass is what
        // destabilizes the cursor surface (buffer flapping 16MB<->67MB).
        BOOL skipSysDefaults = getenv("MC_SKIP_SYSDEFAULTS") != NULL;
        __block NSUInteger systemDefaultCount = 0;
        [systemDefaults enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSDictionary *sysData, BOOL *stop) {
            if (skipSysDefaults) return;
            if ([registeredKeys containsObject:name]) {
                return; // Already registered as cape cursor
            }
            BOOL ok = applyCapeForIdentifier(sysData, name, NO, isCustomMode, YES, YES, baseScaleForRegistration);
            if (ok) systemDefaultCount++;
        }];
        MMLog("Re-registered %lu system default cursors (skipped %lu cape cursors)",
              (unsigned long)systemDefaultCount, (unsigned long)registeredKeys.count);

        if (successCount == 0) {
            MMLog(BOLD RED "No cursors were successfully applied!" RESET);
            return NO;
        }

        MCSetDefault(dictionary[MCCursorDictionaryIdentifierKey], MCPreferencesAppliedCursorKey);

        // Verify scale matches savedScale after full registration.
        // On wake, CGSSetCursorScale may not stick immediately.
        float finalScale = cursorScale();
        if (fabsf(finalScale - savedScale) >= 0.01f) {
            MMLog(YELLOW "Scale mismatch after apply: actual=%.2f, target=%.2f — forcing restore" RESET,
                  finalScale, savedScale);
            setCursorScale(savedScale);
        }

        MMLog(BOLD GREEN "Applied %s (success: %lu, system defaults: %lu)" RESET,
              name.UTF8String, (unsigned long)successCount, (unsigned long)systemDefaultCount);

        // This is the single choke point for EVERY apply — manual Apply clicks,
        // session changes, wake, and display-reconfig recovery alike — which is
        // exactly why the compositor re-engage belongs here: the flicker/vanish
        // bug it fixes is caused by re-registration itself, not by any one
        // trigger source. See reengageAccessibilityCursorCompositor() above.
        reengageAccessibilityCursorCompositor();

        return YES;
    }
    } @finally {
        g_refreshingSystemDefaults = NO;
        // Release this pass's synonym-protection set (see g_capeRegisteredNames).
        g_capeRegisteredNames = nil;
    }
}

NSDictionary *applyCapeWithResult(NSDictionary *dictionary) {
    @autoreleasepool {
        NSDictionary *cursors = dictionary[MCCursorDictionaryCursorsKey];
        NSString *name = dictionary[MCCursorDictionaryCapeNameKey];
        NSNumber *version = dictionary[MCCursorDictionaryCapeVersionKey];

        MMLog("========================================");
        MMLog("=== APPLYING CAPE WITH RESULT ===");
        MMLog("========================================");
        MMLog("Cape name: %s", name.UTF8String);
        MMLog("Cape identifier: %s", [dictionary[MCCursorDictionaryIdentifierKey] UTF8String]);
        MMLog("Total cursors: %lu", (unsigned long)cursors.count);

        // Derive the target scale from preferences, NOT from cursorScale().
        // cursorScale() reads the WindowServer which can return corrupted values.
        float savedScale;
        {
            BOOL mode = customScaleMode();
            if (mode) {
                savedScale = [MCDefault(@"MCCustomMaxScale") floatValue];
                if (savedScale <= 0.0f) savedScale = 1.0f;
            } else {
                savedScale = [MCDefault(@"MCGlobalCursorScale") floatValue];
                if (savedScale < 0.5f || savedScale > 96.0f) savedScale = 1.0f;
            }
        }
        MMLog("Target scale (from prefs): %.2f (WindowServer reports: %.2f)",
              savedScale, cursorScale());

        MMLog("--- Calling resetAllCursors ---");
        resetAllCursors();
        MMLog("--- Calling backupAllCursors ---");
        backupAllCursors();

        // Read scale mode from direct C variable (not CFPreferences)
        BOOL isCustomMode = customScaleMode();

        // baseScaleForRegistration: the CGSSetCursorScale value set BEFORE cursor registration.
        // Used by applyCapeForIdentifier to compute per-cursor ratio without reading WindowServer.
        float baseScaleForRegistration = isCustomMode ? 1.0f : savedScale;

        if (isCustomMode) {
            float minScale = 96.0f;
            float maxScale = 1.0f;
            NSDictionary *perCursorScales = MCDefault(MCPreferencesPerCursorScalesKey);
            if (perCursorScales) {
                for (NSNumber *val in perCursorScales.allValues) {
                    float s = val.floatValue;
                    if (s > 0.0f && s < minScale) minScale = s;
                    if (s > maxScale) maxScale = s;
                }
            }
            float baseScale = 1.0f;
            MMLog("SCALE DEBUG: custom mode, maxScale=%.2f, baseScale=%.2f (direct registration)", maxScale, baseScale);
            setCursorScale(baseScale);
            MCSetDefault(@(baseScale), @"MCCustomMaxScale");
        } else {
            MMLog("SCALE DEBUG: global mode, restoring to %.2f", savedScale);
            if (savedScale >= 0.5f && savedScale <= 96.0f) {
                setCursorScale(savedScale);
            } else {
                setCursorScale(defaultCursorScale());
            }
        }

        MMLog("--- Applying cursors ---");

        NSUInteger successCount = 0;
        NSUInteger skippedCount = 0;
        NSUInteger failedCount = 0;
        NSMutableArray *failedIdentifiers = [NSMutableArray array];
        NSMutableArray *skippedIdentifiers = [NSMutableArray array];

        for (NSString *key in cursors) {
            NSDictionary *cape = cursors[key];
            MMLog("Hooking for %s", key.UTF8String);

            // Check if cursor has valid image data before attempting to apply
            NSArray *reps = cape[MCCursorDictionaryRepresentationsKey];
            if (!reps || reps.count == 0) {
                // System default cursors with no cape images are left alone
                // after resetAllCursors() — they are re-registered below with
                // per-cursor scaling via the MCEnumerateAllCursorIdentifiers loop.
                MMLog(YELLOW "  Skipping cursor %s - no image data (system default, re-registered below)" RESET, key.UTF8String);
                skippedCount++;
                [skippedIdentifiers addObject:key];
                continue;
            }

            BOOL success = applyCapeForIdentifier(cape, key, NO, isCustomMode, NO, NO, baseScaleForRegistration);
            if (!success) {
                MMLog(YELLOW "  Failed to apply cursor %s" RESET, key.UTF8String);
                failedCount++;
                [failedIdentifiers addObject:key];
            } else {
                successCount++;
            }
        }

        // Re-register system default cursors not covered by the cape.
        // In custom mode: per-cursor scale is applied via the ratio in applyCapeForIdentifier.
        // In global mode: CGSSetCursorScale handles uniform scaling, but we still need to
        // register the defaults explicitly — otherwise the WindowServer caches stale images
        // and CGSSetCursorScale alone causes pixelation for unregistered cursor types.
        {
            MMLog("--- Re-registering system defaults (%s mode) ---", isCustomMode ? "custom" : "global");
            NSMutableSet *registeredKeys = [NSMutableSet set];
            for (NSString *key in cursors) {
                NSArray *reps = cursors[key][MCCursorDictionaryRepresentationsKey];
                if (reps && reps.count > 0) {
                    [registeredKeys addObject:key];
                }
            }

            // Temporarily boost cursor scale for high-res extraction
            float extractScale = 64.0f;
            MMLog("  Boosting cursor scale to %.1f for high-res extraction", extractScale);
            CGSSetCursorScale(CGSMainConnectionID(), extractScale);
            CGSHideCursor(CGSMainConnectionID());

            __block NSUInteger systemDefaultCount = 0;
            __block NSUInteger skippedByRegisteredKeys = 0;
            MCEnumerateAllCursorIdentifiers(^(NSString *name) {
                if ([registeredKeys containsObject:name]) {
                    skippedByRegisteredKeys++;
                    return; // Already registered as cape cursor
                }
                NSDictionary *systemData = systemCapeWithIdentifier(name);
                if (!systemData) {
                    return; // No system cursor data available
                }
                BOOL ok = applyCapeForIdentifier(systemData, name, NO, isCustomMode, YES, YES, baseScaleForRegistration);
                if (ok) {
                    systemDefaultCount++;
                } else {
                    MMLog(YELLOW "  Failed to re-register system default %s" RESET, name.UTF8String);
                }
            });

            // Restore the original scale (savedScale from before resetAllCursors)
            MMLog("  Restoring cursor scale to %.1f after extraction", savedScale);
            CGSSetCursorScale(CGSMainConnectionID(), savedScale);
            CGSShowCursor(CGSMainConnectionID());

            MMLog("  Re-registered %lu system default cursors (skipped %lu by registeredKeys)", (unsigned long)systemDefaultCount, (unsigned long)skippedByRegisteredKeys);
        }

        MMLog("--- Application Summary ---");
        MMLog("  Total cursors: %lu", (unsigned long)cursors.count);
        MMLog("  Successfully applied: %lu", (unsigned long)successCount);
        MMLog("  Skipped (no images): %lu", (unsigned long)skippedCount);
        MMLog("  Failed: %lu", (unsigned long)failedCount);

        // Only save applied cursor preference if at least one cursor succeeded
        if (successCount > 0) {
            MCSetDefault(dictionary[MCCursorDictionaryIdentifierKey], MCPreferencesAppliedCursorKey);
        }

        // Return detailed result dictionary
        return @{
            @"success": @(successCount > 0),
            @"successCount": @(successCount),
            @"skippedCount": @(skippedCount),
            @"failedCount": @(failedCount),
            @"failedIdentifiers": [failedIdentifiers copy],
            @"skippedIdentifiers": [skippedIdentifiers copy]
        };
    }
}

BOOL applyCapeAtPath(NSString *path) {
    MMLog("========================================");
    MMLog("=== applyCapeAtPath ===");
    MMLog("========================================");
    MMLog("Input path: %s", path ? path.UTF8String : "(null)");

    // Validate path
    if (!path || path.length == 0) {
        MMLog(BOLD RED "Invalid path" RESET);
        return NO;
    }

    // Resolve symlinks and check for path traversal
    NSString *realPath = [path stringByResolvingSymlinksInPath];
    NSString *standardPath = [realPath stringByStandardizingPath];

    MMLog("Real path: %s", realPath.UTF8String);
    MMLog("Standard path: %s", standardPath.UTF8String);
    MMLog("File exists: %s", [[NSFileManager defaultManager] fileExistsAtPath:standardPath] ? "YES" : "NO");
    MMLog("File readable: %s", [[NSFileManager defaultManager] isReadableFileAtPath:standardPath] ? "YES" : "NO");

    // Validate file extension
    if (![[standardPath pathExtension] isEqualToString:@"cape"]) {
        MMLog(BOLD RED "Invalid file extension - must be .cape" RESET);
        return NO;
    }

    // Check file exists and is readable
    if (![[NSFileManager defaultManager] isReadableFileAtPath:standardPath]) {
        MMLog(BOLD RED "File not readable at path" RESET);
        return NO;
    }

    MMLog("Loading cape file...");

    // Check if the user has customized pointer colors in Accessibility settings.
    // When cursorIsCustomized=1, macOS composites its own color tint over all
    // cursors, overriding CGSRegisterCursorWithImages().  Skip apply and log
    // so the Helper doesn't silently fail on every session change / wake event.
    CFPropertyListRef customizedRef = CFPreferencesCopyValue(
        CFSTR("cursorIsCustomized"),
        CFSTR("com.apple.universalaccess"),
        kCFPreferencesCurrentUser,
        kCFPreferencesCurrentHost
    );
    BOOL isCustomized = [(__bridge_transfer id)customizedRef boolValue];
    if (isCustomized) {
        MMLog(BOLD YELLOW "Skipping apply: system pointer colors are customized" RESET);
        MMLog("User needs to reset pointer color in System Settings > Accessibility > Display");
        return NO;
    }

    NSDictionary *cape = [NSDictionary dictionaryWithContentsOfFile:standardPath];
    if (cape) {
        // Try the surgical path first (in-place update of changed cursors
        // only — no unregister-all/ramp/compositor-kill).  Falls through to
        // the full rebuild when preconditions aren't met.
        if (applyCapeSurgical(cape)) {
            return YES;
        }
        MMLog("Cape file loaded successfully, applying...");
        // Use applyCapeWithoutReset() instead of applyCape() for both the
        // Helper and CLI.  applyCapeWithoutReset() uses a gentler 8x extraction
        // boost (vs 64x) and avoids resetAllCursors() which can cause visible
        // cursor scale spikes on running systems, especially during early boot
        // when the WindowServer hasn't fully settled.
        return applyCapeWithoutReset(cape);
    }
    MMLog(BOLD RED "Could not parse valid cape file" RESET);
    return NO;
}

void refreshSystemDefaultCursors(void) {
    // Re-entry guard: if a refresh is already in progress (e.g. a display
    // reconfiguration fired while we're mid-extraction at 64x), skip this
    // call entirely.  The in-progress refresh will restore the correct scale.
    if (g_refreshingSystemDefaults) {
        MMLog(YELLOW "refreshSystemDefaultCursors: already in progress, skipping re-entry" RESET);
        return;
    }
    g_refreshingSystemDefaults = YES;

    @try {
        @autoreleasepool {
            MMLog("========================================");
            MMLog("=== REFRESHING SYSTEM DEFAULT CURSORS ===");
            MMLog("========================================");

            BOOL isCustomMode = customScaleMode();

            // Derive the target scale from preferences, NOT from cursorScale().
            // cursorScale() may return 64.0 if another refresh is mid-extraction,
            // causing us to "restore" to the extraction boost instead of the real scale.
            float targetScale;
            if (isCustomMode) {
                targetScale = [MCDefault(@"MCCustomMaxScale") floatValue];
                if (targetScale <= 0.0f) targetScale = 1.0f;
            } else {
                targetScale = [MCDefault(@"MCGlobalCursorScale") floatValue];
                if (targetScale < 0.5f || targetScale > 96.0f) targetScale = 1.0f;
            }

            MMLog("Target scale (from prefs): %.2f, mode: %s", targetScale, isCustomMode ? "custom" : "global");

            // Boost to 64x for high-res extraction.
            // At scale=1.0, system cursors come back as tiny 64×64 bitmaps.
            // At scale=64.0, the system renders them at 64× native → ~2048px images.
            float extractScale = 64.0f;
            MMLog("Boosting cursor scale to %.1f for high-res extraction", extractScale);
            CGSSetCursorScale(CGSMainConnectionID(), extractScale);
            CGSHideCursor(CGSMainConnectionID());

            __block NSUInteger successCount = 0;
            __block NSUInteger failedCount = 0;

            MCEnumerateAllCursorIdentifiers(^(NSString *name) {
                NSDictionary *systemData = systemCapeWithIdentifier(name);
                if (!systemData) {
                    return;
                }
                BOOL ok = applyCapeForIdentifier(systemData, name, NO, isCustomMode, YES, YES, targetScale);
                if (ok) {
                    successCount++;
                } else {
                    failedCount++;
                    MMLog(YELLOW "  Failed to re-register system default %s" RESET, name.UTF8String);
                }
            });

            // Restore the target scale (from preferences, not from cursorScale())
            MMLog("Restoring cursor scale to %.2f after extraction", targetScale);
            CGSSetCursorScale(CGSMainConnectionID(), targetScale);
            CGSShowCursor(CGSMainConnectionID());

            MMLog("Re-registered %lu system default cursors (failed: %lu)",
                  (unsigned long)successCount, (unsigned long)failedCount);

            MMLog("=== SYSTEM DEFAULT CURSOR REFRESH COMPLETE ===");
        }
    }
    @finally {
        g_refreshingSystemDefaults = NO;
    }
}
