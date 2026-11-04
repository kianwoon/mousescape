//
//  MCLogger.h
//  Mousecape
//
//  Debug logging system for Mousecape.
//  Only active when DEBUG macro is defined.
//

#ifndef MCLogger_h
#define MCLogger_h

#import <Foundation/Foundation.h>
#import <os/log.h>
#include <stdarg.h>
#include <stdio.h>

/// Write a pre-formatted line to the unified logging system (os_log). Available in
/// ALL build configurations. In Release the rich MMLog apply trace routes here (see
/// MCDefs.h) so it is observable via:
///   log show --last 5m --predicate 'process == "Mousecape" OR process == "MousecapeHelper"'
/// without writing log files to users' disks. Declared `static inline` so every
/// translation unit gets its own copy — no separate .m and no per-target linking.
static inline __attribute__((format(printf, 1, 2)))
void MCLogToSystem(const char *format, ...) {
    if (!format) return;
    char buf[4096];
    va_list args;
    va_start(args, format);
    vsnprintf(buf, sizeof(buf), format, args);
    va_end(args);
    os_log(OS_LOG_DEFAULT, "%{public}s", buf);
}

#ifdef DEBUG

/// Initialize the logging system, create log file
void MCLoggerInit(void);

/// Write to log (outputs to both stdout and file)
void MCLoggerWrite(const char *format, ...) __attribute__((format(printf, 1, 2)));

/// Get the log file path
NSString *MCLoggerGetLogPath(void);

/// Close the log file
void MCLoggerClose(void);

#else

// No-op macros for Release builds
#define MCLoggerInit() ((void)0)
#define MCLoggerWrite(...) ((void)0)
#define MCLoggerGetLogPath() (nil)
#define MCLoggerClose() ((void)0)

#endif

#endif /* MCLogger_h */
