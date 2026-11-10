// Shared release updater. Product-specific values live here; the rest can be copied unchanged.
#import "Updater.h"
#import <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

static NSString *const GitHubOwner = @"fratayaydn";
static NSString *const GitHubRepo = @"nightkeys";
static NSString *const AppName = @"NightKeys";
static NSString *const BundleID = @"io.github.fratayaydn.nightkeys";
static NSString *const TeamID = @"GYWRX9QZZD";

NSString *updaterVersion(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *version = [value hasPrefix:@"v"] ? [value substringFromIndex:1] : value;
    NSArray *parts = [version componentsSeparatedByString:@"."];
    if (parts.count < 1 || parts.count > 3) return nil;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
    for (NSString *part in parts)
        if (!part.length || [part rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
    return version;
}

NSComparisonResult updaterCompareVersions(NSString *left, NSString *right) {
    NSArray *a = [updaterVersion(left) componentsSeparatedByString:@"."];
    NSArray *b = [updaterVersion(right) componentsSeparatedByString:@"."];
    for (NSUInteger i = 0; i < 3; i++) {
        NSString *x = i < a.count ? a[i] : @"0";
        NSString *y = i < b.count ? b[i] : @"0";
        NSComparisonResult result = [x compare:y options:NSNumericSearch];
        if (result != NSOrderedSame) return result;
    }
    return NSOrderedSame;
}

BOOL updaterCheckDue(id lastCheck, NSDate *now, id lastBuild, NSString *currentBuild, BOOL enabled, BOOL force) {
    if (!enabled) return NO;
    if (force || ![lastBuild isEqual:currentBuild]) return YES;
    return ![lastCheck isKindOfClass:NSDate.class] || [now timeIntervalSinceDate:lastCheck] >= 20 * 60 * 60;
}

NSString *updaterAssetName(NSString *version) {
    return [NSString stringWithFormat:@"%@-%@.dmg", AppName, version];
}

BOOL updaterAssetSizeValid(id value) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    double size = [value doubleValue];
    return size > 0 && size <= 64 * 1024 * 1024 && size == [value unsignedLongLongValue];
}

NSString *updaterRequirement(void) {
    return [NSString stringWithFormat:@"anchor apple generic and identifier \"%@\" and certificate leaf[subject.OU] = \"%@\" and notarized",
                                     BundleID, TeamID];
}

static id preference(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)BundleID));
}

static BOOL preferenceEnabled(NSString *key) {
    id value = preference(key);
    return value == nil || [value boolValue];
}

// Resolve the executable rather than the working directory or an application search result.
static NSURL *runningBundle(void) {
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    NSMutableData *buffer = [NSMutableData dataWithLength:size];
    if (_NSGetExecutablePath(buffer.mutableBytes, &size)) return nil;
    char resolved[PATH_MAX];
    if (!realpath(buffer.bytes, resolved)) return nil;
    NSURL *executable = [NSURL fileURLWithPath:@(resolved)];
    NSURL *macOS = executable.URLByDeletingLastPathComponent;
    NSURL *contents = macOS.URLByDeletingLastPathComponent;
    NSURL *bundle = contents.URLByDeletingLastPathComponent;
    if (![macOS.lastPathComponent isEqual:@"MacOS"] || ![contents.lastPathComponent isEqual:@"Contents"] ||
        ![bundle.pathExtension isEqual:@"app"]) return nil;
    return bundle;
}

static NSDictionary *bundleInfo(NSURL *bundle) {
    if (!bundle) return nil;
    return [NSDictionary dictionaryWithContentsOfURL:[bundle URLByAppendingPathComponent:@"Contents/Info.plist"]];
}

static NSMutableURLRequest *requestForURL(NSURL *url, NSString *version) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 20;
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:[NSString stringWithFormat:@"%@/%@", AppName, version] forHTTPHeaderField:@"User-Agent"];
    return request;
}

#ifdef UPDATER_TEST_FEED
static BOOL localTestURL(NSURL *url) {
    return [url.scheme isEqual:@"http"] && [url.host isEqual:@"127.0.0.1"];
}
#endif

static BOOL responseOK(NSURLResponse *response) {
    BOOL secure = [response.URL.scheme isEqual:@"https"];
#ifdef UPDATER_TEST_FEED
    secure = secure || localTestURL(response.URL);
#endif
    return [response isKindOfClass:NSHTTPURLResponse.class] &&
           [(NSHTTPURLResponse *)response statusCode] == 200 && secure;
}

static BOOL waitForCallback(dispatch_semaphore_t done, int seconds) {
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)seconds * NSEC_PER_SEC)) == 0) return YES;
    return NO;
}

// Completion handlers run off the calling thread; waiting does not require an AppKit event loop.
static NSDictionary *latestRelease(NSURLSession *session, NSString *version, BOOL *notFound) {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/releases/latest",
                                                               GitHubOwner, GitHubRepo]];
#ifdef UPDATER_TEST_FEED
    NSString *feed = NSProcessInfo.processInfo.environment[@"UPDATER_TEST_FEED"];
    if (feed) url = [NSURL URLWithString:feed];
#endif
    if (!url) return nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *release;
    __block BOOL missing = NO;
    [[session dataTaskWithRequest:requestForURL(url, version) completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && !responseOK(response)) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
            missing = status == 404;
        }
        else if (!error) {
            id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            if ([value isKindOfClass:NSDictionary.class]) release = value;
        }
        dispatch_semaphore_signal(done);
    }] resume];
    if (!waitForCallback(done, 360)) return nil;
    *notFound = missing;
    return release;
}

static BOOL download(NSURLSession *session, NSURL *url, NSString *version, NSURL *destination) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL success = NO;
    [[session downloadTaskWithRequest:requestForURL(url, version) completionHandler:^(NSURL *file, NSURLResponse *response, NSError *error) {
        if (!error && responseOK(response) && file) {
            success = [NSFileManager.defaultManager moveItemAtURL:file toURL:destination error:NULL];
        }
        dispatch_semaphore_signal(done);
    }] resume];
    if (!waitForCallback(done, 360)) return NO;
    return success;
}

static BOOL runTool(NSString *tool, NSArray<NSString *> *arguments, int timeout) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:tool];
    task.arguments = arguments;
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    if (timeout > 0) task.terminationHandler = ^(NSTask *finished) {
        (void)finished;
        dispatch_semaphore_signal(done);
    };
    if (![task launchAndReturnError:NULL]) return NO;
    if (timeout > 0) {
        if (!waitForCallback(done, timeout)) {
            if (task.running) [task terminate];
            return NO;
        }
    } else {
        [task waitUntilExit];
    }
    BOOL success = task.terminationReason == NSTaskTerminationReasonExit && task.terminationStatus == 0;
    return success;
}

static BOOL verifyDiskImage(NSURL *image) {
    NSString *text = [NSString stringWithFormat:@"anchor apple generic and certificate leaf[subject.OU] = \"%@\" and notarized", TeamID];
    SecStaticCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    OSStatus status = SecRequirementCreateWithString((__bridge CFStringRef)text, kSecCSDefaultFlags, &requirement);
    if (status == errSecSuccess) status = SecStaticCodeCreateWithPath((__bridge CFURLRef)image, kSecCSDefaultFlags, &code);
    if (status == errSecSuccess)
        status = SecStaticCodeCheckValidity(code, kSecCSStrictValidate | kSecCSEnforceRevocationChecks, requirement);
    if (code) CFRelease(code);
    if (requirement) CFRelease(requirement);
    return status == errSecSuccess;
}

static BOOL verifyBundle(NSURL *bundle, NSString *version) {
    SecStaticCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    OSStatus status = SecRequirementCreateWithString((__bridge CFStringRef)updaterRequirement(), kSecCSDefaultFlags, &requirement);
    if (status == errSecSuccess) status = SecStaticCodeCreateWithPath((__bridge CFURLRef)bundle, kSecCSDefaultFlags, &code);
    if (status == errSecSuccess)
        status = SecStaticCodeCheckValidity(code, kSecCSCheckAllArchitectures | kSecCSStrictValidate |
                                           kSecCSCheckNestedCode | kSecCSEnforceRevocationChecks, requirement);
    if (code) CFRelease(code);
    if (requirement) CFRelease(requirement);
    if (status != errSecSuccess) {
        return NO;
    }
    NSDictionary *info = bundleInfo(bundle);
    if (![info[@"CFBundleIdentifier"] isEqual:BundleID] || ![info[@"CFBundleShortVersionString"] isEqual:version]) {
        return NO;
    }
    return YES;
}

static BOOL replaceBundle(NSURL *source, NSURL *installed, NSString *version) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *parent = installed.URLByDeletingLastPathComponent;
    if (![fm isWritableFileAtPath:installed.path] || ![fm isWritableFileAtPath:parent.path]) {
        return NO;
    }
    // A private sibling directory keeps staging on the same filesystem and hides partial copies.
    NSString *pattern = [[parent.path stringByAppendingPathComponent:@".update.XXXXXX"] stringByStandardizingPath];
    char *name = strdup(pattern.fileSystemRepresentation);
    char *created = mkdtemp(name);
    NSURL *staging = created ? [NSURL fileURLWithPath:@(created) isDirectory:YES] : nil;
    free(name);
    if (!staging) return NO;
    NSURL *copy = [staging URLByAppendingPathComponent:[AppName stringByAppendingPathExtension:@"app"]];
    @try {
        if (!runTool(@"/usr/bin/ditto", @[source.path, copy.path], 0)) return NO;
        if (!verifyBundle(copy, version)) return NO;
        if (renamex_np(copy.fileSystemRepresentation, installed.fileSystemRepresentation, RENAME_SWAP) != 0) {
            return NO;
        }
        [fm removeItemAtURL:copy error:NULL];
    } @finally {
        [fm removeItemAtURL:staging error:NULL];
    }
    return YES;
}

static BOOL installRelease(NSURLSession *session, NSDictionary *release, NSString *version, NSString *current, NSURL *installed) {
    NSString *assetName = updaterAssetName(version);
    NSURL *downloadURL = nil;
    NSNumber *assetSize = nil;
    id assets = release[@"assets"];
    if ([assets isKindOfClass:NSArray.class]) for (id asset in assets) {
        if (![asset isKindOfClass:NSDictionary.class] || ![asset[@"name"] isEqual:assetName]) continue;
        assetSize = asset[@"size"];
        id address = asset[@"browser_download_url"];
        if ([address isKindOfClass:NSString.class]) downloadURL = [NSURL URLWithString:address];
        break;
    }
    if (!updaterAssetSizeValid(assetSize)) {
        return NO;
    }
    BOOL valid = [downloadURL.scheme isEqual:@"https"] && [downloadURL.host isEqual:@"github.com"];
#ifdef UPDATER_TEST_FEED
    valid = valid || localTestURL(downloadURL);
#endif
    if (!valid || downloadURL.user || downloadURL.password) {
        return NO;
    }
    NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"app-update.XXXXXX"];
    char *name = strdup(pattern.fileSystemRepresentation);
    char *created = mkdtemp(name);
    NSURL *temporary = created ? [NSURL fileURLWithPath:@(created) isDirectory:YES] : nil;
    free(name);
    if (!temporary) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *image = [temporary URLByAppendingPathComponent:assetName];
    NSURL *mounts = [temporary URLByAppendingPathComponent:@"mounts" isDirectory:YES];
    BOOL clean = YES;
    BOOL success = NO;
    @try {
        if (!download(session, downloadURL, current, image)) return NO;
        struct stat st;
        if (stat(image.fileSystemRepresentation, &st) != 0 || st.st_size != assetSize.longLongValue) {
            return NO;
        }
        if (!verifyDiskImage(image)) return NO;
        if (![fm createDirectoryAtURL:mounts withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions: @0700} error:NULL]) {
            return NO;
        }
        // A failed attach can still leave a mount. Cleanup inspects this private mount root on every path.
        if (!runTool(@"/usr/bin/hdiutil", @[@"attach", @"-nobrowse", @"-readonly", @"-noautoopen",
                                         @"-mountrandom", mounts.path, image.path], 0)) return NO;
        NSArray<NSURL *> *volumes = [fm contentsOfDirectoryAtURL:mounts includingPropertiesForKeys:nil options:0 error:NULL];
        NSURL *candidate = nil;
        for (NSURL *volume in volumes) {
            NSURL *app = [volume URLByAppendingPathComponent:[AppName stringByAppendingPathExtension:@"app"]];
            struct stat st;
            if (lstat(app.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode)) {
                if (candidate) return NO;
                candidate = app;
            }
        }
        if (!candidate) return NO;
        if (!verifyBundle(candidate, version)) return NO;
        success = replaceBundle(candidate, installed, version);
    } @finally {
        for (NSURL *volume in [fm contentsOfDirectoryAtURL:mounts includingPropertiesForKeys:nil options:0 error:NULL]) {
            if (!runTool(@"/usr/bin/hdiutil", @[@"detach", volume.path], 0) &&
                !runTool(@"/usr/bin/hdiutil", @[@"detach", @"-force", volume.path], 0)) clean = NO;
        }
        // Never traverse a mounted volume when removing a temporary directory.
        if (clean && ![fm removeItemAtURL:temporary error:NULL]) clean = NO;
    }
    return success && clean;
}

int updaterRun(BOOL force, BOOL install) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)BundleID);
    char build[256] = {0};
    size_t size = sizeof(build);
    NSString *osBuild = sysctlbyname("kern.osversion", build, &size, NULL, 0) == 0 ? @(build) : nil;
    if (!updaterCheckDue(preference(@"LastUpdateCheck"), NSDate.date, preference(@"LastUpdateCheckOSBuild"), osBuild,
                         preferenceEnabled(@"AutomaticUpdateChecks"), force)) {
        return 0;
    }
    if (!osBuild) return 1;
    NSURL *installed = runningBundle();
    NSString *current = updaterVersion(bundleInfo(installed)[@"CFBundleShortVersionString"]);
    if (!installed || !current) return 1;
    // One lock per installed bundle prevents a scheduled check and a manual check from swapping twice.
    int lock = open(installed.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (lock < 0) return 1;
    if (flock(lock, LOCK_EX | LOCK_NB) != 0) {
        int code = errno;
        close(lock);
        return code == EWOULDBLOCK ? 0 : 1;
    }
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 20;
    configuration.timeoutIntervalForResource = 300;
    configuration.HTTPCookieStorage = nil;
    configuration.HTTPShouldSetCookies = NO;
    configuration.URLCache = nil;
    configuration.URLCredentialStorage = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    @try {
        BOOL notFound = NO;
        NSDictionary *release = latestRelease(session, current, &notFound);
        if (!release) return notFound ? 0 : 1;
        if (![release[@"draft"] isKindOfClass:NSNumber.class] || ![release[@"prerelease"] isKindOfClass:NSNumber.class]) {
            return 1;
        }
        if ([release[@"draft"] boolValue] || [release[@"prerelease"] boolValue]) {
            return 0;
        }
        NSString *version = updaterVersion(release[@"tag_name"]);
        if (!version) return 1;
        CFPreferencesSetAppValue(CFSTR("LastUpdateCheck"), (__bridge CFDateRef)NSDate.date, (__bridge CFStringRef)BundleID);
        CFPreferencesSetAppValue(CFSTR("LastUpdateCheckOSBuild"), (__bridge CFStringRef)osBuild, (__bridge CFStringRef)BundleID);
        CFPreferencesSetAppValue(CFSTR("LatestVersion"), (__bridge CFStringRef)version, (__bridge CFStringRef)BundleID);
        if (!CFPreferencesAppSynchronize((__bridge CFStringRef)BundleID)) {
            return 1;
        }
        if (updaterCompareVersions(version, current) != NSOrderedDescending) {
            return 0;
        }
        BOOL automatic = install || preferenceEnabled(@"AutomaticallyInstallUpdates");
        if (automatic && !installRelease(session, release, version, current, installed)) return 1;
        // Resolve the main executable at the installed path after the swap, so the new app sends the notification.
        NSString *notifier = [installed URLByAppendingPathComponent:@"Contents/MacOS/NightKeys"].path;
        runTool(notifier, @[@"--notify-update", version, automatic ? @"--installed" : @"--available"], 60);
        return 0;
    } @finally {
        [session invalidateAndCancel];
        flock(lock, LOCK_UN);
        close(lock);
    }
}
