// Small C interface to the private macOS APIs NightKeys.app needs, so the Swift UI stays free of runtime tricks.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// True if this Mac has a built-in backlit keyboard.
BOOL NTHasBacklitKeyboard(void);

/// "Turn keyboard backlight off after inactivity", in seconds; 0 means never.
double NTIdleDimTime(void);
void NTSetIdleDimTime(double seconds);

/// "Adjust keyboard brightness in low light".
BOOL NTAutoBrightness(void);
void NTSetAutoBrightness(BOOL enabled);

/// Keyboard brightness, 0...1.
float NTBrightness(void);
void NTSetBrightness(float level);

/// Hands the keyboard backlight back to macOS: its idle timer runs again and the light is set to `level`.
void NTGiveControlToMacOS(float level);

/// Ambient light from the built-in sensor in lux, or -1 if unavailable.
double NTAmbientLux(void);

/// Calls `handler` on the main queue whenever one of the macOS keyboard backlight settings changes.
void NTObserveSystemSettings(void (^handler)(void));

NS_ASSUME_NONNULL_END
