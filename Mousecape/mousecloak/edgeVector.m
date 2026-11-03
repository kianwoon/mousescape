//
//  edgeVector.m
//
#import "edgeVector.h"
#import "MCLogger.h"
#import "MCDefs.h"
#import "apply.h"
#import <math.h>

// --- tunables -------------------------------------------------------------
static const CGFloat  kMCEdgeMinEdgeFrac    = 0.4;   // min share of partial-alpha px on a narrow ramp
static const CGFloat  kMCEdgeRampDivisor    = 340;   // probe radius = width / this (6px at 2048)
static const uint8_t  kMCAlphaOpaque        = 230;
static const uint8_t  kMCAlphaClear         = 10;
static const float    kMCContourLevel       = 0.5f;  // alpha iso-level of the silhouette
static const double   kMCSimplifyTolerance  = 0.25;  // Douglas-Peucker tolerance, source px (keeps thin strokes)
static const int      kMCBleedPasses        = 8;     // colour dilation passes past the silhouette
static const CGFloat  kMCMaxSoftFrac       = 0.12;  // max share of visible px that are translucent but not on an edge
static const size_t   kMCMaxContourPoints   = 400000;

// --- RGBA8 premultiplied bitmap of a CGImage --------------------------------
static CGContextRef MCCreateRGBAContext(size_t w, size_t h, CGColorSpaceRef cs) {
    return CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs,
                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
}

BOOL MCImageHasHardEdges(CGImageRef image) {
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    size_t R = (size_t)fmax(2, (CGFloat)w / kMCEdgeRampDivisor);
    if (w <= 2 * R || h <= 2 * R) return NO;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = MCCreateRGBAContext(w, h, cs);
    CGColorSpaceRelease(cs);
    if (!ctx) return NO;
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
    const uint8_t *px = CGBitmapContextGetData(ctx);
    #define MC_A(x, y) px[((y) * w + (x)) * 4 + 3]
    #define MC_STEP(l, r) (((l) >= kMCAlphaOpaque && (r) <= kMCAlphaClear) || ((l) <= kMCAlphaClear && (r) >= kMCAlphaOpaque))
    size_t partial = 0, edgeLike = 0, visible = 0;
    for (size_t y = R; y < h - R; y++) {
        for (size_t x = R; x < w - R; x++) {
            uint8_t a = MC_A(x, y);
            if (a == 0) continue;
            visible++;
            if (a >= kMCAlphaOpaque) continue;
            partial++;
            if (MC_STEP(MC_A(x - R, y), MC_A(x + R, y)) || MC_STEP(MC_A(x, y - R), MC_A(x, y + R))) edgeLike++;
        }
    }
    #undef MC_A
    #undef MC_STEP
    CGContextRelease(ctx);
    return partial > 0 && ((CGFloat)edgeLike / (CGFloat)partial) >= kMCEdgeMinEdgeFrac
        && ((CGFloat)(partial - edgeLike) / (CGFloat)visible) <= kMCMaxSoftFrac;
}

// --- marching squares ---------------------------------------------------------
// Alpha is padded with a 1-px clear border so every contour closes.
typedef struct { double x, y; } MCPt;

// Edge id on the padded grid: even = horizontal edge (x,y)-(x+1,y), odd = vertical (x,y)-(x,y+1).
static inline long MCHEdge(long x, long y, long pw) { return 2 * (y * pw + x); }
static inline long MCVEdge(long x, long y, long pw) { return 2 * (y * pw + x) + 1; }

static MCPt MCEdgePoint(long id, const float *a, long pw) {
    long cell = id >> 1; long x = cell % pw, y = cell / pw;
    float v0 = a[cell];
    float v1 = (id & 1) ? a[cell + pw] : a[cell + 1];
    double t = (kMCContourLevel - v0) / (double)(v1 - v0);
    MCPt p = (id & 1) ? (MCPt){ (double)x, y + t } : (MCPt){ x + t, (double)y };
    return p;
}

static double MCPointLineDist(MCPt p, MCPt a, MCPt b) {
    double dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy;
    if (len2 < 1e-12) return hypot(p.x - a.x, p.y - a.y);
    return fabs((p.x - a.x) * dy - (p.y - a.y) * dx) / sqrt(len2);
}

static void MCSimplify(const MCPt *pts, long lo, long hi, double tol, bool *keep) {
    if (hi <= lo + 1) return;
    double best = -1; long bi = -1;
    for (long i = lo + 1; i < hi; i++) {
        double d = MCPointLineDist(pts[i], pts[lo], pts[hi]);
        if (d > best) { best = d; bi = i; }
    }
    if (best > tol) {
        keep[bi] = true;
        MCSimplify(pts, lo, bi, tol, keep);
        MCSimplify(pts, bi, hi, tol, keep);
    }
}

// Builds closed polygons (in source pixel coords, pixel centre at +0.5) from the alpha iso-contour.
static CGPathRef MCCreateSilhouettePath(const uint8_t *rgba, long w, long h) {
    long pw = w + 2, ph = h + 2;
    float *a = calloc((size_t)(pw * ph), sizeof(float));
    if (!a) return NULL;
    for (long y = 0; y < h; y++)
        for (long x = 0; x < w; x++)
            a[(y + 1) * pw + (x + 1)] = rgba[(y * w + x) * 4 + 3] / 255.0f;

    // adjacency: each crossed edge links to exactly two other crossed edges
    NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *adj = [NSMutableDictionary dictionary];
    void (^link)(long, long) = ^(long e0, long e1) {
        NSMutableArray *l0 = adj[@(e0)]; if (!l0) { l0 = [NSMutableArray arrayWithCapacity:2]; adj[@(e0)] = l0; }
        NSMutableArray *l1 = adj[@(e1)]; if (!l1) { l1 = [NSMutableArray arrayWithCapacity:2]; adj[@(e1)] = l1; }
        [l0 addObject:@(e1)]; [l1 addObject:@(e0)];
    };
    for (long y = 0; y < ph - 1; y++) {
        for (long x = 0; x < pw - 1; x++) {
            float tl = a[y * pw + x], tr = a[y * pw + x + 1], bl = a[(y + 1) * pw + x], br = a[(y + 1) * pw + x + 1];
            int c = (tl >= kMCContourLevel) | ((tr >= kMCContourLevel) << 1) | ((br >= kMCContourLevel) << 2) | ((bl >= kMCContourLevel) << 3);
            if (c == 0 || c == 15) continue;
            long T = MCHEdge(x, y, pw), B = MCHEdge(x, y + 1, pw), L = MCVEdge(x, y, pw), Rr = MCVEdge(x + 1, y, pw);
            switch (c) {
                case 1: case 14: link(T, L); break;
                case 2: case 13: link(T, Rr); break;
                case 3: case 12: link(L, Rr); break;
                case 4: case 11: link(Rr, B); break;
                case 6: case 9:  link(T, B); break;
                case 7: case 8:  link(L, B); break;
                case 5: case 10: {
                    BOOL centreHigh = ((tl + tr + br + bl) * 0.25f) >= kMCContourLevel;
                    BOOL tlHigh = (c == 10) ? NO : YES; // c==5: tl,br high; c==10: tr,bl high
                    if (centreHigh == tlHigh) { link(T, Rr); link(L, B); } else { link(T, L); link(Rr, B); }
                    break;
                }
            }
        }
    }

    CGMutablePathRef path = CGPathCreateMutable();
    NSMutableSet<NSNumber *> *visited = [NSMutableSet setWithCapacity:adj.count];
    size_t total = 0;
    for (NSNumber *startKey in adj) {
        if ([visited containsObject:startKey]) continue;
        NSMutableArray<NSNumber *> *loop = [NSMutableArray array];
        NSNumber *prev = nil, *cur = startKey;
        while (cur && ![visited containsObject:cur]) {
            [visited addObject:cur]; [loop addObject:cur];
            NSArray<NSNumber *> *nb = adj[cur];
            NSNumber *next = nil;
            for (NSNumber *n in nb) if (!(prev && [n isEqualToNumber:prev]) && ![visited containsObject:n]) { next = n; break; }
            prev = cur; cur = next;
        }
        long n = (long)loop.count;
        if (n < 3) continue;
        total += (size_t)n;
        if (total > kMCMaxContourPoints) { CGPathRelease(path); free(a); return NULL; }
        MCPt *pts = malloc(sizeof(MCPt) * (size_t)(n + 1));
        bool *keep = calloc((size_t)(n + 1), sizeof(bool));
        if (!pts || !keep) { free(pts); free(keep); CGPathRelease(path); free(a); return NULL; }
        for (long i = 0; i < n; i++) pts[i] = MCEdgePoint(loop[i].longValue, a, pw);
        pts[n] = pts[0];
        // split the closed loop at the two points farthest apart so DP has stable anchors
        long far = 0; double fd = -1;
        for (long i = 1; i < n; i++) { double d = hypot(pts[i].x - pts[0].x, pts[i].y - pts[0].y); if (d > fd) { fd = d; far = i; } }
        keep[0] = keep[far] = keep[n] = true;
        MCSimplify(pts, 0, far, kMCSimplifyTolerance, keep);
        MCSimplify(pts, far, n, kMCSimplifyTolerance, keep);
        BOOL first = YES;
        for (long i = 0; i < n; i++) {
            if (!keep[i]) continue;
            // padded grid -> source coords (minus pad), +0.5 for pixel-centre sampling
            CGFloat px = pts[i].x - 1 + 0.5, py = pts[i].y - 1 + 0.5;
            if (first) { CGPathMoveToPoint(path, NULL, px, py); first = NO; } else CGPathAddLineToPoint(path, NULL, px, py);
        }
        CGPathCloseSubpath(path);
        free(pts); free(keep);
    }
    free(a);
    return path;
}

// --- colour bleed: replace colour of non-opaque pixels with nearby opaque colour ----------
static CGImageRef MCCreateBledColourImage(const uint8_t *rgba, size_t w, size_t h, CGColorSpaceRef cs) {
    size_t n = w * h;
    uint8_t *col = calloc(n, 4);
    uint8_t *done = calloc(n, 1);
    if (!col || !done) { free(col); free(done); return NULL; }
    for (size_t i = 0; i < n; i++) {
        uint8_t a = rgba[i * 4 + 3];
        if (a >= kMCAlphaOpaque) {            // un-premultiply fully trusted pixels
            for (int c = 0; c < 3; c++) { unsigned v = (rgba[i * 4 + c] * 255u + a / 2) / a; col[i * 4 + c] = v > 255 ? 255 : (uint8_t)v; }
            col[i * 4 + 3] = 255; done[i] = 1;
        }
    }
    uint8_t *nextDone = malloc(n);
    if (!nextDone) { free(col); free(done); return NULL; }
    for (int pass = 0; pass < kMCBleedPasses; pass++) {
        memcpy(nextDone, done, n);
        for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) {
            size_t i = y * w + x; if (done[i]) continue;
            unsigned r = 0, g = 0, b = 0, cnt = 0;
            for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
                long nx = (long)x + dx, ny = (long)y + dy;
                if (nx < 0 || ny < 0 || nx >= (long)w || ny >= (long)h) continue;
                size_t j = (size_t)ny * w + (size_t)nx; if (!done[j]) continue;
                r += col[j * 4]; g += col[j * 4 + 1]; b += col[j * 4 + 2]; cnt++;
            }
            if (cnt) { col[i * 4] = r / cnt; col[i * 4 + 1] = g / cnt; col[i * 4 + 2] = b / cnt; col[i * 4 + 3] = 255; nextDone[i] = 1; }
        }
        memcpy(done, nextDone, n);
    }
    free(nextDone);
    for (size_t i = 0; i < n; i++) if (!done[i]) { col[i * 4 + 3] = 255; } // far-field: opaque black, clipped away
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, col, n * 4, NULL);
    CGImageRef img = CGImageCreate(w, h, 8, 32, w * 4, cs, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big,
                                   dp, NULL, false, kCGRenderingIntentDefault);
    // copy out so we can free the buffers
    CGImageRef copy = NULL;
    if (img) {
        CGContextRef cc = MCCreateRGBAContext(w, h, cs);
        if (cc) { CGContextDrawImage(cc, CGRectMake(0, 0, w, h), img); copy = CGBitmapContextCreateImage(cc); CGContextRelease(cc); }
        CGImageRelease(img);
    }
    CGDataProviderRelease(dp);
    free(col); free(done);
    return copy;
}

CGImageRef MCVectorUpscaleHardEdges(CGImageRef image, size_t targetW, size_t targetH) {
    @autoreleasepool {
        size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
        if (w < 8 || h < 8 || targetW < w || targetH < h) return NULL;
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef src = MCCreateRGBAContext(w, h, cs);
        if (!src) { CGColorSpaceRelease(cs); return NULL; }
        CGContextDrawImage(src, CGRectMake(0, 0, w, h), image);
        // CGBitmapContext data is stored top row first for drawn images
        const uint8_t *rgba = CGBitmapContextGetData(src);

        CGPathRef silhouette = MCCreateSilhouettePath(rgba, (long)w, (long)h);
        CGImageRef colour = MCCreateBledColourImage(rgba, w, h, cs);
        CGContextRelease(src);
        if (!silhouette || !colour) {
            if (silhouette) CGPathRelease(silhouette);
            if (colour) CGImageRelease(colour);
            CGColorSpaceRelease(cs);
            return NULL;
        }

        CGContextRef out = MCCreateRGBAContext(targetW, targetH, cs);
        CGImageRef result = NULL;
        if (out) {
            CGContextSetInterpolationQuality(out, kCGInterpolationHigh);
            CGContextDrawImage(out, CGRectMake(0, 0, targetW, targetH), colour);
            // Rasterise the silhouette into an alpha mask at target res (CoreGraphics
            // anti-aliases the exact vector edge), then multiply the colour by it.
            CGContextRef maskCtx = MCCreateRGBAContext(targetW, targetH, cs);
            if (maskCtx) {
                CGContextSetShouldAntialias(maskCtx, true);
                CGContextTranslateCTM(maskCtx, 0, (CGFloat)targetH);
                CGContextScaleCTM(maskCtx, (CGFloat)targetW / (CGFloat)w, -(CGFloat)targetH / (CGFloat)h);
                CGContextSetRGBFillColor(maskCtx, 1, 1, 1, 1);
                CGContextAddPath(maskCtx, silhouette);
                CGContextEOFillPath(maskCtx);
                CGImageRef maskImg = CGBitmapContextCreateImage(maskCtx);
                CGContextRelease(maskCtx);
                if (maskImg) {
                    CGContextSetBlendMode(out, kCGBlendModeDestinationIn);
                    CGContextDrawImage(out, CGRectMake(0, 0, targetW, targetH), maskImg);
                    CGImageRelease(maskImg);
                }
            }
            result = CGBitmapContextCreateImage(out);
            CGContextRelease(out);
        }
        CGPathRelease(silhouette);
        CGImageRelease(colour);
        CGColorSpaceRelease(cs);
        MMLog("  Vector silhouette upscale: %zux%zu -> %zux%zu", w, h, targetW, targetH);
        return result;
    }
}
