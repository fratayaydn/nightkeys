// Exercise backlight recovery with private fixtures and simulated wake notifications.
#include <assert.h>
#define main agentMain
#import "../Sources/Agent/nightkeysd.m"
#undef main

typedef void (^SettingCallback)(id, id);

@interface BacklightFixture : NSObject
@property unsigned long long currentID;
@property NSUInteger resolutions;
@property BOOL failAlways;
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
    assert(suspend);
    [self.suspensions addObject:@(keyboard)];
    return YES;
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

int main(void) {
    @autoreleasepool {
        testRetry();
        testWake(NO);
        testWake(YES);
        testNotificationRecovery();
        puts("Passed backlight checks: system wake, display wake, ID recovery, notification recovery and bounded retry.");
    }
    return 0;
}
