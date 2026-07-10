#import "outerShadow.h"
#import "MCDefs.h"
#import <Accelerate/Accelerate.h>
#import <math.h>

// NOTE: deliberately the SAME simple full-resolution algorithm as
// MCApplyOuterGlow, with no downsample/upsample optimization. Three attempts
// at speeding this up via a downsampled blur each produced a different
// visible defect (blocky/serrated edges, a skewed/disconnected result, and
// grainy noise) on very large or extreme-aspect-ratio cursor images.
// Correctness matters more than speed for a cosmetic effect — this is slower
// on huge upscaled cursors, but is guaranteed to render the same way
// MCApplyOuterGlow already does, since it's the same code.
CGImageRef MCApplyOuterShadow(CGImageRef image, float radius, float intensity) {
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

        MMLog("MCApplyOuterShadow: processing %zux%zu image, radius=%d, intensity=%.2f",
              width, height, blurRadius, intensity);

        // --- Step 2: Create pixel buffer (8-bpc RGBA, non-premultiplied) ---
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
        // Pixel format: ARGB (premultiplied first, big endian)
        // Byte order: A, R, G, B per pixel
        float *alpha = (float *)malloc(totalPixels * sizeof(float));
        if (!alpha) {
            MMLog("MCApplyOuterShadow: failed to allocate alpha buffer");
            CGContextRelease(context);
            return NULL;
        }

        for (size_t i = 0; i < totalPixels; i++) {
            alpha[i] = pixels[i * 4] / 255.0f; // Alpha is at byte offset 0 (premultiplied first)
        }

        // --- Step 4: Box blur the alpha using Accelerate vImage (3-pass separable) ---
        // Blur into a ZERO-PADDED canvas, not the raw width x height buffer.
        // Root cause of the "square shadow at the tip" bug: kvImageEdgeExtend
        // replicates the buffer's OUTERMOST pixel outward past its border.
        // When the cursor's shape touches the image edge directly (e.g. this
        // arrow's hotspot is at (0,0), so its tip sits flush against pixel
        // (0,0) with no margin), that edge pixel has nonzero alpha, and
        // edge-extend treats it as if the shape continued forever past the
        // canvas boundary — producing an axis-aligned rectangular patch of
        // "shadow" hugging that corner, instead of the shape's real (diagonal,
        // tapering) silhouette. Padding with real zero-alpha margin at least
        // as wide as the blur's total reach means edge-extend only ever
        // replicates zeros there, so no artificial shape gets invented.
        int pad = blurRadius * 3 + 2; // safety margin for the 3-pass spread
        size_t paddedWidth = width + (size_t)pad * 2;
        size_t paddedHeight = height + (size_t)pad * 2;
        size_t paddedPixels = paddedWidth * paddedHeight;

        float *paddedAlpha = (float *)calloc(paddedPixels, sizeof(float));
        float *paddedTemp = (float *)malloc(paddedPixels * sizeof(float));
        float *paddedBlurred = (float *)malloc(paddedPixels * sizeof(float));

        if (!paddedAlpha || !paddedTemp || !paddedBlurred) {
            MMLog("%s: failed to allocate padded blur buffers", __func__);
            free(alpha);
            if (paddedAlpha) free(paddedAlpha);
            if (paddedTemp) free(paddedTemp);
            if (paddedBlurred) free(paddedBlurred);
            CGContextRelease(context);
            return NULL;
        }

        // Copy the real alpha into the padded canvas's interior; the border
        // stays 0 (from calloc).
        for (size_t y = 0; y < height; y++) {
            memcpy(&paddedAlpha[(y + (size_t)pad) * paddedWidth + (size_t)pad],
                   &alpha[y * width],
                   width * sizeof(float));
        }

        // Build a true Gaussian kernel instead of a uniform box kernel. A
        // uniform box blur has a flat, hard-edged impulse response — its
        // output has visible "steps" at the 8-bit alpha quantization
        // boundaries, which read as rough/speckled noise along the shadow's
        // edge (confirmed: the same speckle appears identically with the
        // untouched MCApplyOuterGlow, which used the same box kernel — this
        // is a algorithmic smoothness issue, not a defect specific to this
        // file). A Gaussian's smooth falloff removes those steps. Since a 2D
        // Gaussian is separable, exactly ONE horizontal + ONE vertical pass
        // is mathematically exact — no third pass needed (unlike the old
        // 3-pass box-blur approximation).
        int kSize = blurRadius * 2 + 1;
        float sigma = blurRadius / 2.5f;
        if (sigma < 0.5f) sigma = 0.5f;

        float *kernel = (float *)malloc(kSize * sizeof(float));
        if (!kernel) {
            MMLog("%s: failed to allocate kernel", __func__);
            free(alpha);
            free(paddedAlpha);
            free(paddedTemp);
            free(paddedBlurred);
            CGContextRelease(context);
            return NULL;
        }
        {
            float sum = 0.0f;
            for (int i = 0; i < kSize; i++) {
                float x = (float)(i - blurRadius);
                kernel[i] = expf(-(x * x) / (2.0f * sigma * sigma));
                sum += kernel[i];
            }
            for (int i = 0; i < kSize; i++) {
                kernel[i] /= sum; // normalize so weights sum to 1
            }
        }

        // Set up vImage buffers (padded dimensions)
        vImage_Buffer srcBuf = { paddedAlpha, paddedHeight, paddedWidth, paddedWidth * sizeof(float) };
        vImage_Buffer tempBuf = { paddedTemp, paddedHeight, paddedWidth, paddedWidth * sizeof(float) };
        vImage_Buffer blurBuf = { paddedBlurred, paddedHeight, paddedWidth, paddedWidth * sizeof(float) };

        // Pass 1: Horizontal — paddedAlpha → paddedTemp
        vImageConvolve_PlanarF(&srcBuf, &tempBuf, NULL, 0, 0,
                               kernel, 1, kSize, 0.0f,
                               kvImageEdgeExtend);

        // Pass 2: Vertical — paddedTemp → paddedBlurred (final result)
        vImageConvolve_PlanarF(&tempBuf, &blurBuf, NULL, 0, 0,
                               kernel, kSize, 1, 0.0f,
                               kvImageEdgeExtend);

        free(kernel);
        free(paddedAlpha);
        free(paddedTemp);

        // paddedBlurred now holds the final Gaussian-blurred alpha, at padded
        // dimensions. Crop the interior back out to the original width x
        // height for Step 5.
        float *blurredAlpha = (float *)malloc(totalPixels * sizeof(float));
        if (!blurredAlpha) {
            MMLog("%s: failed to allocate cropped blur result", __func__);
            free(alpha);
            free(paddedBlurred);
            CGContextRelease(context);
            return NULL;
        }
        for (size_t y = 0; y < height; y++) {
            memcpy(&blurredAlpha[y * width],
                   &paddedBlurred[(y + (size_t)pad) * paddedWidth + (size_t)pad],
                   width * sizeof(float));
        }
        free(paddedBlurred);

        // --- Step 5: Compute outer shadow and apply ---
        for (size_t i = 0; i < totalPixels; i++) {
            float shadow = blurredAlpha[i] - alpha[i];
            if (shadow < 0.0f) shadow = 0.0f;
            if (shadow > 1.0f) shadow = 1.0f;
            shadow *= intensity;

            // Pixel layout: A(0), R(1), G(2), B(3) — premultiplied first, big endian
            //
            // Use a small epsilon, not a bare > 0.0f check. The upstream
            // Lanczos upscale (apply.m) leaves faint sub-threshold "ringing"
            // in the alpha channel near edges — values like 1-2 out of 255,
            // invisible on their own. A hard > 0.0f check treats every one of
            // those as "fully inside the shape, protect from shadow," which
            // punches a scattered, jagged pattern of un-shadowed pixels right
            // where the smooth halo should be — the "speckled/pixelated"
            // look. Ignoring alpha below this threshold treats it as
            // background, matching what's actually visible.
            const float kAlphaEpsilon = 0.02f; // ~5/255
            if (alpha[i] > kAlphaEpsilon) {
                // Inside the cursor shape: keep original pixel unchanged
                continue;
            }

            // Outside the cursor shape: apply dark shadow if there is any.
            // Unlike MCApplyOuterGlow (white halo, R=G=B=alpha), a shadow is
            // black, so premultiplied R/G/B stay 0 regardless of alpha —
            // only the alpha channel carries the shadow's opacity.
            if (shadow > 0.0f) {
                uint8_t shadowAlpha = (uint8_t)(shadow * 255.0f + 0.5f); // round to nearest
                pixels[i * 4 + 0] = shadowAlpha; // A
                pixels[i * 4 + 1] = 0;            // R (premultiplied black)
                pixels[i * 4 + 2] = 0;            // G (premultiplied black)
                pixels[i * 4 + 3] = 0;            // B (premultiplied black)
            }
        }

        // --- Step 6: Create output CGImage ---
        CGImageRef outputImage = CGBitmapContextCreateImage(context);

        // --- Step 7: Clean up ---
        free(alpha);
        free(blurredAlpha);
        CGContextRelease(context);

        if (!outputImage) {
            MMLog("MCApplyOuterShadow: failed to create output image");
            return NULL;
        }

        return outputImage;
    } // @autoreleasepool
}
