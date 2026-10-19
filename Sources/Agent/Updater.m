// Shared release updater. Product-specific values live here; the rest can be copied unchanged.
#import "Updater.h"
#import <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <os/log.h>
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

static os_log_t updateLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create(BundleID.UTF8String, "updater"); });
    return log;
}

// Errors can contain redirect URLs or credentials. Log only the domain and code.
static void logError(NSString *step, NSError *error) {
    os_log_info(updateLog(), "%{public}@ failed: %{public}@ %ld", step, error.domain ?: @"updater", (long)error.code);
}

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

static BOOL waitForCallback(dispatch_semaphore_t done, int seconds, NSString *step) {
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)seconds * NSEC_PER_SEC)) == 0) return YES;
    os_log_info(updateLog(), "%{public}@ timed out", step);
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
    if (!url) { os_log_info(updateLog(), "Release metadata address is invalid"); return nil; }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *release;
    __block BOOL missing = NO;
    [[session dataTaskWithRequest:requestForURL(url, version) completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) logError(@"Release request", error);
        else if (!responseOK(response)) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
            os_log_info(updateLog(), "Release request returned HTTP status %ld", (long)status);
            missing = status == 404;
            if (missing) os_log_info(updateLog(), "No published release");
        }
        else {
            id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            if ([value isKindOfClass:NSDictionary.class]) release = value;
            else os_log_info(updateLog(), "Release response is not a JSON object");
        }
        dispatch_semaphore_signal(done);
    }] resume];
    if (!waitForCallback(done, 360, @"Release request")) return nil;
    *notFound = missing;
    return release;
}

static BOOL download(NSURLSession *session, NSURL *url, NSString *version, NSURL *destination) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL success = NO;
    [[session downloadTaskWithRequest:requestForURL(url, version) completionHandler:^(NSURL *file, NSURLResponse *response, NSError *error) {
        if (error) logError(@"Download", error);
        else if (!responseOK(response)) os_log_info(updateLog(), "Download returned an unsuccessful response");
        else if (file) {
            NSError *moveError = nil;
            success = [NSFileManager.defaultManager moveItemAtURL:file toURL:destination error:&moveError];
            if (!success) logError(@"Save download", moveError);
        }
        dispatch_semaphore_signal(done);
    }] resume];
    if (!waitForCallback(done, 360, @"Download")) return NO;
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
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) { logError(tool.lastPathComponent, error); return NO; }
    if (timeout > 0) {
        if (!waitForCallback(done, timeout, tool.lastPathComponent)) {
            if (task.running) [task terminate];
            os_log_info(updateLog(), "%{public}@ termination requested after timeout", tool.lastPathComponent);
            return NO;
        }
    } else {
        [task waitUntilExit];
    }
    BOOL success = task.terminationReason == NSTaskTerminationReasonExit && task.terminationStatus == 0;
    os_log_info(updateLog(), "%{public}@ finished: %d", tool.lastPathComponent, task.terminationStatus);
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
    if (status != errSecSuccess)
        os_log_info(updateLog(), "Disk image signature, Team ID and notarization validation failed: %d", (int)status);
    return status == errSecSuccess;
}

static BOOL verifyBundle(NSURL *bundle, NSString *version) {
    os_log_info(updateLog(), "Checking all architectures, nested code, identifier, Team ID and notarization");
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
        os_log_info(updateLog(), "Signature, Team ID and notarization validation failed: %d", (int)status);
        return NO;
    }
    NSDictionary *info = bundleInfo(bundle);
    if (![info[@"CFBundleIdentifier"] isEqual:BundleID] || ![info[@"CFBundleShortVersionString"] isEqual:version]) {
        os_log_info(updateLog(), "Bundle identifier or release version does not match");
        return NO;
    }
    return YES;
}

static BOOL replaceBundle(NSURL *source, NSURL *installed, NSString *version) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *parent = installed.URLByDeletingLastPathComponent;
    if (![fm isWritableFileAtPath:installed.path] || ![fm isWritableFileAtPath:parent.path]) {
        os_log_info(updateLog(), "Installed bundle or its parent is not writable");
        return NO;
    }
    // A private sibling directory keeps staging on the same filesystem and hides partial copies.
    NSString *pattern = [[parent.path stringByAppendingPathComponent:@".update.XXXXXX"] stringByStandardizingPath];
    char *name = strdup(pattern.fileSystemRepresentation);
    char *created = mkdtemp(name);
    NSURL *staging = created ? [NSURL fileURLWithPath:@(created) isDirectory:YES] : nil;
    free(name);
    if (!staging) { os_log_info(updateLog(), "Could not create sibling staging directory: %d", errno); return NO; }
    NSURL *copy = [staging URLByAppendingPathComponent:[AppName stringByAppendingPathExtension:@"app"]];
    @try {
        os_log_info(updateLog(), "Copying verified bundle beside the installed app");
        if (!runTool(@"/usr/bin/ditto", @[source.path, copy.path], 0)) return NO;
        if (!verifyBundle(copy, version)) return NO;
        os_log_info(updateLog(), "Swapping the app bundles atomically");
        if (renamex_np(copy.fileSystemRepresentation, installed.fileSystemRepresentation, RENAME_SWAP) != 0) {
            os_log_info(updateLog(), "Atomic swap failed: %d", errno);
            return NO;
        }
        os_log_info(updateLog(), "Removing the old bundle");
        NSError *error = nil;
        if (![fm removeItemAtURL:copy error:&error]) logError(@"Remove old bundle", error);
    } @finally {
        NSError *error = nil;
        if (![fm removeItemAtURL:staging error:&error]) logError(@"Remove staging directory", error);
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
        os_log_info(updateLog(), "Release asset size is missing, invalid or exceeds 64 MB");
        return NO;
    }
    BOOL valid = [downloadURL.scheme isEqual:@"https"] && [downloadURL.host isEqual:@"github.com"];
#ifdef UPDATER_TEST_FEED
    valid = valid || localTestURL(downloadURL);
#endif
    if (!valid || downloadURL.user || downloadURL.password) {
        os_log_info(updateLog(), "Expected release asset is missing or its download address is invalid");
        return NO;
    }
    NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"app-update.XXXXXX"];
    char *name = strdup(pattern.fileSystemRepresentation);
    char *created = mkdtemp(name);
    NSURL *temporary = created ? [NSURL fileURLWithPath:@(created) isDirectory:YES] : nil;
    free(name);
    if (!temporary) { os_log_info(updateLog(), "Could not create private download directory: %d", errno); return NO; }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *image = [temporary URLByAppendingPathComponent:assetName];
    NSURL *mounts = [temporary URLByAppendingPathComponent:@"mounts" isDirectory:YES];
    BOOL clean = YES;
    BOOL success = NO;
    @try {
        os_log_info(updateLog(), "Downloading release asset %{public}@", assetName);
        if (!download(session, downloadURL, current, image)) return NO;
        struct stat st;
        if (stat(image.fileSystemRepresentation, &st) != 0 || st.st_size != assetSize.longLongValue) {
            os_log_info(updateLog(), "Downloaded disk image size does not match release asset size");
            return NO;
        }
        if (!verifyDiskImage(image)) return NO;
        NSError *error = nil;
        if (![fm createDirectoryAtURL:mounts withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions: @0700} error:&error]) {
            logError(@"Create mount directory", error);
            return NO;
        }
        os_log_info(updateLog(), "Attaching disk image read-only");
        // A failed attach can still leave a mount. Cleanup inspects this private mount root on every path.
        if (!runTool(@"/usr/bin/hdiutil", @[@"attach", @"-nobrowse", @"-readonly", @"-noautoopen",
                                         @"-mountrandom", mounts.path, image.path], 0)) return NO;
        NSArray<NSURL *> *volumes = [fm contentsOfDirectoryAtURL:mounts includingPropertiesForKeys:nil options:0 error:NULL];
        NSURL *candidate = nil;
        for (NSURL *volume in volumes) {
            NSURL *app = [volume URLByAppendingPathComponent:[AppName stringByAppendingPathExtension:@"app"]];
            struct stat st;
            if (lstat(app.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode)) {
                if (candidate) { os_log_info(updateLog(), "Disk image has multiple matching apps"); return NO; }
                candidate = app;
            }
        }
        if (!candidate) { os_log_info(updateLog(), "App is missing from disk image"); return NO; }
        if (!verifyBundle(candidate, version)) return NO;
        success = replaceBundle(candidate, installed, version);
    } @finally {
        os_log_info(updateLog(), "Detaching disk image and removing private download directory");
        for (NSURL *volume in [fm contentsOfDirectoryAtURL:mounts includingPropertiesForKeys:nil options:0 error:NULL]) {
            if (!runTool(@"/usr/bin/hdiutil", @[@"detach", volume.path], 0) &&
                !runTool(@"/usr/bin/hdiutil", @[@"detach", @"-force", volume.path], 0)) clean = NO;
        }
        NSError *error = nil;
        // Never traverse a mounted volume when removing a temporary directory.
        if (clean && ![fm removeItemAtURL:temporary error:&error]) { logError(@"Remove download directory", error); clean = NO; }
    }
    return success && clean;
}

int updaterRun(BOOL force, BOOL install) {
    os_log_info(updateLog(), "Update check started");
    CFPreferencesAppSynchronize((__bridge CFStringRef)BundleID);
    char build[256] = {0};
    size_t size = sizeof(build);
    NSString *osBuild = sysctlbyname("kern.osversion", build, &size, NULL, 0) == 0 ? @(build) : nil;
    if (!updaterCheckDue(preference(@"LastUpdateCheck"), NSDate.date, preference(@"LastUpdateCheckOSBuild"), osBuild,
                         preferenceEnabled(@"AutomaticUpdateChecks"), force)) {
        os_log_info(updateLog(), "Update checks disabled or last successful check on this OS build was less than 20 hours ago");
        return 0;
    }
    if (!osBuild) { os_log_info(updateLog(), "Could not read the OS build"); return 1; }
    NSURL *installed = runningBundle();
    NSString *current = updaterVersion(bundleInfo(installed)[@"CFBundleShortVersionString"]);
    if (!installed || !current) { os_log_info(updateLog(), "Could not resolve the running app or its version"); return 1; }
    // One lock per installed bundle prevents a scheduled check and a manual check from swapping twice.
    int lock = open(installed.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (lock < 0) { os_log_info(updateLog(), "Could not open the installed bundle: %d", errno); return 1; }
    if (flock(lock, LOCK_EX | LOCK_NB) != 0) {
        int code = errno;
        close(lock);
        os_log_info(updateLog(), "Update check lock unavailable: %d", code);
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
        os_log_info(updateLog(), "Requesting latest public release metadata");
        BOOL notFound = NO;
        NSDictionary *release = latestRelease(session, current, &notFound);
        if (!release) return notFound ? 0 : 1;
        if (![release[@"draft"] isKindOfClass:NSNumber.class] || ![release[@"prerelease"] isKindOfClass:NSNumber.class]) {
            os_log_info(updateLog(), "Release draft or prerelease status is invalid");
            return 1;
        }
        if ([release[@"draft"] boolValue] || [release[@"prerelease"] boolValue]) {
            os_log_info(updateLog(), "Ignoring draft or prerelease");
            return 0;
        }
        NSString *version = updaterVersion(release[@"tag_name"]);
        if (!version) { os_log_info(updateLog(), "Release version is invalid"); return 1; }
        CFPreferencesSetAppValue(CFSTR("LastUpdateCheck"), (__bridge CFDateRef)NSDate.date, (__bridge CFStringRef)BundleID);
        CFPreferencesSetAppValue(CFSTR("LastUpdateCheckOSBuild"), (__bridge CFStringRef)osBuild, (__bridge CFStringRef)BundleID);
        CFPreferencesSetAppValue(CFSTR("LatestVersion"), (__bridge CFStringRef)version, (__bridge CFStringRef)BundleID);
        if (!CFPreferencesAppSynchronize((__bridge CFStringRef)BundleID)) {
            os_log_info(updateLog(), "Could not save successful update check"); return 1;
        }
        os_log_info(updateLog(), "Latest version %{public}@; installed version %{public}@", version, current);
        if (updaterCompareVersions(version, current) != NSOrderedDescending) {
            os_log_info(updateLog(), "No update needed");
            return 0;
        }
        BOOL automatic = install || preferenceEnabled(@"AutomaticallyInstallUpdates");
        if (automatic && !installRelease(session, release, version, current, installed)) return 1;
        // Resolve the main executable at the installed path after the swap, so the new app sends the notification.
        NSString *notifier = [installed URLByAppendingPathComponent:@"Contents/MacOS/NightKeys"].path;
        if (!runTool(notifier, @[@"--notify-update", version, automatic ? @"--installed" : @"--available"], 60))
            os_log_info(updateLog(), "Release notification failed; update result is unchanged");
        os_log_info(updateLog(), "Update check finished");
        return 0;
    } @finally {
        [session invalidateAndCancel];
        flock(lock, LOCK_UN);
        close(lock);
    }
}
