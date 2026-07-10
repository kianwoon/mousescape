#import "innerShadow.h"
#import "MCDefs.h"
#import <Accelerate/Accelerate.h>
#import <math.h>

CGImageRef MCApplyInnerShadow(CGImageRef image, float radius, float intensity) {
    @autoreleasepool {

        // --- Step 1: Validate input ---
        if (!image) {
            MMLog("MCApplyInnerShadow: image is NULL");
            return NULL;
        }

        size_t width = CGImageGetWidth(image);
        size_t height = CGImageGetHeight(image);

        if (width == 0 || height == 0) {
            MMLog("MCApplyInnerShadow: image has zero dimensions (%zux%zu)", width, height);
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

        MMLog("MCApplyInnerShadow: processing %zux%zu image, radius=%d, intensity=%.2f",
              width, height, blurRadius, intensity);

        // --- Step 2: Create pixel buffer (8-bpc RGBA, non-premultiplied) ---
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        if (!colorSpace) {
            MMLog("MCApplyInnerShadow: failed to create color space");
            return NULL;
        }

        // kCGImageAlphaPremultipliedLast = RGBA byte order, non-premultiplied rendering
        // We draw into this context which normalizes the pixel format.
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
            MMLog("MCApplyInnerShadow: failed to create bitmap context");
            return NULL;
        }

        // Draw source image into our normalized context
        CGRect rect = CGRectMake(0, 0, width, height);
        CGContextDrawImage(context, rect, image);

        // Get mutable pixel data
        uint8_t *pixels = (uint8_t *)CGBitmapContextGetData(context);
        if (!pixels) {
            MMLog("MCApplyInnerShadow: failed to get pixel data from context");
            CGContextRelease(context);
            return NULL;
        }

        size_t totalPixels = width * height;

        // --- Step 3: Extract alpha channel ---
        // Pixel format: ARGB (premultiplied first, big endian)
        // Byte order: A, R, G, B per pixel
        float *alpha = (float *)malloc(totalPixels * sizeof(float));
        if (!alpha) {
            MMLog("MCApplyInnerShadow: failed to allocate alpha buffer");
            CGContextRelease(context);
            return NULL;
        }

        for (size_t i = 0; i < totalPixels; i++) {
            alpha[i] = pixels[i * 4] / 255.0f; // Alpha is at byte offset 0 (premultiplied first)
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

        // True Gaussian kernel instead of a uniform box kernel — the box
        // kernel's flat impulse response produces visible 8-bit-quantization
        // "steps" (rough/speckled look). A separable Gaussian only needs ONE
        // horizontal + ONE vertical pass (mathematically exact), not the old
        // 3-pass box-blur approximation.
        int kSize = blurRadius * 2 + 1;
        float sigma = blurRadius / 2.5f;
        if (sigma < 0.5f) sigma = 0.5f;

        float *kernel = (float *)malloc(kSize * sizeof(float));
        if (!kernel) {
            MMLog("%s: failed to allocate kernel", __func__);
            free(alpha);
            free(temp);
            free(blurred);
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

        // Set up vImage buffers
        vImage_Buffer srcBuf = { alpha, height, width, width * sizeof(float) };
        vImage_Buffer tempBuf = { temp, height, width, width * sizeof(float) };
        vImage_Buffer blurBuf = { blurred, height, width, width * sizeof(float) };

        // Pass 1: Horizontal — alpha → temp
        vImageConvolve_PlanarF(&srcBuf, &tempBuf, NULL, 0, 0,
                               kernel, 1, kSize, 0.0f,
                               kvImageEdgeExtend);

        // Pass 2: Vertical — temp → blurred (final result)
        vImageConvolve_PlanarF(&tempBuf, &blurBuf, NULL, 0, 0,
                               kernel, kSize, 1, 0.0f,
                               kvImageEdgeExtend);

        free(kernel);
        free(temp);

        // blurred now holds the final Gaussian-blurred alpha
        float *blurredAlpha = blurred;

        // --- Step 5: Compute shadow and darken pixels ---
        for (size_t i = 0; i < totalPixels; i++) {
            float shadow = alpha[i] - blurredAlpha[i];
            if (shadow < 0.0f) shadow = 0.0f;
            if (shadow > 1.0f) shadow = 1.0f;
            shadow *= intensity;

            float darkening = shadow * 255.0f;

            // Pixel layout: A(0), R(1), G(2), B(3) — premultiplied first, big endian
            float r = pixels[i * 4 + 1] - darkening;
            float g = pixels[i * 4 + 2] - darkening;
            float b = pixels[i * 4 + 3] - darkening;

            // Clamp RGB to [0, 255]
            if (r < 0.0f) r = 0.0f;
            if (r > 255.0f) r = 255.0f;
            if (g < 0.0f) g = 0.0f;
            if (g > 255.0f) g = 255.0f;
            if (b < 0.0f) b = 0.0f;
            if (b > 255.0f) b = 255.0f;

            // Write back — alpha unchanged
            pixels[i * 4 + 1] = (uint8_t)(r + 0.5f); // round to nearest
            pixels[i * 4 + 2] = (uint8_t)(g + 0.5f);
            pixels[i * 4 + 3] = (uint8_t)(b + 0.5f);
        }

        // --- Step 6: Create output CGImage ---
        CGImageRef outputImage = CGBitmapContextCreateImage(context);

        // --- Step 7: Clean up ---
        free(alpha);
        free(blurredAlpha);
        CGContextRelease(context);

        if (!outputImage) {
            MMLog("MCApplyInnerShadow: failed to create output image");
            return NULL;
        }

        return outputImage;
    } // @autoreleasepool
}
