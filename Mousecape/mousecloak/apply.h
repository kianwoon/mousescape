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
extern volatile BOOL g_refreshingSystemDefaults;

NS_ASSUME_NONNULL_END

#endif
