// Exercise the bounded memory log and request/reply using a private notification center.
#include <assert.h>
#define main agentMain
#import "../Sources/Agent/nightkeysd.m"
#undef main

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
        testRing();
        testReply();
        puts("Passed diagnostic checks: 500-entry ring, oldest-first order, expiry on add/read and correlated request/reply.");
    }
    return 0;
}
