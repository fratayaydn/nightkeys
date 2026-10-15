#import "NightKeysBridge.h"
#include <dlfcn.h>

@interface NSObject (KeyboardBrightnessClient)
- (id)copyKeyboardBacklightIDs;
- (BOOL)isKeyboardBuiltIn:(unsigned long long)k;
- (double)idleDimTimeForKeyboard:(unsigned long long)k;
- (BOOL)setIdleDimTime:(double)t forKeyboard:(unsigned long long)k;
- (BOOL)isAutoBrightnessEnabledForKeyboard:(unsigned long long)k;
- (BOOL)enableAutoBrightness:(BOOL)e forKeyboard:(unsigned long long)k;
- (float)brightnessForKeyboard:(unsigned long long)k;
- (BOOL)setBrightness:(float)b fadeSpeed:(int)f commit:(BOOL)c forKeyboard:(unsigned long long)k;
- (void)registerNotificationForKeys:(NSArray *)keys keyboardID:(unsigned long long)k block:(void (^)(id key, id value))block;
- (BOOL)suspendIdleDimming:(BOOL)s forKeyboard:(unsigned long long)k;
@end

@interface NSObject (DisplayServicesClient)
- (id)copyPropertyForKey:(id)key;
@end

static id client;
static id display;
static unsigned long long keyboard;
static BOOL found;

static void Setup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW);
        client = [NSClassFromString(@"KeyboardBrightnessClient") new];
        display = [NSClassFromString(@"DisplayServicesClient") new];
        for (NSNumber *n in [client copyKeyboardBacklightIDs]) {
            if ([client isKeyboardBuiltIn:n.unsignedLongLongValue]) {
                keyboard = n.unsignedLongLongValue;
                found = YES;
                break;
            }
        }
    });
}

BOOL NTHasBacklitKeyboard(void) { Setup(); return found; }
double NTIdleDimTime(void) { Setup(); return found ? [client idleDimTimeForKeyboard:keyboard] : 0; }
void NTSetIdleDimTime(double seconds) { Setup(); if (found) [client setIdleDimTime:seconds forKeyboard:keyboard]; }
BOOL NTAutoBrightness(void) { Setup(); return found && [client isAutoBrightnessEnabledForKeyboard:keyboard]; }
void NTSetAutoBrightness(BOOL enabled) { Setup(); if (found) [client enableAutoBrightness:enabled forKeyboard:keyboard]; }
float NTBrightness(void) { Setup(); return found ? [client brightnessForKeyboard:keyboard] : 0; }
void NTSetBrightness(float level) { Setup(); if (found) [client setBrightness:level fadeSpeed:100 commit:YES forKeyboard:keyboard]; }

void NTGiveControlToMacOS(float level) {
    Setup();
    if (!found) return;
    [client setBrightness:level fadeSpeed:150 commit:YES forKeyboard:keyboard];
    [client suspendIdleDimming:NO forKeyboard:keyboard];
}

double NTAmbientLux(void) {
    Setup();
    NSNumber *lux = [display copyPropertyForKey:@"AggregatedLux"];
    return lux ? lux.doubleValue : -1;
}

void NTObserveSystemSettings(void (^handler)(void)) {
    Setup();
    if (!found) return;
    NSArray *keys = @[ @"KeyboardBacklightIdleDimTime", @"KeyboardBacklightABEnabled", @"KeyboardBacklightBrightness" ];
    [client registerNotificationForKeys:keys keyboardID:keyboard block:^(id key, id value) {
        dispatch_async(dispatch_get_main_queue(), handler);
    }];
}
