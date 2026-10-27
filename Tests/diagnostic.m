// Exercise the bounded memory log and request/reply using a private notification center.
#include <assert.h>
#import <Foundation/Foundation.h>

#define BACKLIGHT_TEST_LIBRARY
#import "backlight.m"
#undef CFNotificationCenterPostNotification

static void resetLog(void) {
    for (NSUInteger i = 0; i < 500; i++) gDiagnosticEntries[i] = nil;
    gDiagnosticHead = gDiagnosticCount = 0;
}

static void testRing(void) {
    resetLog();
    for (int i = 0; i < 750; i++) DIAG(@"event %d", i);
    NSArray *entries = diagnosticRead();
    assert(entries.count == 500);
    assert([entries.firstObject[@"text"] isEqual:@"event 250"]);
    assert([entries.lastObject[@"text"] isEqual:@"event 749"]);
    for (NSUInteger i = 1; i < entries.count; i++)
        assert([entries[i - 1][@"timestamp"] doubleValue] <= [entries[i][@"timestamp"] doubleValue]);

    // The oldest entry expires on read, even without another event.
    gDiagnosticEntries[gDiagnosticHead] = @{@"timestamp": @(CFAbsoluteTimeGetCurrent() - 601), @"text": @"expired"};
    assert(diagnosticRead().count == 499);
    assert(gDiagnosticEntries[(gDiagnosticHead + 499) % 500] == nil);

    // Expired entries are also removed on add.
    resetLog();
    gDiagnosticEntries[0] = @{@"timestamp": @(CFAbsoluteTimeGetCurrent() - 601), @"text": @"expired"};
    gDiagnosticCount = 1;
    DIAG(@"fresh");
    entries = diagnosticRead();
    assert(entries.count == 1 && [entries.firstObject[@"text"] isEqual:@"fresh"]);
    assert(gDiagnosticEntries[0] == nil);

    resetLog();
    gDiagnosticEntries[0] = @{@"timestamp": @400, @"text": @"boundary"};
    gDiagnosticCount = 1;
    diagnosticPrune(1000);
    assert(gDiagnosticCount == 1);
    diagnosticPrune(1000.001);
    assert(gDiagnosticCount == 0 && gDiagnosticEntries[0] == nil);
}

static void testReply(void) {
    resetLog();
    DIAG(@"agent start");
    CFNotificationCenterRef center = CFNotificationCenterGetLocalCenter();
    NSArray *entries = nil;
    CFNotificationCenterAddObserver(center, NULL, diagnosticRequested, LOG_REQUEST, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, &entries, diagnosticReceived, LOG_REPLY, CFSTR("test-token"),
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterPostNotification(center, LOG_REQUEST, CFSTR("different-token"), NULL, true);
    assert(entries == nil);
    CFNotificationCenterPostNotification(center, LOG_REQUEST, CFSTR("test-token"), NULL, true);
    assert(entries.count == 1 && [entries.firstObject[@"text"] isEqual:@"agent start"]);
    resetLog();
    entries = nil;
    CFNotificationCenterPostNotification(center, LOG_REQUEST, CFSTR("test-token"), NULL, true);
    assert(entries != nil && entries.count == 0);
    CFNotificationCenterRemoveEveryObserver(center, NULL);
    CFNotificationCenterRemoveEveryObserver(center, &entries);
}

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
        resetLog();
        testTransitions();
        NSMutableSet *events = [NSMutableSet new];
        for (NSDictionary *entry in diagnosticRead()) [events addObject:entry[@"text"]];
        assert([events containsObject:@"display sleep"] && [events containsObject:@"display wake"]);
        assert([events containsObject:@"screen lock"] && [events containsObject:@"screen unlock"]);
        assert([events containsObject:@"power will sleep"] && [events containsObject:@"power has powered on"]);
        resetLog();
        BacklightFixture *client = fixture();
        gKbd = client.currentID;
        gLevel = 0.625;
        gSession = gLit = YES;
        testPreferences[@"Level"] = @(gLevel);
        gPreferencesLevel = gLevel;
        testMainAsleep = YES;
        testSession = @{@"CGSSessionScreenIsLocked": @NO};
        gLastBrightnessKey = 0;
        gSetLevel = -1;
        gSetAt = 0;
        systemSettingChanged(CB_BRIGHTNESS, @0);
        NSArray *entries = diagnosticRead();
        assert([entries[0][@"text"] isEqual:
                @"external brightness value=0.000 class=automatic reason=display asleep live display asleep=1 screen locked=0"]);
        assert([entries[1][@"text"] isEqual:@"external brightness restore action=saved level level=0.625"]);
        assert(gLevel == 0.625f);
        resetLog();
        gLastBrightnessKey = CFAbsoluteTimeGetCurrent();
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_resume(gTimer);
        systemSettingChanged(CB_BRIGHTNESS, @0.75);
        entries = diagnosticRead();
        assert([entries[0][@"text"] isEqual:
                @"external brightness value=0.750 class=manual reason=brightness key within 3 seconds live display asleep=1 screen locked=0"]);
        cancelManualSave();
        resetLog();
        testMainAsleep = NO;
        testSession = @{@"CGSSessionScreenIsLocked": @YES};
        gLastBrightnessKey = 0;
        NSUInteger writes = client.writes.count;
        systemSettingChanged(CB_BRIGHTNESS, @0.754);
        entries = diagnosticRead();
        assert(entries.count == 1 && client.writes.count == writes && !gManualPending);
        assert([entries[0][@"text"] isEqual:
                @"external brightness value=0.754 class=manual reason=matches configured Level live display asleep=0 screen locked=1"]);
        dispatch_source_cancel(gTimer);
        gTimer = nil;
        resetLog();
        testPreferences[@"Level"] = @0.375;
        loadSettings();
        entries = diagnosticRead();
        assert(entries.count == 1 && gLevel == 0.375f);
        assert([entries[0][@"text"] isEqual:@"preferences Level=0.375"]);
        testRing();
        testReply();
        puts("Passed diagnostic checks: brightness class and reason, live display/lock values, restore action, preference level, "
             "ring and request/reply.");
    }
    return 0;
}
