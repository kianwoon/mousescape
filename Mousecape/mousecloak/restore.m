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
    CGError err = CoreCursorUnregisterAll(CGSMainConnectionID());
    MMLog("CoreCursorUnregisterAll result: %d", err);

    if (err == 0) {
        MCSetDefault(NULL, MCPreferencesAppliedCursorKey);
        for (int x = 0; x < 45; x++) {
            CoreCursorSet(CGSMainConnectionID(), x);
        }
        MMLog(BOLD GREEN "Successfully restored all cursors." RESET);
    } else {
        MMLog(BOLD RED "Received an error while restoring core cursors." RESET);
    }

    // Restore original scale settings
    CGSSetCursorScale(CGSMainConnectionID(), originalScale);
    MCSetDefault(originalScalePref, MCPreferencesCursorScaleKey);

    MMLog("=== resetAllCursors complete ===");
}
