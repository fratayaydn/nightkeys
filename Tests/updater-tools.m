// Exercise the subprocess timeout without a release check, saved preferences or an installed application.
#include <assert.h>
#import "../Sources/Agent/Updater.m"

int main(void) {
    @autoreleasepool {
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
