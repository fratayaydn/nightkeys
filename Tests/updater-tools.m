// Exercise the subprocess timeout without a release check, saved preferences or an installed application.
#include <assert.h>
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>

static NSString *testExecutable;
static NSMutableDictionary *testPreferences;
static NSDictionary *testRelease;
static NSUInteger releaseRequests;

static int testExecutablePath(char *buffer, uint32_t *size) {
    uint32_t needed = (uint32_t)strlen(testExecutable.fileSystemRepresentation) + 1;
    if (*size < needed) { *size = needed; return -1; }
    memcpy(buffer, testExecutable.fileSystemRepresentation, needed);
    return 0;
}
static CFPropertyListRef testCopyAppValue(CFStringRef key, CFStringRef domain) {
    assert(CFEqual(domain, CFSTR("io.github.fratayaydn.nightkeys")));
    id value = testPreferences[(__bridge NSString *)key];
    return value ? CFBridgingRetain(value) : NULL;
}
static void testSetAppValue(CFStringRef key, CFPropertyListRef value, CFStringRef domain) {
    assert(CFEqual(domain, CFSTR("io.github.fratayaydn.nightkeys")));
    testPreferences[(__bridge NSString *)key] = (__bridge id)value;
}
static Boolean testSynchronize(CFStringRef domain) { (void)domain; return true; }

@interface UpdaterTaskFixture : NSObject
- (void)resume;
@end
@implementation UpdaterTaskFixture
- (void)resume {}
@end

// Replace the session entirely so a regression cannot send a network request.
@interface UpdaterSessionFixture : NSObject
+ (instancetype)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration;
- (UpdaterTaskFixture *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler;
- (UpdaterTaskFixture *)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))handler;
- (void)invalidateAndCancel;
@end
@implementation UpdaterSessionFixture
+ (instancetype)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration { return [self new]; }
- (UpdaterTaskFixture *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    releaseRequests++;
    handler([NSJSONSerialization dataWithJSONObject:testRelease options:0 error:NULL],
            [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:nil headerFields:nil], nil);
    return [UpdaterTaskFixture new];
}
- (UpdaterTaskFixture *)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))handler {
    abort();
}
- (void)invalidateAndCancel {}
@end

#define _NSGetExecutablePath testExecutablePath
#define CFPreferencesCopyAppValue testCopyAppValue
#define CFPreferencesSetAppValue testSetAppValue
#define CFPreferencesAppSynchronize testSynchronize
#define NSURLSession UpdaterSessionFixture
#import "../Sources/Agent/Updater.m"

static void testUpdateNotifications(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSURL *bundle = [NSURL fileURLWithPath:[temporary stringByAppendingPathComponent:@"NightKeys.app"]];
    NSString *macOS = [bundle.path stringByAppendingPathComponent:@"Contents/MacOS"];
    assert([fm createDirectoryAtPath:macOS withIntermediateDirectories:YES attributes:nil error:NULL]);
    @try {
        testExecutable = [macOS stringByAppendingPathComponent:@"nightkeysd"];
        assert([fm createFileAtPath:testExecutable contents:NSData.data attributes:nil]);
        assert([@{@"CFBundleShortVersionString": @"1.0.0"} writeToURL:
            [bundle URLByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES]);
        NSString *notifier = [macOS stringByAppendingPathComponent:@"NightKeys"];
        NSString *script = @"#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.arguments\"\n";
        assert([script writeToFile:notifier atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        assert([fm setAttributes:@{NSFilePosixPermissions: @0700} ofItemAtPath:notifier error:NULL]);
        NSString *arguments = [notifier stringByAppendingString:@".arguments"];
        for (NSNumber *force in @[@NO, @YES]) for (NSNumber *install in @[@NO, @YES]) for (NSNumber *failed in @[@NO, @YES]) {
            notifyUpdate(bundle, @"1.2.3", force.boolValue, install.boolValue, YES, failed.boolValue);
            if (force.boolValue || install.boolValue) {
                assert(![fm fileExistsAtPath:arguments]);
            } else {
                NSString *expected = failed.boolValue ? @"--notify-update\n1.2.3\n--available\n" :
                                                       @"--notify-update\n1.2.3\n--installed\n";
                assert([[NSString stringWithContentsOfFile:arguments encoding:NSUTF8StringEncoding error:NULL] isEqual:expected]);
                assert([fm removeItemAtPath:arguments error:NULL]);
            }
        }
        // Missing assets make automatic installation fail before any download or filesystem install.
        testRelease = @{@"tag_name": @"v1.2.3", @"draft": @NO, @"prerelease": @NO, @"assets": @[]};
        for (NSNumber *force in @[@NO, @YES]) for (NSNumber *automatic in @[@NO, @YES]) for (NSNumber *install in @[@NO, @YES]) {
            testPreferences = [@{@"AutomaticallyInstallUpdates": automatic} mutableCopy];
            NSUInteger requests = releaseRequests;
            int result = updaterRun(force.boolValue, install.boolValue);
            assert(result == (automatic.boolValue || install.boolValue ? 1 : 0));
            if (!force.boolValue && !install.boolValue && automatic.boolValue) {
                assert([[NSString stringWithContentsOfFile:arguments encoding:NSUTF8StringEncoding error:NULL]
                    isEqual:@"--notify-update\n1.2.3\n--available\n"]);
                assert([fm removeItemAtPath:arguments error:NULL]);
            } else {
                assert(![fm fileExistsAtPath:arguments]);
            }
            if (releaseRequests > requests) assert([testPreferences[@"LatestVersion"] isEqual:@"1.2.3"]);
        }
        // Failure to launch the notifier must not hide the install failure exit code.
        assert([fm removeItemAtPath:notifier error:NULL]);
        testPreferences = [@{@"AutomaticallyInstallUpdates": @YES} mutableCopy];
        assert(updaterRun(NO, NO) == 1);
        assert(releaseRequests == 8);
    } @finally {
        assert([fm removeItemAtPath:temporary error:NULL]);
    }
    puts("Passed updater notification checks: manual runs stay silent; scheduled install failures notify availability; exit codes preserved; no network or real install.");
}

int main(void) {
    @autoreleasepool {
        testUpdateNotifications();
        assert(runTool(@"/usr/bin/true", @[], 2));
        assert(!runTool(@"/usr/bin/false", @[], 2));
        assert(runTool(@"/bin/test", @[@"two words", @"=", @"two words"], 2));
        NSString *missing = [NSFileManager.defaultManager.currentDirectoryPath
            stringByAppendingPathComponent:[@".build/missing-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        assert(!runTool(missing, @[], 2));
        NSString *pidFile = [missing stringByAppendingString:@".pid"];
        NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
        assert(!runTool(@"/bin/sh", @[@"-c", @"printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 10",
                                     @"notification-test", pidFile], 1));
        assert(NSProcessInfo.processInfo.systemUptime - start < 5);
        pid_t pid = [[NSString stringWithContentsOfFile:pidFile encoding:NSUTF8StringEncoding error:NULL] intValue];
        assert(pid > 0);
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 2;
        while (kill(pid, 0) == 0 && NSProcessInfo.processInfo.systemUptime < deadline) usleep(10000);
        assert(kill(pid, 0) == -1 && errno == ESRCH);
        assert([NSFileManager.defaultManager removeItemAtPath:pidFile error:NULL]);
        puts("Passed updater subprocess checks: success, failure, arguments, launch error and bounded timeout.");
    }
    return 0;
}
