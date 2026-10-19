// Shared release updater. Change the product constants in Updater.m when copying it to another app.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSString * _Nullable updaterVersion(id _Nullable value);
NSComparisonResult updaterCompareVersions(NSString *left, NSString *right);
BOOL updaterCheckDue(id _Nullable lastCheck, NSDate *now, id _Nullable lastBuild,
                     NSString * _Nullable currentBuild, BOOL enabled, BOOL force);
NSString *updaterAssetName(NSString *version);
BOOL updaterAssetSizeValid(id _Nullable value);
NSString *updaterRequirement(void);
int updaterRun(BOOL force, BOOL install);

NS_ASSUME_NONNULL_END
