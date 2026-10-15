// nightkeysd: lights the keyboard backlight only when the built-in keyboard is used.
// The trackpad, mouse and external keyboards are ignored. Optionally stays off in bright rooms.
// Event-driven: uses no CPU while idle (no polling).
//
// Settings that macOS already has are used directly, so System Settings > Keyboard and NightKeys.app stay in sync:
//   - "Turn keyboard backlight off after inactivity"  -> how long the light stays on after the last key
//   - "Adjust keyboard brightness in low light"        -> stay off when the room is bright
//   - keyboard brightness (System Settings, Control Center) -> the level the light turns on at
// CoreBrightness notifies us when any of them changes. The only NightKeys-specific setting, the lux threshold,
// lives in the "io.github.fratayaydn.nightkeys" preferences domain; NightKeys.app posts SETTINGS_CHANGED_NOTIFICATION.
#import <Foundation/Foundation.h>
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

extern char **environ;

#define PREFS_DOMAIN                  CFSTR("io.github.fratayaydn.nightkeys")
#define SETTINGS_CHANGED_NOTIFICATION CFSTR("io.github.fratayaydn.nightkeys.SettingsChanged")
#define STATUS_CHANGED_NOTIFICATION   CFSTR("io.github.fratayaydn.nightkeys.StatusChanged")
#define VERIFY_NOTIFICATION           CFSTR("io.github.fratayaydn.nightkeys.VerifyPermission")

// NightKeys's own setting (written by the app).
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
#define KEY_STATUS_LEVEL      CFSTR("StatusUserBrightness")  // the level the user picked (0 = keep the light off)

@interface NSObject (KeyboardBrightnessClient)
- (id)copyKeyboardBacklightIDs;
- (BOOL)isKeyboardBuiltIn:(unsigned long long)k;
- (double)idleDimTimeForKeyboard:(unsigned long long)k;
- (BOOL)isAutoBrightnessEnabledForKeyboard:(unsigned long long)k;
- (void)registerNotificationForKeys:(NSArray *)keys keyboardID:(unsigned long long)k block:(void (^)(id key, id value))block;
- (float)brightnessForKeyboard:(unsigned long long)k;
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

static const int kFadeInMs = 150, kFadeOutMs = 1000;
static const double kLuxRecheckSeconds = 15;  // while typing, read the light sensor at most this often
static double gTimeout = DEFAULT_TIMEOUT;  // 0 = never turn off
static BOOL gAmbientEnabled = YES;
static double gLuxLimit = DEFAULT_AMBIENT_LUX;
static id gClient, gDisplay;
static unsigned long long gKbd;
static float gLevel = 0.5;          // user's brightness level
static BOOL gLit = NO;              // is the light currently on
static BOOL gSession = NO;          // is a typing session active (< gTimeout since last key)
static CFAbsoluteTime gLastKey;
static CFAbsoluteTime gLuxCheckedAt;  // when the light sensor was last read for the current session
static float gSetLevel = -1;        // brightness we set last, to recognize our own change notifications
static CFAbsoluteTime gSetAt = 0;
static dispatch_source_t gTimer;
static io_connect_t gPMRoot;
static dispatch_source_t gBundleWatch;
static char gExecutable[PATH_MAX];  // our path inside NightKeys.app, to see if a new copy replaced it

#pragma mark - Settings and status

static double prefDouble(CFStringRef key, double fallback, double min, double max) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, PREFS_DOMAIN);
    double d = fallback;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberDoubleType, &d);
    if (v) CFRelease(v);
    return d < min ? min : d > max ? max : d;
}

static void loadSettings(void) {
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    gLuxLimit = prefDouble(KEY_AMBIENT_LUX, DEFAULT_AMBIENT_LUX, 0, 100000);
}

static void publishStatus(BOOL permission, BOOL keyboard) {
    CFPreferencesSetAppValue(KEY_STATUS_PERMISSION, permission ? kCFBooleanTrue : kCFBooleanFalse, PREFS_DOMAIN);
    CFPreferencesSetAppValue(KEY_STATUS_KEYBOARD, keyboard ? kCFBooleanTrue : kCFBooleanFalse, PREFS_DOMAIN);
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(), STATUS_CHANGED_NOTIFICATION, NULL, NULL, true);
}

// Let NightKeys.app show the user's level even while the light is off.
static void publishLevel(float level) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberFloatType, &level);
    CFPreferencesSetAppValue(KEY_STATUS_LEVEL, n, PREFS_DOMAIN);
    CFRelease(n);
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
}

static void settingsChanged(CFNotificationCenterRef c, void *observer, CFNotificationName name, const void *object, CFDictionaryRef info) {
    loadSettings();
}

#pragma mark - Light control

static double ambientLux(void) {
    NSNumber *lux = [gDisplay copyPropertyForKey:@"AggregatedLux"];
    return lux ? lux.doubleValue : -1;
}

static BOOL shouldLight(void) {
    if (!gAmbientEnabled) return YES;
    double lux = ambientLux();
    return lux < 0 || lux <= gLuxLimit;  // no sensor reading: behave as if dark
}

static void setLevel(float level, int fade_ms) {
    gSetLevel = level;
    gSetAt = CFAbsoluteTimeGetCurrent();
    [gClient setBrightness:level fadeSpeed:fade_ms commit:NO forKeyboard:gKbd];
}

static void lightOff(void) {
    float cur = [gClient brightnessForKeyboard:gKbd];
    if (cur > 0.01f && fabsf(cur - gLevel) > 0.01f) {  // the user adjusted it while lit: remember it
        gLevel = cur;
        publishLevel(gLevel);
    }
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

static void timerFired(void) {
    double remaining = gTimeout - (CFAbsoluteTimeGetCurrent() - gLastKey);
    if (remaining > 0.05) { armTimer(remaining); return; }
    gSession = NO;
    if (gLit) lightOff();
}

// During a long typing session the room may get brighter or darker: follow it.
static void recheckAmbient(void) {
    gLuxCheckedAt = gLastKey;
    if (!gAmbientEnabled || gLevel <= 0.01f) return;
    BOOL light = shouldLight();
    if (gLit && !light) {
        lightOff();
    } else if (!gLit && light) {
        setLevel(gLevel, kFadeInMs);
        gLit = YES;
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
    if (gLevel > 0.01f && shouldLight()) {
        setLevel(gLevel, kFadeInMs);
        gLit = YES;
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
        BOOL ours = fabsf(level - gSetLevel) < 0.01f || CFAbsoluteTimeGetCurrent() - gSetAt < (kFadeOutMs + 200) / 1000.0;
        if (ours) return;
        // The user picked a brightness: use it from now on, and keep it visible for a full timeout.
        // 0 means the user wants the light off, so typing must not turn it on either.
        gLevel = level;
        publishLevel(gLevel);
        if (level > 0.01f) {
            gLit = gSession = YES;
            gLastKey = CFAbsoluteTimeGetCurrent();
            armTimer(gTimeout);
        } else {
            gLit = NO;
        }
    }
}

static void hidCallback(void *ctx, IOReturn result, void *sender, IOHIDValueRef value) {
    IOHIDElementRef el = IOHIDValueGetElement(value);
    uint32_t page = IOHIDElementGetUsagePage(el), usage = IOHIDElementGetUsage(el);
    // 0x07 regular keys (0-3 are error/rollover codes), 0x0C media keys, 0xFF/0xFF00 fn key
    if ((page == kHIDPage_KeyboardOrKeypad && usage > 3 && usage != 0xFFFFFFFF) ||
        page == kHIDPage_Consumer || ((page == 0xFF || page == 0xFF00) && usage == 0x03))
        keyActivity();
}

// After sleep the system may restore its own backlight state; take control back.
static void powerCallback(void *ref, io_service_t service, natural_t msg, void *arg) {
    if (msg == kIOMessageCanSystemSleep || msg == kIOMessageSystemWillSleep) {
        IOAllowPowerChange(gPMRoot, (long)arg);
    } else if (msg == kIOMessageSystemHasPoweredOn) {
        [gClient suspendIdleDimming:YES forKeyboard:gKbd];
        if (!gLit) setLevel(0, 0);
    }
}

// Hand the system its own idle timer and brightness back. The level is committed, as System Settings does:
// an uncommitted level is dropped when this process exits, which would leave the backlight at 0.
static void giveBackControl(void) {
    float cur = gLit ? [gClient brightnessForKeyboard:gKbd] : 0;
    gSetLevel = cur > 0.01f ? cur : gLevel;
    gSetAt = CFAbsoluteTimeGetCurrent();
    [gClient setBrightness:gSetLevel fadeSpeed:kFadeInMs commit:YES forKeyboard:gKbd];
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
    Class cls = NSClassFromString(@"SMAppService");
    NSError *error = nil;
    if (![[cls agentServiceWithPlistName:AGENT_PLIST] unregisterAndReturnError:&error])
        fprintf(stderr, "nightkeysd: could not remove the login item: %s\n", error.localizedDescription.UTF8String);
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
    BOOL found = NO;
    for (NSNumber *n in [gClient copyKeyboardBacklightIDs]) {
        if ([gClient isKeyboardBuiltIn:n.unsignedLongLongValue]) { gKbd = n.unsignedLongLongValue; found = YES; break; }
    }
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
    IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOReturn r = IOHIDManagerOpen(hid, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) { fprintf(stderr, "nightkeysd: could not open keyboard (0x%x)\n", r); exit(1); }

    loadSettings();
    gTimeout = [gClient idleDimTimeForKeyboard:gKbd];
    gAmbientEnabled = [gClient isAutoBrightnessEnabledForKeyboard:gKbd];
    [gClient registerNotificationForKeys:@[ CB_IDLE_DIM_TIME, CB_AUTO_BRIGHTNESS, CB_BRIGHTNESS ] keyboardID:gKbd block:^(id key, id value) {
        dispatch_async(dispatch_get_main_queue(), ^{ systemSettingChanged(key, value); });
    }];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), NULL, settingsChanged,
                                    SETTINGS_CHANGED_NOTIFICATION, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), NULL, verifyRequested,
                                    VERIFY_NOTIFICATION, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    publishStatus(YES, YES);

    // Suspend the system's "turn off after x sec" timer; we are in control.
    [gClient suspendIdleDimming:YES forKeyboard:gKbd];
    float cur = [gClient brightnessForKeyboard:gKbd];
    CFPropertyListRef saved = CFPreferencesCopyAppValue(KEY_STATUS_LEVEL, PREFS_DOMAIN);
    if (saved && CFGetTypeID(saved) == CFNumberGetTypeID()) CFNumberGetValue(saved, kCFNumberFloatType, &gLevel);
    else if (cur > 0.01f) gLevel = cur;
    if (saved) CFRelease(saved);
    publishLevel(gLevel);

    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(gTimer, ^{ timerFired(); });
    dispatch_source_set_timer(gTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(gTimer);

    // Start lit; turn off when the timeout passes.
    gLit = gSession = YES;
    gLastKey = CFAbsoluteTimeGetCurrent();
    armTimer(gTimeout);

    IONotificationPortRef pmPort;
    io_object_t pmNotifier;
    gPMRoot = IORegisterForSystemPower(NULL, &pmPort, powerCallback, &pmNotifier);
    if (gPMRoot) CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(pmPort), kCFRunLoopCommonModes);

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
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW);
        gDisplay = [NSClassFromString(@"DisplayServicesClient") new];
        if (argc > 1 && !strcmp(argv[1], "--status")) {  // for scripts and debugging
            printf("ambient light: %.1f lux\n", ambientLux());
            return 0;
        }
        if (argc > 1 && !strcmp(argv[1], "--check"))  // fresh permission check, see permissionStillGranted()
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted ? 0 : 1;

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
