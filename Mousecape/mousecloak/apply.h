//
//  apply.h
//  Mousecape
//
//  Created by Alex Zielenski on 2/1/14.
//  Copyright (c) 2014 Alex Zielenski. All rights reserved.
//

#ifndef Mousecape_apply_h
#define Mousecape_apply_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

extern BOOL applyCursorForIdentifier(NSUInteger frameCount, CGFloat frameDuration, CGPoint hotSpot, CGSize size, NSArray *images, NSString *ident, NSUInteger repeatCount, BOOL skipSynonyms);
extern BOOL applyCapeForIdentifier(NSDictionary *cursor, NSString *identifier, BOOL restore, BOOL customScaleMode, BOOL skipSynonyms, BOOL isSystemDefault, float baseScale);
extern BOOL applyCape(NSDictionary *dictionary);
extern NSDictionary *applyCapeWithResult(NSDictionary *dictionary);
extern BOOL applyCapeAtPath(NSString *path);
extern void refreshSystemDefaultCursors(void);
extern BOOL applyCapeWithoutReset(NSDictionary *dictionary);
// Lightweight re-apply (macOS 27): registers only the cape's cursors in place, without
// CoreCursorUnregisterAll / system-default churn / scale toggle, keeping the accessibility
// cursor compositor engaged so large cursors keep painting. Use for in-app re-applies.
extern BOOL applyCapeLight(NSDictionary *dictionary);
extern volatile BOOL g_refreshingSystemDefaults;

// Cross-process apply-recency stamp (see apply.m). MCStampApplyTime() records
// "an apply just happened"; MCSecondsSinceLastApply() lets the Helper's display
// reconfiguration callback ignore the self-induced events that follow an apply.
extern void MCStampApplyTime(void);
extern double MCSecondsSinceLastApply(void);

// Record the applied cape and notify the Helper, WITHOUT registering cursors in this
// process. The foreground app uses this to delegate the apply to the background Helper
// (whose apply renders large cursors on macOS 27, unlike the foreground app's).
extern void persistAppliedCape(NSString *identifier);

// macOS 27: restart universalaccessd so the accessibility cursor compositor re-engages
// on the just-applied cape (large cursors otherwise blink/vanish on a mid-session apply).
extern void reengageAccessibilityCursor(void);

NS_ASSUME_NONNULL_END

#endif
