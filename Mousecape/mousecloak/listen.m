//
//  listen.m
//  Mousecape
//
//  Created by Alex Zielenski on 2/1/14.
//  Copyright (c) 2014 Alex Zielenski. All rights reserved.
//

#import "listen.h"
#import "apply.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import "MCPrefs.h"
#import "MCDefs.h"
#import "CGSCursor.h"
#import <Cocoa/Cocoa.h>
#import <os/log.h>

// NSLog-based logging for reliable visibility in unified log and Console.app.
// os_log with custom subsystems is not persisted for ad-hoc signed apps,
// so we use NSLog which always appears under the default subsystem.
#define HLOG(fmt, ...) NSLog(@"[MousecapeHelper] " fmt, ## __VA_ARGS__)
#define HLOG_ERR(fmt, ...) NSLog(@"[MousecapeHelper][ERROR] " fmt, ## __VA_ARGS__)
#define HLOG_SUCCESS(fmt, ...) NSLog(@"[MousecapeHelper] " fmt, ## __VA_ARGS__)

// Forward declaration for cleanup
static void unregisterDisplayCallback(void);

// Static references for session monitor cleanup
static CFRunLoopSourceRef g_sessionMonitorRLS = NULL;

NSString *appliedCapePathForUser(NSString *user) {
    // Validate user - must not be empty or contain path separators
    if (!user || user.length == 0 || [user containsString:@"/"] || [user containsString:@".."]) {
        MMLog(BOLD RED "Invalid username" RESET);
        return nil;
    }

    NSString *home = NSHomeDirectoryForUser(user);
    if (!home) {
        MMLog(BOLD RED "Could not get home directory for user" RESET);
        return nil;
    }

    NSString *ident = MCDefaultFor(@"MCAppliedCursor", user, (NSString *)kCFPreferencesCurrentHost);
    HLOG("appliedCapePathForUser: user=%@, ident=%@", user, ident ?: @"(null)");

    // Validate identifier - remove any path traversal attempts
    if (ident && ([ident containsString:@"/"] || [ident containsString:@".."])) {
        MMLog(BOLD RED "Invalid cape identifier" RESET);
        return nil;
    }

    if (!ident || ident.length == 0) {
        HLOG("No MCAppliedCursor set for user %@", user);
        return nil;
    }

    NSString *appSupport = [home stringByAppendingPathComponent:@"Library/Application Support"];
    NSString *capePath = [[[appSupport stringByAppendingPathComponent:@"Mousecape/capes"] stringByAppendingPathComponent:ident] stringByAppendingPathExtension:@"cape"];
    HLOG("Resolved cape path: %@", capePath);

    // Ensure the final path is within the expected directory
    NSString *standardPath = [capePath stringByStandardizingPath];
    NSString *expectedPrefix = [[appSupport stringByAppendingPathComponent:@"Mousecape/capes"] stringByStandardizingPath];
    if (![standardPath hasPrefix:expectedPrefix]) {
        MMLog(BOLD RED "Path traversal detected" RESET);
        return nil;
    }

    return capePath;
}

static void UserSpaceChanged(SCDynamicStoreRef	store, CFArrayRef changedKeys, void *info) {
    // Skip if refreshSystemDefaultCursors is mid-extraction at 64x.
    // Re-entering would read the boosted 64x scale and "restore" to it permanently.
    if (g_refreshingSystemDefaults) {
        MMLog(YELLOW "UserSpaceChanged: refresh in progress, skipping" RESET);
        return;
    }

    HLOG("UserSpaceChanged fired");
    MMLog("========================================");
    MMLog("=== USER SPACE CHANGED EVENT ===");
    MMLog("========================================");

    CFStringRef currentConsoleUser = SCDynamicStoreCopyConsoleUser(store, NULL, NULL);

    MMLog("Console user: %s", currentConsoleUser ? [(__bridge NSString *)currentConsoleUser UTF8String] : "(null)");
    MMLog("Changed keys count: %ld", CFArrayGetCount(changedKeys));

    if (!currentConsoleUser || CFEqual(currentConsoleUser, CFSTR("loginwindow"))) {
        MMLog("Skipping - loginwindow or no user");
        if (currentConsoleUser) CFRelease(currentConsoleUser);
        return;
    }

    NSString *appliedPath = appliedCapePathForUser((__bridge NSString *)currentConsoleUser);
    MMLog(BOLD GREEN "User Space Changed to %s, applying cape..." RESET, [(__bridge NSString *)currentConsoleUser UTF8String]);
    MMLog("Cape path: %s", appliedPath ? appliedPath.UTF8String : "(none)");

    // Only attempt to apply if there's a valid cape path
    if (appliedPath) {
        BOOL success = applyCapeAtPath(appliedPath);
        MMLog("Apply result: %s", success ? "SUCCESS" : "FAILED");
        if (success) { HLOG("UserSpaceChanged apply succeeded"); }
        else { HLOG_ERR("UserSpaceChanged apply FAILED"); }
        if (!success) {
            MMLog(BOLD RED "Application of cape failed" RESET);
        }
    } else {
        // No cape configured — do nothing.
        // Do NOT call refreshSystemDefaultCursors() here. Without an applied cape,
        // there is no cursor scale to restore, and the 64x extraction boost can
        // leave the WindowServer scale in a corrupted state on wake-from-sleep.
        MMLog("No cape configured for user — skipping re-apply");
    }

    CFRelease(currentConsoleUser);
}

void reconfigurationCallback(CGDirectDisplayID display,
	CGDisplayChangeSummaryFlags flags,
	void *userInfo) {
    // Skip if refreshSystemDefaultCursors is mid-extraction at 64x.
    if (g_refreshingSystemDefaults) {
        MMLog(YELLOW "Reconfig: apply/refresh in progress, skipping" RESET);
        return;
    }

    // Skip the "begin" phase — macOS fires this callback twice per event:
    // once before the change (begin flag set) and once after (no begin flag).
    // Only acting on the "after" phase prevents double re-application.
    if (flags & kCGDisplayBeginConfigurationFlag) {
        MMLog("Display %u reconfiguration BEGIN phase — skipping", display);
        return;
    }

    MMLog("========================================");
    MMLog("=== DISPLAY RECONFIGURATION EVENT ===");
    MMLog("========================================");
    MMLog("Display ID: %u", display);
    MMLog("Flags: 0x%x", flags);

    NSString *capePath = appliedCapePathForUser(NSUserName());
    MMLog("Cape path: %s", capePath ? capePath.UTF8String : "(none)");

    if (capePath) {
        // Give WindowServer time to settle after wake/reconfiguration.
        // Without this delay, CGSSetCursorScale calls may be ignored or
        // overridden by the WindowServer mid-initialization.
        MMLog("Waiting 1000ms for WindowServer to settle...");
        HLOG("Reconfiguration: waiting 1s for WindowServer to settle");
        usleep(1000000); // 1000 ms

        // Retry up to 3 times on failure — the WindowServer may not be
        // fully ready on the first attempt after wake-from-sleep.
        int maxRetries = 3;
        for (int attempt = 1; attempt <= maxRetries; attempt++) {
            BOOL success = applyCapeAtPath(capePath);
            MMLog("Apply attempt %d/%d: %s", attempt, maxRetries, success ? "SUCCESS" : "FAILED");
            if (success) { HLOG("Reconfiguration apply attempt %d/%d: success", attempt, maxRetries); }
            else { HLOG_ERR("Reconfiguration apply attempt %d/%d: failed", attempt, maxRetries); }
            if (success) break;
            if (attempt < maxRetries) {
                MMLog("Retrying in 500ms...");
                usleep(500000); // 500 ms
            }
        }
    } else {
        // No cape applied — do nothing.  Avoid calling refreshSystemDefaultCursors()
        // here because its 64x extraction boost can leave the scale stuck if the
        // WindowServer is sluggish after wake.
        MMLog("No cape configured — skipping re-apply after reconfiguration");
    }
}


void listener(void) {
#ifdef DEBUG
    MCLoggerInit();
#endif

    MMLog("========================================");
    MMLog("=== MOUSECAPE HELPER DAEMON STARTED ===");
    MMLog("========================================");

    NSOperatingSystemVersion ver = [[NSProcessInfo processInfo] operatingSystemVersion];
    MMLog("macOS version: %ld.%ld.%ld",
          (long)ver.majorVersion, (long)ver.minorVersion, (long)ver.patchVersion);
    MMLog("Process: %s (PID: %d)",
          [[[NSProcessInfo processInfo] processName] UTF8String],
          [[NSProcessInfo processInfo] processIdentifier]);
    MMLog("User: %s", NSUserName().UTF8String);
    MMLog("Home: %s", NSHomeDirectory().UTF8String);

    // Log environment variables
    MMLog("--- Environment Variables ---");
    NSDictionary *env = [[NSProcessInfo processInfo] environment];
    for (NSString *key in @[@"USER", @"HOME", @"DISPLAY", @"XPC_SERVICE_NAME"]) {
        MMLog("  %s = %s", key.UTF8String, [env[key] UTF8String] ?: "(null)");
    }

    SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("com.apple.dts.ConsoleUser"), UserSpaceChanged, NULL);
    if (!store) {
        MMLog(BOLD RED "Failed to create SCDynamicStore — session monitor unavailable" RESET);
        goto enter_runloop;
    }

    CFStringRef key = SCDynamicStoreKeyCreateConsoleUser(NULL);
    if (!key) {
        MMLog(BOLD RED "Failed to create console user key — session monitor unavailable" RESET);
        CFRelease(store);
        goto enter_runloop;
    }

    CFArrayRef keys = CFArrayCreate(NULL, (const void **)&key, 1, &kCFTypeArrayCallBacks);
    if (!keys) {
        MMLog(BOLD RED "Failed to create key array — session monitor unavailable" RESET);
        CFRelease(key);
        CFRelease(store);
        goto enter_runloop;
    }

    {
        Boolean success = SCDynamicStoreSetNotificationKeys(store, keys, NULL);
        if (!success) {
            MMLog(BOLD RED "Failed to set notification keys — session monitor unavailable" RESET);
            CFRelease(keys);
            CFRelease(key);
            CFRelease(store);
            goto enter_runloop;
        }
        CFRelease(keys);
        CFRelease(key);
    }

    NSApplicationLoad();
    CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, NULL);
    MMLog(BOLD CYAN "Listening for Display changes" RESET);

    {
        CFRunLoopSourceRef rls = SCDynamicStoreCreateRunLoopSource(NULL, store, 0);
        if (!rls) {
            MMLog(BOLD RED "Failed to create run loop source — session monitor unavailable" RESET);
            CFRelease(store);
            goto enter_runloop;
        }

        // Check CGS Connection
        MMLog("--- Checking CGS Connection ---");
        CGSConnectionID cid = CGSMainConnectionID();
        MMLog("CGSMainConnectionID: %d", cid);

        // Apply the cape for the user on load (if configured)
        MMLog("--- Initial Cape Check ---");
        NSString *initialCapePath = appliedCapePathForUser(NSUserName());
        MMLog("Cape path: %s", initialCapePath ? initialCapePath.UTF8String : "(none)");
        if (initialCapePath) {
            MMLog("--- Applying initial cape ---");
            BOOL applySuccess = applyCapeAtPath(initialCapePath);
            MMLog("Initial apply result: %s", applySuccess ? "SUCCESS" : "FAILED");
        } else {
            // No cape configured — do nothing on startup.
            // refreshSystemDefaultCursors() boosts scale to 64x for extraction, and on
            // early boot the WindowServer may not be fully settled, causing the restore
            // to fail and leaving the scale stuck at a wrong value.
            MMLog("No cape configured — skipping initial refresh (system defaults are already active)");
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, kCFRunLoopDefaultMode);
        MMLog("Entering run loop...");
        CFRunLoopRun();

        // Cleanup
        MMLog("Exiting run loop, cleaning up...");
        CFRunLoopSourceInvalidate(rls);
        CFRelease(rls);
    }

    // Cleanup display callback
    unregisterDisplayCallback();
    CFRelease(store);

#ifdef DEBUG
    MCLoggerClose();
#endif
    return;

enter_runloop:
    // Fallback: still enter run loop to keep the process alive, but without session monitoring
    MMLog(BOLD YELLOW "Entering run loop without session monitoring" RESET);
    CFRunLoopRun();
#ifdef DEBUG
    MCLoggerClose();
#endif
}

// Cleanup: remove display reconfiguration callback to prevent firing during teardown
static void unregisterDisplayCallback(void) {
    CGDisplayRemoveReconfigurationCallback(reconfigurationCallback, NULL);
    MMLog("Display reconfiguration callback unregistered");
}

void startSessionMonitor(void) {
    MMLog("========================================");
    MMLog("=== SESSION MONITOR STARTED (in-app) ===");
    MMLog("========================================");
    HLOG("startSessionMonitor called");

    SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("com.apple.dts.ConsoleUser"), UserSpaceChanged, NULL);
    if (!store) {
        MMLog(BOLD RED "Failed to create SCDynamicStore — session monitor unavailable" RESET);
        return;
    }

    CFStringRef key = SCDynamicStoreKeyCreateConsoleUser(NULL);
    if (!key) {
        MMLog(BOLD RED "Failed to create console user key — session monitor unavailable" RESET);
        CFRelease(store);
        return;
    }

    CFArrayRef keys = CFArrayCreate(NULL, (const void **)&key, 1, &kCFTypeArrayCallBacks);
    if (!keys) {
        MMLog(BOLD RED "Failed to create key array — session monitor unavailable" RESET);
        CFRelease(key);
        CFRelease(store);
        return;
    }

    {
        Boolean success = SCDynamicStoreSetNotificationKeys(store, keys, NULL);
        if (!success) {
            MMLog(BOLD RED "Failed to set notification keys — session monitor unavailable" RESET);
            CFRelease(keys);
            CFRelease(key);
            CFRelease(store);
            return;
        }
        CFRelease(keys);
        CFRelease(key);
    }

    CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, NULL);
    MMLog(BOLD CYAN "Listening for Display changes" RESET);

    CFRunLoopSourceRef rls = SCDynamicStoreCreateRunLoopSource(NULL, store, 0);
    if (!rls) {
        MMLog(BOLD RED "Failed to create run loop source — session monitor unavailable" RESET);
        unregisterDisplayCallback();
        CFRelease(store);
        return;
    }
    MMLog(BOLD CYAN "Listening for User changes" RESET);

    // Apply the cape for the user on load (if configured)
    // Retry up to 5 times with increasing delay — at startup the WindowServer
    // may not be ready, causing applyCapeAtPath to fail silently.
    NSString *initialCapePath = appliedCapePathForUser(NSUserName());
    if (initialCapePath) {
        BOOL applySuccess = NO;
        int maxStartupRetries = 5;
        for (int attempt = 1; attempt <= maxStartupRetries; attempt++) {
            applySuccess = applyCapeAtPath(initialCapePath);
            MMLog("Initial apply attempt %d/%d: %s", attempt, maxStartupRetries, applySuccess ? "SUCCESS" : "FAILED");
            if (applySuccess) { HLOG("Startup apply attempt %d/%d: success", attempt, maxStartupRetries); }
            else { HLOG_ERR("Startup apply attempt %d/%d: failed", attempt, maxStartupRetries); }
            if (applySuccess) break;
            // Exponential backoff: 1s, 2s, 3s, 4s
            double delaySec = (double)attempt;
            MMLog("Retrying in %.0fs...", delaySec);
            usleep((useconds_t)(delaySec * 1000000));
        }
        if (!applySuccess) {
            HLOG_ERR("All %d startup apply attempts failed", maxStartupRetries);
        }
    } else {
        // No cape configured — do nothing on startup.
        // refreshSystemDefaultCursors() boosts scale to 64x for extraction, and on
        // early boot the WindowServer may not be fully settled, causing the restore
        // to fail and leaving the scale stuck at a wrong value.
        // The session/display event callbacks (UserSpaceChanged, reconfigurationCallback)
        // already skip when no cape is set for this same reason.
        MMLog("No cape configured — skipping initial refresh (system defaults are already active)");
    }
    g_sessionMonitorRLS = rls;
    CFRunLoopAddSource(CFRunLoopGetMain(), rls, kCFRunLoopDefaultMode);
    MMLog("Session monitor attached to main run loop (non-blocking)");

    // Intentionally not releasing store/rls — they must stay alive
    // for the lifetime of the app to keep the session monitor active.
}

void stopSessionMonitor(void) {
    MMLog("Stopping session monitor...");

    // Remove display reconfiguration callback to prevent firing during teardown
    unregisterDisplayCallback();

    // Remove run loop source to stop receiving session change notifications
    if (g_sessionMonitorRLS) {
        CFRunLoopSourceInvalidate(g_sessionMonitorRLS);
        g_sessionMonitorRLS = NULL;
        MMLog("Session monitor run loop source removed");
    }
}

BOOL reapplyCapeForCurrentUser(void) {
    HLOG("reapplyCapeForCurrentUser called");
    NSString *capePath = appliedCapePathForUser(NSUserName());
    if (!capePath) {
        HLOG("No cape configured for current user");
        return NO;
    }
    BOOL success = applyCapeAtPath(capePath);
    if (success) { HLOG("Reapply succeeded"); }
    else { HLOG_ERR("Reapply failed"); }
    return success;
}
