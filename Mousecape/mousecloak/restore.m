//
//  restore.m
//  Mousecape
//
//  Created by Alex Zielenski on 2/1/14.
//  Copyright (c) 2014 Alex Zielenski. All rights reserved.
//

#import "apply.h"
#import "backup.h"
#import "MCPrefs.h"
#import "MCDefs.h"
#import "scale.h"
#import "CGSInternal/CGSCursor.h"

NSString *restoreStringForIdentifier(NSString *identifier) {
    NSString *prefix = @"com.alexzielenski.mousecape.";
    if ([identifier hasPrefix:prefix] && identifier.length > prefix.length) {
        return [identifier substringFromIndex:prefix.length];
    }
    return identifier;
}

void restoreCursorForIdentifier(NSString *ident) {
    MMLog("  Restoring: %s", ident.UTF8String);
    bool registered = false;
    MCIsCursorRegistered(CGSMainConnectionID(), (char *)ident.UTF8String, &registered);

    NSString *restoreIdent = restoreStringForIdentifier(ident);
    NSDictionary *cape = capeWithIdentifier(ident);

    MMLog("    Restore target: %s, registered: %s, cape: %s",
          restoreIdent.UTF8String,
          registered ? "YES" : "NO",
          cape ? "YES" : "NO");

    if (cape && registered) {
        BOOL success = applyCapeForIdentifier(cape, restoreIdent, YES, NO, NO, NO, 1.0f);
        MMLog("    Restore result: %s", success ? "SUCCESS" : "FAILED");
    } else {
        MMLog("    Skipped - no cape or not registered");
    }

    CGSRemoveRegisteredCursor(CGSMainConnectionID(), (char *)ident.UTF8String, false);
    MMLog("    Removed backup cursor");
}

void resetAllCursors(void) {
    MMLog("=== resetAllCursors ===");

    // Save current scale settings
    float originalScale;
    CGSGetCursorScale(CGSMainConnectionID(), &originalScale);
    id originalScalePref = MCDefault(MCPreferencesCursorScaleKey);

    // Temporarily set scale to 1.0 to ensure system cursors are restored
    // at their original size, not scaled by the current preference
    MCSetDefault(@1.0, MCPreferencesCursorScaleKey);
    CGSSetCursorScale(CGSMainConnectionID(), 1.0);

    // Restore all cursors from backups (default + synonyms)
    MMLog("--- Restoring all cursors from backups ---");
    MCEnumerateAllCursorIdentifiers(^(NSString *name) {
        restoreCursorForIdentifier(backupStringForIdentifier(name));
    });

    // Restore auxiliary/core cursors
    MMLog("--- Restoring core cursors ---");
    // Always clear the applied-cape preference, even if CoreCursorUnregisterAll
    // reports an error — otherwise reset leaves the cape "applied" and the Helper
    // re-applies it on the next event. Use an explicit synchronized write so the
    // removal is immediately visible to other processes (MCSetDefault doesn't sync).
    CFPreferencesSetValue((__bridge CFStringRef)MCPreferencesAppliedCursorKey, NULL,
                          (__bridge CFStringRef)kMCDomain,
                          kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
    CFPreferencesSynchronize((__bridge CFStringRef)kMCDomain,
                             kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
    NSLog(@"[MousecapeHelper] resetAllCursors: cleared MCAppliedCursor");

    CGError err = CoreCursorUnregisterAll(CGSMainConnectionID());
    NSLog(@"[MousecapeHelper] resetAllCursors: CoreCursorUnregisterAll result=%d", (int)err);

    if (err == 0) {
        for (int x = 0; x < 45; x++) {
            CoreCursorSet(CGSMainConnectionID(), x);
        }
        NSLog(@"[MousecapeHelper] resetAllCursors: restored %d core cursors", 45);
    } else {
        NSLog(@"[MousecapeHelper] resetAllCursors: error restoring core cursors (err=%d)", (int)err);
    }

    // Restore original scale settings
    CGSSetCursorScale(CGSMainConnectionID(), originalScale);
    MCSetDefault(originalScalePref, MCPreferencesCursorScaleKey);

    MMLog("=== resetAllCursors complete ===");
}
