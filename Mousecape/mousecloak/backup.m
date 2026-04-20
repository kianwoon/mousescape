//
//  backup.m
//  Mousecape
//
//  Created by Alex Zielenski on 2/1/14.
//  Copyright (c) 2014 Alex Zielenski. All rights reserved.
//

#import "backup.h"
#import "apply.h"
#import "MCDefs.h"

NSString *backupStringForIdentifier(NSString *identifier) {
    return [NSString stringWithFormat:@"com.alexzielenski.mousecape.%@", identifier];
}

void backupCursorForIdentifier(NSString *ident) {
    MMLog("  Backing up: %s", ident.UTF8String);
    bool registered = false;
    MCIsCursorRegistered(CGSMainConnectionID(), (char *)ident.UTF8String, &registered);

//     dont try to backup a nonexistant cursor
    if (!registered) {
        MMLog("    Skipped - cursor not registered");
        return;
    }

    NSString *backupIdent = backupStringForIdentifier(ident);
    MCIsCursorRegistered(CGSMainConnectionID(), (char *)backupIdent.UTF8String, &registered);

//     don't re-back it up
    if (registered) {
        MMLog("    Skipped - backup already exists");
        return;
    }

    NSDictionary *cape = capeWithIdentifier(ident);
    BOOL success = applyCapeForIdentifier(cape, backupIdent, YES, NO, NO, NO, 1.0f);
    MMLog("    Backup result: %s", success ? "SUCCESS" : "FAILED");
}

void backupAllCursors(void) {
    MMLog("=== backupAllCursors ===");
    // Iterate ALL identifiers — backupCursorForIdentifier individually skips
    // cursors that already have backups, so this safely picks up any newly-added
    // identifiers (e.g. com.apple.cursor.N added in v1.1.2) on existing installs.
    MMLog("--- Backing up all cursors ---");
    MCEnumerateAllCursorIdentifiers(^(NSString *name) {
        backupCursorForIdentifier(name);
    });
    MMLog("=== backupAllCursors complete ===");
}
