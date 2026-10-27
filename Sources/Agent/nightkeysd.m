// nightkeysd: lights the keyboard backlight only when the built-in keyboard is used.
// The trackpad, mouse and external keyboards are ignored. Optionally stays off in bright rooms.
// Event-driven: uses no CPU while idle (no polling).
//
// Settings that macOS already has are used directly, so System Settings > Keyboard and NightKeys.app stay in sync:
//   - "Turn keyboard backlight off after inactivity"  -> how long the light stays on after the last key
//   - "Adjust keyboard brightness in low light"        -> stay off when the room is bright
// CoreBrightness notifies us when these settings change. The level and lux threshold live in the
// "io.github.fratayaydn.nightkeys" preferences domain; NightKeys.app posts SETTINGS_CHANGED_NOTIFICATION.
#import <Foundation/Foundation.h>
#import <AppKit/NSWorkspace.h>
#import <CoreGraphics/CoreGraphics.h>
#import "Updater.h"
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/IOMessage.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#import "DiagnosticLog.h"

extern char **environ;

#define PREFS_DOMAIN                  CFSTR("io.github.fratayaydn.nightkeys")
#define SETTINGS_CHANGED_NOTIFICATION CFSTR("io.github.fratayaydn.nightkeys.SettingsChanged")
#define STATUS_CHANGED_NOTIFICATION   CFSTR("io.github.fratayaydn.nightkeys.StatusChanged")
#define VERIFY_NOTIFICATION           CFSTR("io.github.fratayaydn.nightkeys.VerifyPermission")

// NightKeys settings (Level is also saved after manual macOS adjustments).
#define KEY_LEVEL            CFSTR("Level")
#define KEY_AMBIENT_LUX      CFSTR("AmbientThresholdLux")  // "bright" means above this
#define DEFAULT_AMBIENT_LUX  3.0
#define DEFAULT_TIMEOUT      10.0

// CoreBrightness keys for the macOS keyboard backlight settings.
#define CB_IDLE_DIM_TIME     @"KeyboardBacklightIdleDimTime"  // seconds; 0 = never
#define CB_AUTO_BRIGHTNESS   @"KeyboardBacklightABEnabled"
#define CB_BRIGHTNESS        @"KeyboardBacklightBrightness"

// Status keys (written by the agent, shown by the app).
#define KEY_STATUS_PERMISSION CFSTR("StatusInputMonitoringGranted")
#define KEY_STATUS_KEYBOARD   CFSTR("StatusKeyboardFound")
#define KEY_STATUS_LEVEL      CFSTR("StatusUserBrightness")  // read-only legacy value for migration

@interface NSObject (KeyboardBrightnessClient)
- (id)copyKeyboardBacklightIDs;
- (BOOL)isKeyboardBuiltIn:(unsigned long long)k;
- (double)idleDimTimeForKeyboard:(unsigned long long)k;
- (BOOL)isAutoBrightnessEnabledForKeyboard:(unsigned long long)k;
- (void)registerNotificationForKeys:(NSArray *)keys keyboardID:(unsigned long long)k block:(void (^)(id key, id value))block;
- (BOOL)setBrightness:(float)b fadeSpeed:(int)f commit:(BOOL)c forKeyboard:(unsigned long long)k;
- (BOOL)suspendIdleDimming:(BOOL)s forKeyboard:(unsigned long long)k;
@end

@interface NSObject (DisplayServicesClient)
- (id)copyPropertyForKey:(id)key;
@end

// ServiceManagement is loaded only when the app is removed, so it costs no memory while running.
@interface NSObject (SMAppService)
+ (id)agentServiceWithPlistName:(NSString *)name;
- (BOOL)unregisterAndReturnError:(NSError **)error;
@end
#define AGENT_PLIST @"io.github.fratayaydn.nightkeys.agent.plist"
#define UPDATER_PLIST @"io.github.fratayaydn.nightkeys.updater.plist"

static const int kFadeInMs = 150, kFadeOutMs = 1000;
static const double kLuxRecheckSeconds = 15;  // while typing, read the light sensor at most this often
static double gTimeout = DEFAULT_TIMEOUT;  // 0 = never turn off
static BOOL gAmbientEnabled = YES;
static double gLuxLimit = DEFAULT_AMBIENT_LUX;
static id gClient, gDisplay;
static unsigned long long gKbd;
static float gLevel = 0.5;          // user's brightness level
static float gPreferencesLevel = 0.5;  // last Level read or written, separate from a pending manual ramp
static BOOL gLit = NO;              // is the light currently on
static BOOL gSession = NO;          // is a typing session active (< gTimeout since last key)
static CFAbsoluteTime gLastKey;
static CFAbsoluteTime gLuxCheckedAt;  // when the light sensor was last read for the current session
static float gSetLevel = -1;        // brightness we set last, to recognize our own change notifications
static CFAbsoluteTime gSetAt = 0;
static dispatch_source_t gTimer;
static CFAbsoluteTime gLastTransition, gLastBrightnessKey;
static BOOL gManualPending;
static float gManualLevel;
static CFAbsoluteTime gManualAt;
static dispatch_source_t gManualTimer;
static io_connect_t gPMRoot;
static dispatch_source_t gBundleWatch;
static char gExecutable[PATH_MAX];  // our path inside NightKeys.app, to see if a new copy replaced it

#pragma mark - Settings and status

typedef enum {
    BrightnessManualLevel, BrightnessManualKey, BrightnessManualNormal,
    BrightnessAutomaticDisplay, BrightnessAutomaticLock, BrightnessAutomaticTransition
} BrightnessClass;

// No system calls or mutable state: the key window takes priority over transition guards.
static BrightnessClass classifyBrightness(double now, double lastKey, double lastTransition,
                                           BOOL displayAsleep, BOOL screenLocked) {
    if (lastKey > 0 && now >= lastKey && now - lastKey <= 3) return BrightnessManualKey;
    if (displayAsleep) return BrightnessAutomaticDisplay;
    if (screenLocked) return BrightnessAutomaticLock;
    if (now - lastTransition <= 10) return BrightnessAutomaticTransition;
    return BrightnessManualNormal;
}

static BOOL sameBrightnessRamp(double now, double previous) {
    return now >= previous && now - previous <= 1;
}

static BOOL illuminationKey(uint32_t page, uint32_t usage) {
    // Consumer keyboard illumination, and AppleVendorTopCase IlluminationUp/Down.
    // Display brightness (consumer 0x6f/0x70) is deliberately excluded.
    return (page == kHIDPage_Consumer && (usage == 0x79 || usage == 0x7a))
        || (page == 0xff && (usage == 0x08 || usage == 0x09));
}

static BOOL noteBrightnessKey(uint32_t page, uint32_t usage, CFIndex pressed) {
    BOOL brightness = illuminationKey(page, usage);
    if (brightness && pressed > 0) gLastBrightnessKey = CFAbsoluteTimeGetCurrent();
    return brightness;
}

static void cancelManualSave(void) {
    gManualPending = NO;
    if (gManualTimer)
        dispatch_source_set_timer(gManualTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
}

static void saveManualLevel(void) {
    if (!gManualPending) return;
    float level = gManualLevel;
    cancelManualSave();
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberFloatType, &level);
    CFPreferencesSetAppValue(KEY_LEVEL, value, PREFS_DOMAIN);
    CFRelease(value);
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    gPreferencesLevel = level;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(),
                                         STATUS_CHANGED_NOTIFICATION, NULL, NULL, true);
}

static void manualTimerFired(void) {
    if (!gManualPending) return;
    double remaining = 1 - (CFAbsoluteTimeGetCurrent() - gManualAt);
    if (remaining > 0) {
        dispatch_source_set_timer(gManualTimer,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, 0);
    } else saveManualLevel();
}

static void queueManualLevel(float level, CFAbsoluteTime now) {
    if (gManualPending && !sameBrightnessRamp(now, gManualAt)) saveManualLevel();
    gManualPending = YES;
    gManualLevel = level;
    gManualAt = now;
    if (!gManualTimer) {
        gManualTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(gManualTimer, ^{ manualTimerFired(); });
        dispatch_resume(gManualTimer);
    }
    dispatch_source_set_timer(gManualTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              DISPATCH_TIME_FOREVER, 0);
}

static double prefDouble(CFStringRef key, double fallback, double min, double max) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, PREFS_DOMAIN);
    double d = fallback;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberDoubleType, &d);
    if (v) CFRelease(v);
    return d < min ? min : d > max ? max : d;
}

// Until the window persists the migration, use the same fallback without writing preferences here.
static float readLevel(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(KEY_LEVEL, PREFS_DOMAIN);
    if (value) {
        CFRelease(value);
        return (float)prefDouble(KEY_LEVEL, 0.5, 0, 1);
    }
    double legacy = prefDouble(KEY_STATUS_LEVEL, 0.5, 0, 1);
    return legacy > 0.01 ? (float)legacy : 0.5f;
}

static void loadSettings(void) {
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    gLuxLimit = prefDouble(KEY_AMBIENT_LUX, DEFAULT_AMBIENT_LUX, 0, 100000);
    gLevel = gPreferencesLevel = readLevel();
    DIAG(@"preferences Level=%.3f", gLevel);
}

static void publishStatus(BOOL permission, BOOL keyboard) {
    CFPreferencesSetAppValue(KEY_STATUS_PERMISSION, permission ? kCFBooleanTrue : kCFBooleanFalse, PREFS_DOMAIN);
    CFPreferencesSetAppValue(KEY_STATUS_KEYBOARD, keyboard ? kCFBooleanTrue : kCFBooleanFalse, PREFS_DOMAIN);
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(), STATUS_CHANGED_NOTIFICATION, NULL, NULL, true);
}

#pragma mark - Light control

static double ambientLux(void) {
    NSNumber *lux = [gDisplay copyPropertyForKey:@"AggregatedLux"];
    return lux ? lux.doubleValue : -1;
}

static void systemSettingChanged(NSString *key, id value);

static BOOL builtInKeyboardID(unsigned long long *keyboard) {
    for (NSNumber *n in [gClient copyKeyboardBacklightIDs]) {
        if ([gClient isKeyboardBuiltIn:n.unsignedLongLongValue]) {
            *keyboard = n.unsignedLongLongValue;
            return YES;
        }
    }
    return NO;
}

static void registerKeyboardNotifications(void) {
    unsigned long long keyboard = gKbd;
    [gClient registerNotificationForKeys:@[ CB_IDLE_DIM_TIME, CB_AUTO_BRIGHTNESS, CB_BRIGHTNESS ]
                            keyboardID:keyboard block:^(id key, id value) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (keyboard == gKbd) systemSettingChanged(key, value);
        });
    }];
}

static void refreshKeyboard(void) {
    unsigned long long current = 0;
    BOOL found = builtInKeyboardID(&current);
    if (!found) DIAG(@"keyboard ID re-resolution: not found (old=%llu)", gKbd);
    else if (current == gKbd) DIAG(@"keyboard ID re-resolution: unchanged %llu", current);
    else DIAG(@"keyboard ID re-resolution: changed %llu->%llu", gKbd, current);
    if (found && current != gKbd) {
        gKbd = current;
        registerKeyboardNotifications();
        [gClient suspendIdleDimming:YES forKeyboard:gKbd];
    }
}

static BOOL writeBrightness(float level, int fade, BOOL commit) {
    for (int attempt = 0; attempt < 2; attempt++) {
        gSetLevel = level;
        gSetAt = CFAbsoluteTimeGetCurrent();
        BOOL result = [gClient setBrightness:level fadeSpeed:fade commit:commit forKeyboard:gKbd];
        DIAG(@"setBrightness result=%d keyboard ID=%llu level=%.3f", result, gKbd, level);
        if (attempt == 1) DIAG(@"setBrightness retry result=%d keyboard ID=%llu", result, gKbd);
        if (result) return YES;
        if (attempt == 0) refreshKeyboard();
    }
    return NO;
}

static BOOL setLevel(float level, int fade_ms) {
    return writeBrightness(level, fade_ms, NO);
}

static BOOL shouldLight(void) {
    if (!gAmbientEnabled) return YES;
    double lux = ambientLux();
    return lux < 0 || lux <= gLuxLimit;  // no sensor reading: behave as if dark
}

#ifdef NIGHTKEYS_DIAGNOSTIC_LOG
static BOOL diagnosticSessionShouldLight(void) {
    double lux = ambientLux();
    BOOL light = gLevel > 0 && (!gAmbientEnabled || lux < 0 || lux <= gLuxLimit);
    DIAG(@"key session start category=%@ AggregatedLux=%.3f threshold=%.3f ambient enabled=%d level=%.3f decision=%@",
         gDiagnosticCategory, lux, gLuxLimit, gAmbientEnabled, gLevel, light ? @"light" : @"stay off");
    return light;
}
#endif

static void lightOff(void) {
    DIAG(@"lightOff");
    setLevel(0, kFadeOutMs);
    gLit = NO;
}

static void armTimer(double seconds) {
    if (gTimeout <= 0) {  // "Never": stay lit until the setting changes
        dispatch_source_set_timer(gTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
        return;
    }
    dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 200 * NSEC_PER_MSEC);
}

static void startManualSession(float level, CFAbsoluteTime now) {
    gLastKey = gLuxCheckedAt = now;
    gSession = YES;
    gLit = level > 0;
    armTimer(gTimeout);
}

static void settingsChanged(CFNotificationCenterRef c, void *observer, CFNotificationName name, const void *object, CFDictionaryRef info) {
    float previous = gLevel, previousPreference = gPreferencesLevel;
    cancelManualSave();  // The window's newer direct write wins over a pending external ramp.
    loadSettings();
    if (gLevel == previousPreference && gLevel == previous) return;
    float preview = gLevel > 0.01f ? gLevel : 0;
    BOOL lit = setLevel(preview, kFadeInMs);
    startManualSession(preview, CFAbsoluteTimeGetCurrent());
    gLit = preview > 0 && lit;
}

static BOOL displayIsAsleep(void) {
    CGDirectDisplayID main = CGMainDisplayID();
    BOOL asleep = CGDisplayIsAsleep(main);
    if (CGDisplayIsBuiltin(main)) return asleep;
    // Include sleeping and mirrored built-in displays when an external display is primary.
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(0, NULL, &count) != kCGErrorSuccess || !count) return asleep;
    CGDirectDisplayID *displays = calloc(count, sizeof(*displays));
    if (!displays) return asleep;
    if (CGGetOnlineDisplayList(count, displays, &count) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < count; i++) {
            if (CGDisplayIsBuiltin(displays[i]) && CGDisplayIsAsleep(displays[i])) asleep = YES;
        }
    }
    free(displays);
    return asleep;
}

static BOOL screenIsLocked(void) {
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    return [session[@"CGSSessionScreenIsLocked"] boolValue];
}

static void timerFired(void) {
    DIAG(@"timer fired");
    double remaining = gTimeout - (CFAbsoluteTimeGetCurrent() - gLastKey);
    if (remaining > 0.05) { armTimer(remaining); return; }
    gSession = NO;
    if (gLit) lightOff();
}

// During a long typing session the room may get brighter or darker: follow it.
static void recheckAmbient(void) {
    gLuxCheckedAt = gLastKey;
    if (!gAmbientEnabled || gLevel <= 0) {
        DIAG(@"recheckAmbient result=skipped ambient enabled=%d level=%.3f", gAmbientEnabled, gLevel);
        return;
    }
    BOOL light = shouldLight();
    DIAG(@"recheckAmbient result=%@", light ? @"light" : @"stay off");
    if (gLit && !light) {
        lightOff();
    } else if (!gLit && light) {
        gLit = setLevel(gLevel, kFadeInMs);
    }
}

static void keyActivity(void) {
    // Per-key work: one timestamp and one comparison. The light sensor is read when a typing session starts and
    // at most every kLuxRecheckSeconds while it lasts, only on a key press: never on a timer.
    gLastKey = CFAbsoluteTimeGetCurrent();
    if (gSession) {
        if (gLastKey - gLuxCheckedAt >= kLuxRecheckSeconds) recheckAmbient();
        return;
    }
    gSession = YES;
    gLuxCheckedAt = gLastKey;
    if (SESSION_SHOULD_LIGHT()) {
        gLit = setLevel(gLevel, kFadeInMs);
    }
    armTimer(gTimeout);
}

// A macOS keyboard backlight setting changed (System Settings, Control Center or NightKeys.app).
static void systemSettingChanged(NSString *key, id value) {
    if ([key isEqualToString:CB_IDLE_DIM_TIME]) {
        gTimeout = [value doubleValue];
        if (gSession) armTimer(gTimeout - (CFAbsoluteTimeGetCurrent() - gLastKey));
    } else if ([key isEqualToString:CB_AUTO_BRIGHTNESS]) {
        gAmbientEnabled = [value boolValue];
    } else if ([key isEqualToString:CB_BRIGHTNESS]) {
        float level = [value floatValue];
        if (!isfinite(level)) return;
        level = fminf(fmaxf(level, 0), 1);
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        BOOL ours = fabsf(level - gSetLevel) < 0.0001f
            && now - gSetAt <= (kFadeOutMs + 200) / 1000.0;
        if (ours) return;
        // The window saves Level before sending either notification. Observe that write even if
        // CoreBrightness reaches us before the distributed settings notification.
        CFPreferencesAppSynchronize(PREFS_DOMAIN);
        if (readLevel() != gPreferencesLevel) settingsChanged(NULL, NULL, NULL, NULL, NULL);
        now = CFAbsoluteTimeGetCurrent();
        BOOL matchesLevel = fabsf(level - gLevel) <= 0.01f;
        BOOL displayAsleep = displayIsAsleep(), screenLocked = screenIsLocked();
        BrightnessClass classification = matchesLevel ? BrightnessManualLevel
            : classifyBrightness(now, gLastBrightnessKey, gLastTransition, displayAsleep, screenLocked);
        BOOL manual = classification == BrightnessManualLevel || classification == BrightnessManualKey
            || classification == BrightnessManualNormal;
#ifdef NIGHTKEYS_DIAGNOSTIC_LOG
        NSString *reason = classification == BrightnessManualLevel ? @"matches configured Level"
            : classification == BrightnessManualKey ? @"brightness key within 3 seconds"
            : classification == BrightnessManualNormal ? @"awake and unlocked for more than 10 seconds"
            : classification == BrightnessAutomaticDisplay ? @"display asleep"
            : classification == BrightnessAutomaticLock ? @"screen locked" : @"transition within 10 seconds";
        DIAG(@"external brightness value=%.3f class=%@ reason=%@ live display asleep=%d screen locked=%d",
             level, manual ? @"manual" : @"automatic", reason, displayAsleep, screenLocked);
#endif
        if (manual) {
            if (!matchesLevel) {
                queueManualLevel(level, now);
                gLevel = level;
            }
            startManualSession(level, now);
        } else {
            float restore = gSession && gLit ? gLevel : 0;
            DIAG(@"external brightness restore action=%@ level=%.3f",
                 gSession && gLit ? @"saved level" : @"keep dark", restore);
            setLevel(restore, 0);
        }
    }
}

static void hidCallback(void *ctx, IOReturn result, void *sender, IOHIDValueRef value) {
    IOHIDElementRef el = IOHIDValueGetElement(value);
    uint32_t page = IOHIDElementGetUsagePage(el), usage = IOHIDElementGetUsage(el);
    BOOL brightness = noteBrightnessKey(page, usage, IOHIDValueGetIntegerValue(value));
    // 0x07 regular keys (0-3 are error/rollover codes), 0x0C media keys, 0xFF/0xFF00 fn key
    if ((page == kHIDPage_KeyboardOrKeypad && usage > 3 && usage != 0xFFFFFFFF) ||
        page == kHIDPage_Consumer || brightness || ((page == 0xFF || page == 0xFF00) && usage == 0x03))
    {
        DIAG_CATEGORY(page == kHIDPage_KeyboardOrKeypad ? @"keyboard key" :
                      page == kHIDPage_Consumer ? @"media key" : @"fn");
        keyActivity();
    }
}

#ifdef NIGHTKEYS_DIAGNOSTIC_LOG
static void keyboardMatched(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef device) {
    DIAG(@"built-in keyboard device matched");
}

static void keyboardRemoved(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef device) {
    DIAG(@"built-in keyboard device removed");
}
#endif

// After sleep the system may restore its own backlight state; take control back.
static void backlightDidWake(void) {
    refreshKeyboard();
    [gClient suspendIdleDimming:YES forKeyboard:gKbd];
    if (!gLit) setLevel(0, 0);
}

static void noteTransition(void) {
    saveManualLevel();
    gLastTransition = CFAbsoluteTimeGetCurrent();
}

static void screenLockChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                              const void *object, CFDictionaryRef info) {
    noteTransition();
    DIAG(@"screen %@", CFEqual(name, CFSTR("com.apple.screenIsLocked")) ? @"lock" : @"unlock");
}

static void registerDisplayWakeNotification(NSNotificationCenter *center) {
    [center addObserverForName:NSWorkspaceScreensDidWakeNotification object:nil queue:NSOperationQueue.mainQueue
                   usingBlock:^(NSNotification *note) {
        DIAG(@"display wake");
        noteTransition();
        backlightDidWake();
    }];
    [center addObserverForName:NSWorkspaceScreensDidSleepNotification object:nil queue:NSOperationQueue.mainQueue
                   usingBlock:^(NSNotification *note) {
        noteTransition();
        DIAG(@"display sleep");
    }];
}

static void powerCallback(void *ref, io_service_t service, natural_t msg, void *arg) {
    if (msg == kIOMessageSystemWillSleep) DIAG(@"power will sleep");
    else if (msg == kIOMessageSystemHasPoweredOn) DIAG(@"power has powered on");
    else DIAG(@"power message 0x%x", msg);
    if (msg == kIOMessageCanSystemSleep || msg == kIOMessageSystemWillSleep) {
        if (msg == kIOMessageSystemWillSleep) {
            noteTransition();
        }
        IOAllowPowerChange(gPMRoot, (long)arg);
    } else if (msg == kIOMessageSystemHasPoweredOn) {
        noteTransition();
        backlightDidWake();
    }
}

// Hand the system its own idle timer and brightness back. The level is committed, as System Settings does:
// an uncommitted level is dropped when this process exits, which would leave the backlight at 0.
static void giveBackControl(void) {
    saveManualLevel();
    writeBrightness(gLevel > 0 ? gLevel : 0.5f, kFadeInMs, YES);
    [gClient suspendIdleDimming:NO forKeyboard:gKbd];
}

// Before exiting: give the backlight back and let CoreBrightness finish with it.
static void giveBackControlAndExit(int code) {
    giveBackControl();
    usleep(300 * 1000);
    exit(code);
}

static void restoreAndExit(void) {
    giveBackControlAndExit(0);
}

static BOOL selfPath(char *path, uint32_t size) {
    return _NSGetExecutablePath(path, &size) == 0;
}

// macOS decides Input Monitoring once per process image, so this process would not notice the permission
// being taken away. A short-lived copy of ourselves (`nightkeysd --check`) asks afresh.
static BOOL permissionStillGranted(void) {
    char path[PATH_MAX];
    if (!selfPath(path, sizeof(path))) return YES;
    char *const args[] = { path, "--check", NULL };
    pid_t pid;
    if (posix_spawn(&pid, path, NULL, NULL, args, environ) != 0) return YES;
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

// Called when NightKeys.app asks (window opened, "Check Again"): if the permission was taken away, give the
// backlight back to macOS and start over in the "waiting for permission" state.
static void verifyPermission(void) {
    if (permissionStillGranted()) return;
    fprintf(stderr, "nightkeysd: Input Monitoring permission was removed\n");
    giveBackControl();
    char path[PATH_MAX];
    if (!selfPath(path, sizeof(path))) exit(1);
    char *const args[] = { path, NULL };
    execv(path, args);
    exit(1);  // exec failed: launchd restarts us
}

// Remove our login item, as turning off "Enable NightKeys" does, so nothing is left in Login Items and
// launchd does not start another copy of NightKeys at the next login.
static void unregisterLoginItem(void) {
    if (!dlopen("/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement", RTLD_NOW)) return;
    // Remove the updater first: unregistering the main job can stop this process immediately.
    for (NSString *plist in @[UPDATER_PLIST, AGENT_PLIST]) {
        NSError *error = nil;
        if (![[NSClassFromString(@"SMAppService") agentServiceWithPlistName:plist] unregisterAndReturnError:&error])
            fprintf(stderr, "nightkeysd: could not remove %s: %s\n", plist.UTF8String, error.localizedDescription.UTF8String);
    }
}

// NightKeys.app was moved to the Trash or replaced by an update. An update puts a new copy at the same path
// within moments: exit with an error so launchd starts the new agent. Otherwise the app is gone: give the
// backlight back and exit for good (a successful exit is not restarted).
static void appMoved(void) {
    dispatch_source_cancel(gBundleWatch);
    for (int i = 0; i < 10; i++) {
        sleep(1);
        struct stat st;
        if (stat(gExecutable, &st) == 0) {
            fprintf(stderr, "nightkeysd: NightKeys.app was updated, restarting\n");
            giveBackControlAndExit(1);
        }
    }
    fprintf(stderr, "nightkeysd: NightKeys.app was removed, exiting\n");
    giveBackControl();
    usleep(300 * 1000);
    unregisterLoginItem();  // launchd may stop us right here; the backlight is already handed back
    exit(0);
}

// Watch the app bundle through the kernel's event queue: no polling, no wakeups until it moves.
static void watchAppBundle(void) {
    char path[PATH_MAX], resolved[PATH_MAX];
    if (!selfPath(path, sizeof(path)) || !realpath(path, resolved)) return;
    strlcpy(gExecutable, resolved, sizeof(gExecutable));
    char *contents = strstr(resolved, "/Contents/MacOS/");
    if (!contents) return;  // not running from an app bundle
    *contents = 0;
    int fd = open(resolved, O_EVTONLY);
    if (fd < 0) return;
    gBundleWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd,
                                          DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE,
                                          dispatch_get_main_queue());
    dispatch_source_set_event_handler(gBundleWatch, ^{ appMoved(); });
    dispatch_source_set_cancel_handler(gBundleWatch, ^{ close(fd); });
    dispatch_resume(gBundleWatch);
}

static void verifyRequested(CFNotificationCenterRef c, void *observer, CFNotificationName name, const void *object, CFDictionaryRef info) {
    verifyPermission();
}

// While waiting for permission: start over in a fresh process image, which sees the current permission.
static void recheckRequested(CFNotificationCenterRef c, void *observer, CFNotificationName name, const void *object, CFDictionaryRef info) {
    char path[PATH_MAX];
    if (!selfPath(path, sizeof(path))) return;
    char *const args[] = { path, NULL };
    execv(path, args);
}

// Everything that needs Input Monitoring: find the keyboard, listen to it and take over the backlight.
static void start(void) {
    if (!dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)) exit(2);
    Class cls = NSClassFromString(@"KeyboardBrightnessClient");
    if (!cls) exit(2);
    gClient = [cls new];
    BOOL found = builtInKeyboardID(&gKbd);
    if (!found) {
        publishStatus(YES, NO);
        fprintf(stderr, "nightkeysd: no built-in backlit keyboard found\n");
        sleep(60);  // nothing to do on this Mac; avoid a fast launchd restart loop
        exit(2);
    }

    // Listen to the built-in keyboard device only; the trackpad is a separate HID device, so its events never arrive.
    IOHIDManagerRef hid = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    IOHIDManagerSetDeviceMatching(hid, (__bridge CFDictionaryRef)@{
        @kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop),
        @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Keyboard),
        @kIOHIDBuiltInKey: @YES,
    });
    IOHIDManagerRegisterInputValueCallback(hid, hidCallback, NULL);
#ifdef NIGHTKEYS_DIAGNOSTIC_LOG
    IOHIDManagerRegisterDeviceMatchingCallback(hid, keyboardMatched, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(hid, keyboardRemoved, NULL);
#endif
    IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOReturn r = IOHIDManagerOpen(hid, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) { fprintf(stderr, "nightkeysd: could not open keyboard (0x%x)\n", r); exit(1); }

    loadSettings();
    gTimeout = [gClient idleDimTimeForKeyboard:gKbd];
    gAmbientEnabled = [gClient isAutoBrightnessEnabledForKeyboard:gKbd];
    registerKeyboardNotifications();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), NULL, settingsChanged,
                                    SETTINGS_CHANGED_NOTIFICATION, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), NULL, verifyRequested,
                                    VERIFY_NOTIFICATION, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    publishStatus(YES, YES);

    // Suspend the system's "turn off after x sec" timer; we are in control.
    [gClient suspendIdleDimming:YES forKeyboard:gKbd];
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(gTimer, ^{ timerFired(); });
    dispatch_source_set_timer(gTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(gTimer);

    // Preview the configured level at startup; turn off when the timeout passes.
    BOOL lit = setLevel(gLevel, kFadeInMs);
    gLit = gLevel > 0 && lit;
    gSession = YES;
    gLastKey = CFAbsoluteTimeGetCurrent();
    armTimer(gTimeout);

    IONotificationPortRef pmPort;
    io_object_t pmNotifier;
    gPMRoot = IORegisterForSystemPower(NULL, &pmPort, powerCallback, &pmNotifier);
    if (gPMRoot) CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(pmPort), kCFRunLoopCommonModes);

    registerDisplayWakeNotification(NSWorkspace.sharedWorkspace.notificationCenter);
    gLastTransition = CFAbsoluteTimeGetCurrent();
    CFNotificationCenterRef distributed = CFNotificationCenterGetDistributedCenter();
    CFNotificationCenterAddObserver(distributed, NULL, screenLockChanged, CFSTR("com.apple.screenIsLocked"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(distributed, NULL, screenLockChanged, CFSTR("com.apple.screenIsUnlocked"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    int sigs[] = { SIGINT, SIGTERM, SIGHUP };
    for (int i = 0; i < 3; i++) {
        int sig = sigs[i];
        signal(sig, SIG_IGN);
        dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sig, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(s, ^{ restoreAndExit(); });
        dispatch_resume(s);
        CFBridgingRetain(s);
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && !strcmp(argv[1], "--update-check")) {
            BOOL force = NO, install = NO;
            for (int i = 2; i < argc; i++) {
                if (!strcmp(argv[i], "--force")) force = YES;
                else if (!strcmp(argv[i], "--install")) install = YES;
                else return 1;
            }
            return updaterRun(force, install);
        }
#ifdef NIGHTKEYS_DIAGNOSTIC_LOG
        if (argc > 1 && !strcmp(argv[1], "--log")) return diagnosticPrint();
#endif
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW);
        gDisplay = [NSClassFromString(@"DisplayServicesClient") new];
        if (argc > 1 && !strcmp(argv[1], "--status")) {  // for scripts and debugging
            printf("ambient light: %.1f lux\n", ambientLux());
            return 0;
        }
        if (argc > 1 && !strcmp(argv[1], "--check"))  // fresh permission check, see permissionStillGranted()
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted ? 0 : 1;

#ifdef NIGHTKEYS_DIAGNOSTIC_LOG
        DIAG(@"agent start");
        CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), NULL, diagnosticRequested,
                                        LOG_REQUEST, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
#endif
        watchAppBundle();
        if (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted) {
            start();
        } else {
            // Wait idle until NightKeys.app asks for a new check (when its window opens, or "Check Again").
            // macOS decides Input Monitoring once per process image, so the check re-execs us; see verifyPermission().
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
            publishStatus(NO, NO);
            fprintf(stderr, "nightkeysd: waiting for Input Monitoring permission (allow it in System Settings, then click Check Again in the NightKeys window)\n");
            CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), NULL, recheckRequested,
                                            VERIFY_NOTIFICATION, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }

        CFRunLoopRun();
    }
    return 0;
}
