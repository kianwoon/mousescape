#import "outerShadow.h"
#import "MCDefs.h"
#import <Accelerate/Accelerate.h>

CGImageRef MCApplyOuterShadow(CGImageRef image, float radius, float intensity, float offsetX, float offsetY) {
    @autoreleasepool {

        // --- Step 1: Validate input ---
        if (!image) {
            MMLog("MCApplyOuterShadow: image is NULL");
            return NULL;
        }

        size_t width = CGImageGetWidth(image);
        size_t height = CGImageGetHeight(image);

        if (width == 0 || height == 0) {
            MMLog("MCApplyOuterShadow: image has zero dimensions (%zux%zu)", width, height);
            return NULL;
        }

        // Clamp radius to at least 1.0
        int blurRadius = (int)radius;
        if (blurRadius < 1) {
            blurRadius = 1;
        }

        // Clamp intensity
        if (intensity < 0.0f) intensity = 0.0f;
        if (intensity > 1.0f) intensity = 1.0f;

        int dx = (int)(offsetX + (offsetX >= 0 ? 0.5f : -0.5f));
        int dy = (int)(offsetY + (offsetY >= 0 ? 0.5f : -0.5f));

        MMLog("MCApplyOuterShadow: processing %zux%zu image, radius=%d, intensity=%.2f, offset=(%d,%d)",
              width, height, blurRadius, intensity, dx, dy);

        // --- Step 2: Create pixel buffer (8-bpc RGBA, premultiplied first) ---
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        if (!colorSpace) {
            MMLog("MCApplyOuterShadow: failed to create color space");
            return NULL;
        }

        CGContextRef context = CGBitmapContextCreate(
            nil,
            width,
            height,
            8,
            width * 4,
            colorSpace,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big
        );
        CGColorSpaceRelease(colorSpace);

        if (!context) {
            MMLog("MCApplyOuterShadow: failed to create bitmap context");
            return NULL;
        }

        // Draw source image into our normalized context
        CGRect rect = CGRectMake(0, 0, width, height);
        CGContextDrawImage(context, rect, image);

        // Get mutable pixel data
        uint8_t *pixels = (uint8_t *)CGBitmapContextGetData(context);
        if (!pixels) {
            MMLog("MCApplyOuterShadow: failed to get pixel data from context");
            CGContextRelease(context);
            return NULL;
        }

        size_t totalPixels = width * height;

        // --- Step 3: Extract alpha channel ---
        // Pixel format: ARGB (premultiplied first, big endian) → A, R, G, B per pixel
        float *alpha = (float *)malloc(totalPixels * sizeof(float));
        if (!alpha) {
            MMLog("MCApplyOuterShadow: failed to allocate alpha buffer");
            CGContextRelease(context);
            return NULL;
        }

        for (size_t i = 0; i < totalPixels; i++) {
            alpha[i] = pixels[i * 4] / 255.0f; // Alpha at byte offset 0 (premultiplied first)
        }

        // --- Step 4: Box blur the alpha using Accelerate vImage (3-pass separable) ---
        float *temp = (float *)malloc(totalPixels * sizeof(float));
        float *blurred = (float *)malloc(totalPixels * sizeof(float));

        if (!temp || !blurred) {
            MMLog("%s: failed to allocate blur buffers", __func__);
            free(alpha);
            if (temp) free(temp);
            if (blurred) free(blurred);
            CGContextRelease(context);
            return NULL;
        }

        int kSize = blurRadius * 2 + 1;
        float invK = 1.0f / kSize;

        float *kernel = (float *)malloc(kSize * sizeof(float));
        if (!kernel) {
            MMLog("%s: failed to allocate kernel", __func__);
            free(alpha);
            free(temp);
            free(blurred);
            CGContextRelease(context);
            return NULL;
        }
        for (int i = 0; i < kSize; i++) {
            kernel[i] = invK;
        }

        vImage_Buffer srcBuf = { alpha, height, width, width * sizeof(float) };
        vImage_Buffer tempBuf = { temp, height, width, width * sizeof(float) };
        vImage_Buffer blurBuf = { blurred, height, width, width * sizeof(float) };

        // Pass 1: Horizontal — alpha → temp
        vImageConvolve_PlanarF(&srcBuf, &tempBuf, NULL, 0, 0,
                               kernel, 1, kSize, 0.0f, kvImageEdgeExtend);
        // Pass 2: Vertical — temp → blurred
        vImageConvolve_PlanarF(&tempBuf, &blurBuf, NULL, 0, 0,
                               kernel, kSize, 1, 0.0f, kvImageEdgeExtend);
        // Pass 3: Horizontal — blurred → temp
        vImageConvolve_PlanarF(&blurBuf, &tempBuf, NULL, 0, 0,
                               kernel, 1, kSize, 0.0f, kvImageEdgeExtend);

        free(kernel);

        // temp now holds the final 3-pass blurred alpha (the shadow mask, un-offset)
        float *blurredAlpha = temp;

        // --- Step 5: Composite the offset dark shadow ---
        // For each output pixel outside the cursor shape, sample the blurred alpha at
        // an offset position so the shadow falls behind the cursor toward the
        // bottom-right (light from top-left). The bitmap buffer is TOP-DOWN
        // (row 0 = top of image), so to cast the shadow DOWN-right we sample the
        // shape that sits up-and-left of the output pixel: srcRow = y - dy,
        // srcCol = x - dx. (Verified visually 2026-06-23.)
        for (size_t y = 0; y < height; y++) {
            for (size_t x = 0; x < width; x++) {
                size_t i = y * width + x;

                // Inside the cursor shape: keep the original pixel (cursor stays on top).
                if (alpha[i] > 0.0f) {
                    continue;
                }

                long srcX = (long)x - dx;
                long srcY = (long)y - dy;
                if (srcX < 0 || srcX >= (long)width || srcY < 0 || srcY >= (long)height) {
                    continue; // shadow source out of bounds → no shadow here
                }

                float shadow = blurredAlpha[(size_t)srcY * width + (size_t)srcX] * intensity;
                if (shadow <= 0.0f) {
                    continue;
                }
                if (shadow > 1.0f) shadow = 1.0f;

                // Premultiplied black: A = shadow, R = G = B = 0.
                uint8_t a = (uint8_t)(shadow * 255.0f + 0.5f);
                pixels[i * 4 + 0] = a; // A
                pixels[i * 4 + 1] = 0; // R
                pixels[i * 4 + 2] = 0; // G
                pixels[i * 4 + 3] = 0; // B
            }
        }

        // --- Step 6: Create output CGImage ---
        CGImageRef outputImage = CGBitmapContextCreateImage(context);

        // --- Step 7: Clean up ---
        free(alpha);
        free(temp);
        free(blurred);
        CGContextRelease(context);

        if (!outputImage) {
            MMLog("MCApplyOuterShadow: failed to create output image");
            return NULL;
        }

        return outputImage;
    } // @autoreleasepool
}
