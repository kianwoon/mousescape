//
//  MousecapeHelper-Bridging-Header.h
//  MousecapeHelper
//

#ifndef MousecapeHelper_Bridging_Header_h
#define MousecapeHelper_Bridging_Header_h

#import <Foundation/Foundation.h>

// Pure C function declarations (no ObjC syntax)
// These functions are defined in HelperBridge.m or linked from mousecloak

// Logger functions
void MCLoggerInit(void);
void MCLoggerClose(void);
void MCLoggerWrite(const char *format, ...);

// Session monitoring
void startSessionMonitor(void);
void stopSessionMonitor(void);

// Cursor management
void ResetCursorsToDefault(void);
void refreshSystemDefaultCursors(void);
BOOL reapplyCapeForCurrentUser(void);
// User-initiated apply path (ArrowS scale hotkeys): not gated by the shared
// wake cooldown. Defined in listen.m alongside reapplyCapeForCurrentUser().
BOOL applyCurrentCapeUserInitiated(void);
// Live base cursor scale (scale.m) — used when switching global -> custom mode.
BOOL setCursorScale(float scale);
// Persists MCScaleMode to currentHost (what apply.m/scale.m actually read).
void setCustomScaleMode(BOOL isCustom);

// Simple logging wrapper for Swift
void HelperLog(const char* message);

#endif /* MousecapeHelper_Bridging_Header_h */
