//
//  HelperBridge.m
//  MousecapeHelper
//
//  Bridge between Swift and ObjC - imports all complex headers
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "../mousecloak/listen.h"
#import "../mousecloak/apply.h"
#import "../mousecloak/MCLogger.h"
#import "../mousecloak/MCPrefs.h"
#import "../mousecloak/restore.h"
#import "../mousecloak/CGSInternal/CGSCursor.h"
#import "../mousecloak/CGSInternal/CGSConnection.h"

// These functions are already provided by the .m files added to the target
// This file just ensures proper linking

// Reset cursors to system default
void ResetCursorsToDefault(void) {
    // Use the same function as main app
    resetAllCursors();
    // macOS 27: re-engage the accessibility cursor compositor so it repaints the
    // now-default cursors (resetAllCursors unregisters the cape, but the compositor
    // still holds the old large-cursor surface until it's rebuilt).
    reengageAccessibilityCursorCompositor();
}

// Simple logging wrapper for Swift (non-variadic)
void HelperLog(const char* message) {
    if (message) {
        MCLoggerWrite("%s\n", message);
    }
}
