//
//  scale.m
//  Mousecape
//
//  Created by Alex Zielenski on 2/2/14.
//  Copyright (c) 2014 Alex Zielenski. All rights reserved.
//

#import "scale.h"
#import "MCPrefs.h"
#import "MCDefs.h"
#import "CGSCursor.h"
#import <math.h>

float cursorScale(void) {
    float value;
    CGSGetCursorScale(CGSMainConnectionID(), &value);
    return value;
}

float defaultCursorScale(void) {
    float scale = [MCDefault(MCPreferencesCursorScaleKey) floatValue];
    if (scale < .5 || scale > 96)
        scale = 1;
    return scale;
}

BOOL setCursorScale(float dbl) {
    if (!isfinite(dbl) || dbl <= 0 || dbl > 96) {
        MMLog(BOLD RED "Invalid cursor scale (must be 0 < scale <= 96)" RESET);
        return NO;
    } else if (CGSSetCursorScale(CGSMainConnectionID(), dbl) == noErr) {
        MMLog("Successfully set cursor scale!");
        return YES;
    } else {
        MMLog("Somehow failed to set cursor scale!");
        return NO;
    }
}

BOOL customScaleMode(void) {
    // Always re-read from CFPreferences to avoid stale cache across processes.
    // Called only during session/display events (not a hot path).
    NSString *mode = (__bridge_transfer NSString *)CFPreferencesCopyValue(
        CFSTR("MCScaleMode"),
        CFSTR("com.sdmj76.Mousecape"),
        kCFPreferencesCurrentUser,
        kCFPreferencesCurrentHost
    );
    BOOL isCustom = [mode isEqualToString:@"custom"];
    MMLog("Scale mode read from preferences: %s", isCustom ? "custom" : "global");
    return isCustom;
}

void setCustomScaleMode(BOOL isCustom) {
    // Persist to CFPreferences so other processes (Helper) pick up the change
    NSString *modeValue = isCustom ? @"custom" : @"global";
    CFPreferencesSetValue(
        CFSTR("MCScaleMode"),
        (__bridge CFPropertyListRef)modeValue,
        CFSTR("com.sdmj76.Mousecape"),
        kCFPreferencesCurrentUser,
        kCFPreferencesCurrentHost
    );
    CFPreferencesSynchronize(
        CFSTR("com.sdmj76.Mousecape"),
        kCFPreferencesCurrentUser,
        kCFPreferencesCurrentHost
    );

    MMLog("Scale mode set to: %s", isCustom ? "custom" : "global");
}
