// Exercise backlight recovery with private fixtures and simulated wake notifications.
#include <assert.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

static CGDirectDisplayID testMainDisplay = 10, testBuiltInDisplay = 10;
static BOOL testMainAsleep, testBuiltInAsleep;
static NSUInteger displayReads, sessionReads;
static NSDictionary *testSession;
static CGDirectDisplayID testMainDisplayID(void) { return testMainDisplay; }
static boolean_t testDisplayIsBuiltin(CGDirectDisplayID display) { return display == testBuiltInDisplay; }
static boolean_t testDisplayIsAsleep(CGDirectDisplayID display) {
    displayReads++;
    return display == testMainDisplay ? testMainAsleep : testBuiltInAsleep;
}
static CGError testOnlineDisplays(uint32_t capacity, CGDirectDisplayID *displays, uint32_t *count) {
    CGDirectDisplayID online[] = {testMainDisplay, testBuiltInDisplay};
    uint32_t available = testMainDisplay == testBuiltInDisplay || !testBuiltInDisplay ? 1 : 2;
    *count = displays ? MIN(capacity, available) : available;
    if (displays) memcpy(displays, online, *count * sizeof(*displays));
    return kCGErrorSuccess;
}
static CFDictionaryRef testCopySession(void) {
    sessionReads++;
    return testSession ? CFBridgingRetain(testSession) : NULL;
}

static NSMutableDictionary *testPreferences;
static CFPropertyListRef testCopyAppValue(CFStringRef key, CFStringRef domain) {
    assert(CFEqual(domain, CFSTR("io.github.fratayaydn.nightkeys")));
    id value = testPreferences[(__bridge NSString *)key];
    return value ? CFBridgingRetain(value) : NULL;
}
static NSUInteger preferenceWrites;
static void testSetAppValue(CFStringRef key, CFPropertyListRef value, CFStringRef domain) {
    preferenceWrites++;
    testPreferences[(__bridge NSString *)key] = (__bridge id)value;
}
static Boolean testSynchronize(CFStringRef domain) { return true; }
static NSUInteger statusPublications;
static void testPostNotification(CFNotificationCenterRef center, CFNotificationName name, const void *object,
                                 CFDictionaryRef info, Boolean immediately) {
    if (center == CFNotificationCenterGetLocalCenter()) {
        CFNotificationCenterPostNotification(center, name, object, info, immediately);
        return;
    }
    statusPublications++;
}
#define CFNotificationCenterPostNotification testPostNotification
#define CFPreferencesCopyAppValue testCopyAppValue
#define CFPreferencesAppSynchronize testSynchronize
#define CFPreferencesSetAppValue testSetAppValue
#define CGMainDisplayID testMainDisplayID
#define CGDisplayIsBuiltin testDisplayIsBuiltin
#define CGDisplayIsAsleep testDisplayIsAsleep
#define CGGetOnlineDisplayList testOnlineDisplays
#define CGSessionCopyCurrentDictionary testCopySession
#define main agentMain
#import "../Sources/Agent/nightkeysd.m"
#undef main

typedef void (^SettingCallback)(id, id);

@interface BacklightFixture : NSObject
@property unsigned long long currentID;
@property NSUInteger resolutions;
@property BOOL failAlways;
@property float liveBrightness;
@property NSUInteger brightnessReads;
@property BOOL idleSuspended;
@property NSUInteger failuresRemaining;
@property NSMutableArray<NSDictionary *> *writes;
@property NSMutableArray<NSNumber *> *registrations;
@property NSMutableArray<NSNumber *> *suspensions;
@property NSMutableArray<SettingCallback> *callbacks;
@end

@implementation BacklightFixture
- (instancetype)init {
    if ((self = [super init])) {
        _currentID = 2;
        _writes = [NSMutableArray new];
        _registrations = [NSMutableArray new];
        _suspensions = [NSMutableArray new];
        _callbacks = [NSMutableArray new];
    }
    return self;
}
- (id)copyKeyboardBacklightIDs {
    self.resolutions++;
    // The external keyboard must never be selected.
    return self.currentID ? @[@99, @(self.currentID)] : @[@99];
}
- (BOOL)isKeyboardBuiltIn:(unsigned long long)keyboard { return keyboard == self.currentID; }
- (void)registerNotificationForKeys:(NSArray *)keys keyboardID:(unsigned long long)keyboard
                            block:(SettingCallback)block {
    assert(keyboard == self.currentID);
    assert(([keys isEqualToArray:@[CB_IDLE_DIM_TIME, CB_AUTO_BRIGHTNESS, CB_BRIGHTNESS]]));
    [self.registrations addObject:@(keyboard)];
    [self.callbacks addObject:[block copy]];
}
- (BOOL)suspendIdleDimming:(BOOL)suspend forKeyboard:(unsigned long long)keyboard {
    self.idleSuspended = suspend;
    [self.suspensions addObject:@(keyboard)];
    return YES;
}
- (float)brightnessForKeyboard:(unsigned long long)keyboard {
    self.brightnessReads++;
    return self.liveBrightness;
}
- (BOOL)setBrightness:(float)level fadeSpeed:(int)fade commit:(BOOL)commit forKeyboard:(unsigned long long)keyboard {
    [self.writes addObject:@{@"keyboard": @(keyboard), @"level": @(level), @"fade": @(fade), @"commit": @(commit)}];
    if (self.failuresRemaining) {
        self.failuresRemaining--;
        return NO;
    }
    return !self.failAlways && keyboard == self.currentID;
}
@end

static BacklightFixture *fixture(void) {
    BacklightFixture *client = [BacklightFixture new];
    gClient = client;
    gKbd = 1;
    gLit = YES;
    return client;
}

static void testRetry(void) {
    BacklightFixture *client = fixture();
    assert(setLevel(0.5, 150));
    assert(gKbd == 2 && client.resolutions == 1 && client.writes.count == 2);
    assert(([client.registrations isEqualToArray:@[@2]]));
    assert(([client.suspensions isEqualToArray:@[@2]]));
    assert([client.writes[0][@"keyboard"] isEqual:@1]);
    assert([client.writes[1][@"keyboard"] isEqual:@2]);
    for (NSDictionary *write in client.writes) {
        assert([write[@"level"] floatValue] == 0.5f);
        assert([write[@"fade"] intValue] == 150 && ![write[@"commit"] boolValue]);
    }

    client = fixture();
    gKbd = client.currentID;
    assert(setLevel(0.5, 150));
    assert(client.writes.count == 1 && client.resolutions == 0);

    client = fixture();
    gKbd = client.currentID;
    client.failuresRemaining = 1;
    assert(writeBrightness(0.75, 1000, YES));
    assert(client.writes.count == 2 && client.resolutions == 1);
    assert(client.registrations.count == 0 && client.suspensions.count == 0);
    for (NSDictionary *write in client.writes) {
        assert([write[@"keyboard"] isEqual:@2]);
        assert([write[@"level"] floatValue] == 0.75f);
        assert([write[@"fade"] intValue] == 1000 && [write[@"commit"] boolValue]);
    }

    client = fixture();
    client.failAlways = YES;
    assert(!setLevel(0.5, 150));
    assert(gKbd == 2 && client.writes.count == 2 && client.resolutions == 1);
    assert(client.registrations.count == 1 && client.suspensions.count == 1);

    client = fixture();
    gKbd = client.currentID;
    client.failAlways = YES;
    assert(!setLevel(0.5, 150));
    assert(client.writes.count == 2 && client.resolutions == 1);
    assert(client.registrations.count == 0 && client.suspensions.count == 0);

    client = fixture();
    client.currentID = 0;
    assert(!setLevel(0.5, 150));
    assert(gKbd == 1 && client.writes.count == 2 && client.resolutions == 1);
    assert(client.registrations.count == 0 && client.suspensions.count == 0);
}

static void testWake(BOOL displayWake) {
    BacklightFixture *client = fixture();
    NSNotificationCenter *center = [NSNotificationCenter new];
    if (displayWake) registerDisplayWakeNotification(center);
    void (^wake)(void) = ^{
        if (displayWake) [center postNotificationName:NSWorkspaceScreensDidWakeNotification object:nil];
        else powerCallback(NULL, 0, kIOMessageSystemHasPoweredOn, NULL);
    };
    wake();
    assert(gKbd == 2 && client.resolutions == 1 && client.writes.count == 0);
    assert(([client.registrations isEqualToArray:@[@2]]));
    assert(client.suspensions.count >= 1);
    for (NSNumber *keyboard in client.suspensions) assert([keyboard isEqual:@2]);

    [client.suspensions removeAllObjects];
    wake();
    assert(client.resolutions == 2 && client.registrations.count == 1);
    assert(([client.suspensions isEqualToArray:@[@2]]));

    client.currentID = 3;
    gLit = NO;
    [client.suspensions removeAllObjects];
    wake();
    assert(gKbd == 3 && client.resolutions == 3);
    assert(([client.registrations isEqualToArray:@[@2, @3]]));
    assert(client.suspensions.count >= 1);
    for (NSNumber *keyboard in client.suspensions) assert([keyboard isEqual:@3]);
    assert(client.writes.count == 1);
    NSDictionary *write = client.writes.lastObject;
    assert([write[@"keyboard"] isEqual:@3] && [write[@"level"] floatValue] == 0);
    assert([write[@"fade"] intValue] == 0 && ![write[@"commit"] boolValue]);

    client.currentID = 0;
    gLit = YES;
    wake();
    assert(gKbd == 3 && client.resolutions == 4 && client.registrations.count == 2);
    assert(client.writes.count == 1);
}

static void drainMainQueue(void) {
    __block BOOL done = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ done = YES; });
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 1;
    while (!done && CFAbsoluteTimeGetCurrent() < deadline)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
    assert(done);
}

static void testNotificationRecovery(void) {
    BacklightFixture *client = fixture();
    gKbd = 2;
    registerKeyboardNotifications();
    gAmbientEnabled = YES;
    client.callbacks[0](CB_AUTO_BRIGHTNESS, @NO);
    // A callback queued before switching IDs must also be ignored.
    client.currentID = 3;
    refreshKeyboard();
    drainMainQueue();
    assert(gAmbientEnabled);
    client.callbacks[0](CB_AUTO_BRIGHTNESS, @NO);
    drainMainQueue();
    assert(gAmbientEnabled);
    client.callbacks[1](CB_AUTO_BRIGHTNESS, @NO);
    drainMainQueue();
    assert(!gAmbientEnabled);
}

static void testLevelPreferences(void) {
    BacklightFixture *client = fixture();
    gKbd = client.currentID;
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_resume(gTimer);
    testPreferences = [NSMutableDictionary new];
    for (id legacy in @[[NSNull null], @0, @0.01, @(-1), @0.75, @2]) {
        [testPreferences removeAllObjects];
        if (legacy != NSNull.null) testPreferences[@"StatusUserBrightness"] = legacy;
        loadSettings();
        float expected = legacy == NSNull.null || [legacy doubleValue] <= 0.01 ? 0.5f
            : fminf([legacy floatValue], 1);
        assert(gLevel == expected);
        assert(!testPreferences[@"Level"]);
    }
    for (NSNumber *level in @[@0, @0.005, @0.25, @1, @(-1), @2]) {
        testPreferences[@"Level"] = level;
        testPreferences[@"StatusUserBrightness"] = @0.9;
        settingsChanged(NULL, NULL, NULL, NULL, NULL);
        assert(gLevel == fminf(fmaxf(level.floatValue, 0), 1));
    }
    // The next typing session uses the window's Level, including an explicit zero.
    gAmbientEnabled = NO;
    for (NSNumber *level in @[@0.25, @0, @0.005]) {
        testPreferences[@"Level"] = level;
        settingsChanged(NULL, NULL, NULL, NULL, NULL);
        gSession = gLit = NO;
        [client.writes removeAllObjects];
        keyActivity();
        assert(gSession && gLit == (level.floatValue > 0));
        assert(client.writes.count == (level.floatValue > 0 ? 1 : 0));
        if (gLit) assert([client.writes.lastObject[@"level"] floatValue] == level.floatValue);
    }
    dispatch_source_cancel(gTimer);
    gTimer = nil;
}

static void testClassification(void) {
    assert(classifyBrightness(100, 97, 99, YES, YES) == BrightnessManualKey);
    assert(classifyBrightness(100, 96.999, 99, NO, NO) == BrightnessAutomaticTransition);
    assert(classifyBrightness(100, 101, 99, NO, NO) == BrightnessAutomaticTransition);
    assert(classifyBrightness(100, 0, 90, NO, NO) == BrightnessAutomaticTransition);
    assert(classifyBrightness(100.001, 0, 90, NO, NO) == BrightnessManualNormal);
    assert(classifyBrightness(100, 0, 1, NO, YES) == BrightnessAutomaticLock);
    assert(classifyBrightness(100, 0, 1, YES, NO) == BrightnessAutomaticDisplay);
    assert(classifyBrightness(100, 0, 1, NO, NO) == BrightnessManualNormal);
    assert(sameBrightnessRamp(100, 99));
    assert(!sameBrightnessRamp(100.001, 99));
    assert(!sameBrightnessRamp(98, 99));
    assert(illuminationKey(0x0c, 0x79) && illuminationKey(0x0c, 0x7a));
    assert(illuminationKey(0xff, 8) && illuminationKey(0xff, 9));
    assert(!illuminationKey(0x0c, 0x6f) && !illuminationKey(0x0c, 0x70));
    assert(!illuminationKey(0xff00, 8) && !illuminationKey(7, 8));
}

static void testBrightnessKeys(void) {
    gSession = YES;
    gLuxCheckedAt = CFAbsoluteTimeGetCurrent();
    for (NSNumber *page in @[@0x0c, @0xff]) {
        for (NSNumber *usage in page.intValue == 0x0c ? @[@0x79, @0x7a] : @[@8, @9]) {
            gLastBrightnessKey = 0;
            noteBrightnessKey(page.intValue, usage.intValue, 1);
            assert(gLastBrightnessKey > 0);
            CFAbsoluteTime pressedAt = gLastBrightnessKey;
            noteBrightnessKey(page.intValue, usage.intValue, 0);
            assert(gLastBrightnessKey == pressedAt);
        }
    }
    gLastBrightnessKey = 0;
    noteBrightnessKey(7, 4, 1);
    noteBrightnessKey(0x0c, 0x6f, 1);
    noteBrightnessKey(0xff, 3, 1);
    assert(gLastBrightnessKey == 0);
}

static void testExternalBrightness(void) {
    BacklightFixture *client = fixture();
    gKbd = client.currentID;
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_resume(gTimer);
    gLevel = 0.625;
    testPreferences[@"Level"] = @(gLevel);
    gPreferencesLevel = gLevel;
    gLastBrightnessKey = 0;
    testMainAsleep = YES;
    testSession = @{@"CGSSessionScreenIsLocked": @NO};
    gLastTransition = CFAbsoluteTimeGetCurrent();
    NSUInteger before = preferenceWrites;
    // Automatic zero must restore the saved level only when both session flags are true.
    for (int state = 0; state < 4; state++) {
        gSession = (state & 1) != 0;
        gLit = (state & 2) != 0;
        for (NSNumber *value in @[@0, @0.25, @1]) {
            gSetLevel = -1;
            gSetAt = 0;
            gLastKey = 123;
            systemSettingChanged(CB_BRIGHTNESS, value);
            assert(gLevel == 0.625f && gSession == ((state & 1) != 0) && gLit == ((state & 2) != 0));
            assert(gLastKey == 123 && preferenceWrites == before);
            assert([client.writes.lastObject[@"level"] floatValue] == (state == 3 ? 0.625f : 0));
        }
    }
    // Echoes do nothing, but a different value during our fade is still external.
    gSession = gLit = YES;
    setLevel(gLevel, 150);
    NSUInteger writes = client.writes.count;
    systemSettingChanged(CB_BRIGHTNESS, @(gLevel));
    assert(client.writes.count == writes && preferenceWrites == before);
    gLastBrightnessKey = CFAbsoluteTimeGetCurrent();
    for (NSNumber *value in @[@0.25, @0.5, @0.75]) {
        systemSettingChanged(CB_BRIGHTNESS, value);
        assert(gLevel == value.floatValue && gLit && gSession);
        assert(CFAbsoluteTimeGetCurrent() - gLastKey < 0.1);
    }
    assert(gManualPending && preferenceWrites == before);
    assert(client.writes.count == writes);  // Manual changes already reached the hardware.
    timerFired();
    assert(gSession && gLit);  // The last ramp value starts a full new timeout.
    gManualAt -= 1.01;
    NSUInteger publications = statusPublications;
    manualTimerFired();
    assert(preferenceWrites == before + 1 && !gManualPending);
    assert(statusPublications == publications + 1);
    assert([testPreferences[@"Level"] floatValue] == 0.75f);

    // A stable desktop accepts Control Center and System Settings without a key press.
    gLastBrightnessKey = 0;
    gLastTransition = CFAbsoluteTimeGetCurrent() - 11;
    testMainAsleep = NO;
    systemSettingChanged(CB_BRIGHTNESS, @0);
    assert(gLevel == 0 && !gLit && gSession);
    saveManualLevel();
    assert([testPreferences[@"Level"] floatValue] == 0);
    keyActivity();
    assert(!gLit && gLevel == 0);

    // A newer direct window preference cancels the unfinished ramp.
    systemSettingChanged(CB_BRIGHTNESS, @0.875);
    testPreferences[@"Level"] = @0.375;
    settingsChanged(NULL, NULL, NULL, NULL, NULL);
    before = preferenceWrites;
    manualTimerFired();
    assert(!gManualPending && gLevel == 0.375f && preferenceWrites == before);

    // A gap over one second finishes the previous run before starting another.
    queueManualLevel(0.25, 100);
    queueManualLevel(0.5, 101);
    assert(preferenceWrites == before);
    queueManualLevel(0.75, 102.001);
    assert(preferenceWrites == before + 1 && [testPreferences[@"Level"] floatValue] == 0.5f);
    saveManualLevel();
    assert(preferenceWrites == before + 2 && [testPreferences[@"Level"] floatValue] == 0.75f);

    for (NSNumber *live in @[@0, @0.9]) {
        client.liveBrightness = live.floatValue;
        gLit = YES;
        lightOff();
        assert(!gLit && client.brightnessReads == 0);
        assert([client.writes.lastObject[@"level"] floatValue] == 0);
    }
    for (NSNumber *level in @[@0, @0.005, @0.625]) {
        gLevel = level.floatValue;
        giveBackControl();
        NSDictionary *write = client.writes.lastObject;
        assert([write[@"level"] floatValue] == (gLevel > 0 ? gLevel : 0.5f));
        assert([write[@"commit"] boolValue] && !client.idleSuspended && client.brightnessReads == 0);
    }
    dispatch_source_cancel(gTimer);
    gTimer = nil;
}

static void testWindowPreview(void) {
    BacklightFixture *client = fixture();
    gKbd = client.currentID;
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_resume(gTimer);
    gTimeout = 10;
    gAmbientEnabled = YES;  // A direct preview bypasses ambient gating.
    testMainAsleep = YES;
    testSession = @{@"CGSSessionScreenIsLocked": @YES};
    gLastBrightnessKey = 0;
    gLastTransition = CFAbsoluteTimeGetCurrent();
    NSUInteger before = preferenceWrites;
    for (int brightnessFirst = 0; brightnessFirst < 2; brightnessFirst++) {
        for (NSNumber *value in @[@0.125, @0.633, @0.75, @0, @1]) {
            testPreferences[@"Level"] = @0.625;
            loadSettings();
            gSetLevel = -1;
            gSetAt = 0;
            gSession = gLit = NO;
            gLastKey = CFAbsoluteTimeGetCurrent() - 9;
            queueManualLevel(0.875, CFAbsoluteTimeGetCurrent());
            [client.writes removeAllObjects];
            testPreferences[@"Level"] = value;
            // Use a nearby value to exercise the Level tolerance rather than our exact write echo.
            NSNumber *external = @(value.floatValue > 0 && value.floatValue < 1 ? value.floatValue + 0.004f
                                                                                 : value.floatValue);
            if (!brightnessFirst) settingsChanged(NULL, NULL, NULL, NULL, NULL);
            systemSettingChanged(CB_BRIGHTNESS, external);
            if (brightnessFirst) settingsChanged(NULL, NULL, NULL, NULL, NULL);
            assert(gLevel == value.floatValue && !gManualPending && preferenceWrites == before);
            assert(gSession && gLit == (value.floatValue > 0));
            assert(CFAbsoluteTimeGetCurrent() - gLastKey < 0.1);
            assert(client.writes.count == 1);
            assert([client.writes[0][@"level"] floatValue] == value.floatValue);
            timerFired();
            assert(gSession && client.writes.count == 1);  // The previous timeout cannot end the preview.
            gLastKey -= gTimeout + 0.1;
            timerFired();
            assert(!gSession && !gLit);
            assert(client.writes.count == (value.floatValue > 0 ? 2 : 1));
        }
    }
    // An equal-to-Level external change is accepted even outside our own notification window.
    testPreferences[@"Level"] = @0.5;
    loadSettings();
    for (NSNumber *external in @[@0.49, @0.491, @0.5, @0.509, @0.51]) {
        gSetLevel = -1;
        gSetAt = 0;
        gSession = gLit = NO;
        [client.writes removeAllObjects];
        systemSettingChanged(CB_BRIGHTNESS, external);
        assert(gLevel == 0.5f && gSession && gLit);
        assert(client.writes.count == 0 && !gManualPending && preferenceWrites == before);
    }
    // Other window settings must not restart an unchanged brightness preview.
    [client.writes removeAllObjects];
    gLastKey = 123;
    testPreferences[@"AmbientThresholdLux"] = @4;
    settingsChanged(NULL, NULL, NULL, NULL, NULL);
    assert(client.writes.count == 0 && gLastKey == 123 && gLuxLimit == 4);
    dispatch_source_cancel(gTimer);
    gTimer = nil;
}

static void testLiveState(void) {
    BacklightFixture *client = fixture();
    gKbd = client.currentID;
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_resume(gTimer);
    gLastBrightnessKey = 0;
    NSNotificationCenter *center = [NSNotificationCenter new];
    registerDisplayWakeNotification(center);
    // Old sleep and lock notifications cannot override the current awake, unlocked desktop.
    [center postNotificationName:NSWorkspaceScreensDidSleepNotification object:nil];
    screenLockChanged(NULL, NULL, CFSTR("com.apple.screenIsLocked"), NULL, NULL);
    for (int state = 0; state < 4; state++) {
        testPreferences[@"Level"] = @0.625;
        loadSettings();
        cancelManualSave();
        testMainAsleep = (state & 1) != 0;
        testSession = @{@"CGSSessionScreenIsLocked": @((state & 2) != 0)};
        gLastTransition = CFAbsoluteTimeGetCurrent() - 11;
        gSetLevel = -1;
        gSetAt = 0;
        gSession = gLit = NO;
        [client.writes removeAllObjects];
        NSUInteger previousDisplays = displayReads, previousSessions = sessionReads;
        systemSettingChanged(CB_BRIGHTNESS, @0.25);
        assert(displayReads > previousDisplays && sessionReads == previousSessions + 1);
        assert(gLevel == (state == 0 ? 0.25f : 0.625f));
        assert(gSession == (state == 0) && gLit == (state == 0));
        assert(client.writes.count == (state == 0 ? 0 : 1));
        if (state) assert([client.writes.lastObject[@"level"] floatValue] == 0);
    }
    cancelManualSave();
    // Wake and unlock notifications likewise cannot hide a currently sleeping or locked state.
    [center postNotificationName:NSWorkspaceScreensDidWakeNotification object:nil];
    screenLockChanged(NULL, NULL, CFSTR("com.apple.screenIsUnlocked"), NULL, NULL);
    for (int state = 1; state <= 2; state++) {
        testMainAsleep = state == 1;
        testSession = @{@"CGSSessionScreenIsLocked": @(state == 2)};
        gLastTransition = CFAbsoluteTimeGetCurrent() - 11;
        gSetLevel = -1;
        [client.writes removeAllObjects];
        systemSettingChanged(CB_BRIGHTNESS, @0.25);
        assert(gLevel == 0.625f && client.writes.count == 1 && !gManualPending);
    }
    // With an external main display, the built-in display is also read live.
    testBuiltInDisplay = 20;
    testSession = nil;
    for (int state = 0; state < 4; state++) {
        loadSettings();
        cancelManualSave();
        testMainAsleep = (state & 1) != 0;
        testBuiltInAsleep = (state & 2) != 0;
        gSession = gLit = NO;
        gSetLevel = -1;
        [client.writes removeAllObjects];
        systemSettingChanged(CB_BRIGHTNESS, @0.25);
        assert(gLevel == (state == 0 ? 0.25f : 0.625f));
        assert(client.writes.count == (state == 0 ? 0 : 1));
    }
    cancelManualSave();
    testMainAsleep = NO;
    testBuiltInDisplay = 0;  // No built-in display, as in clamshell mode.
    assert(!displayIsAsleep() && !screenIsLocked());
    testSession = @{};
    assert(!screenIsLocked());
    testBuiltInDisplay = testMainDisplay;
    testBuiltInAsleep = NO;
    dispatch_source_cancel(gTimer);
    gTimer = nil;
}

static void testTransitions(void) {
    NSNotificationCenter *center = [NSNotificationCenter new];
    registerDisplayWakeNotification(center);
    gLastTransition = 0;
    [center postNotificationName:NSWorkspaceScreensDidSleepNotification object:nil];
    assert(gLastTransition > 0);
    gLastTransition = 0;
    [center postNotificationName:NSWorkspaceScreensDidWakeNotification object:nil];
    assert(gLastTransition > 0);
    gLastTransition = 0;
    screenLockChanged(NULL, NULL, CFSTR("com.apple.screenIsLocked"), NULL, NULL);
    assert(gLastTransition > 0);
    gLastTransition = 0;
    screenLockChanged(NULL, NULL, CFSTR("com.apple.screenIsUnlocked"), NULL, NULL);
    assert(gLastTransition > 0);
    gLastTransition = 0;
    powerCallback(NULL, 0, kIOMessageSystemWillSleep, NULL);
    assert(gLastTransition > 0);
    gLastTransition = 0;
    powerCallback(NULL, 0, kIOMessageSystemHasPoweredOn, NULL);
    assert(gLastTransition > 0);
}

#ifndef BACKLIGHT_TEST_LIBRARY

int main(void) {
    @autoreleasepool {
        testClassification();
        testBrightnessKeys();
        testLevelPreferences();
        testExternalBrightness();
        testWindowPreview();
        testLiveState();
        testRetry();
        testWake(NO);
        testWake(YES);
        testNotificationRecovery();
        testTransitions();
        puts("Passed level checks: classification, ramp coalescing, saved manual levels, automatic restore "
             "and window preview in either notification order, plus live display/lock state.");
        puts("Passed backlight checks: system wake, display wake, ID recovery, notification recovery "
             "and bounded retry.");
    }
    return 0;
}

#endif
