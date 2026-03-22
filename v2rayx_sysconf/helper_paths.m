#import <Foundation/Foundation.h>
#import "helper_paths.h"

static NSString* const V2RayXSAppSupportRelativePath = @"Library/Application Support/V2RayXS";
static NSString* const SystemRouteBackupFilename = @"system_route_backup.plist";
static NSString* const SystemProxyBackupFilename = @"system_proxy_backup.plist";
static NSString* const RouteWhitelistStoreFilename = @"route_whitelist_store.plist";
static NSString* const TunControlSocketFilename = @"tun_route.sock";
static NSString* const TunSessionLockFilename = @"tun_session.lock";

NSString* helperAppSupportPath(void) {
    NSString* override = [[[NSProcessInfo processInfo] environment] objectForKey:@"V2RAYXS_APP_SUPPORT_PATH"];
    if (override.length > 0) {
        return override;
    }
    return [NSString stringWithFormat:@"%@/%@", NSHomeDirectory(), V2RayXSAppSupportRelativePath];
}

NSURL* helperAppSupportFileURL(NSString* filename) {
    if (filename.length == 0) {
        return nil;
    }
    return [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/%@", helperAppSupportPath(), filename]];
}

BOOL helperEnsureAppSupportDirectory(void) {
    NSError* error = nil;
    if ([[NSFileManager defaultManager] createDirectoryAtPath:helperAppSupportPath() withIntermediateDirectories:YES attributes:nil error:&error]) {
        return YES;
    }
    return error == nil;
}

NSURL* helperRouteBackupFileURL(void) {
    return helperAppSupportFileURL(SystemRouteBackupFilename);
}

NSURL* helperRouteStoreFileURL(void) {
    return helperAppSupportFileURL(RouteWhitelistStoreFilename);
}

NSURL* helperProxyBackupFileURL(void) {
    return helperAppSupportFileURL(SystemProxyBackupFilename);
}

NSString* helperControlSocketPath(void) {
    return [[helperAppSupportFileURL(TunControlSocketFilename) path] copy];
}

NSString* helperTunSessionLockPath(void) {
    return [[helperAppSupportFileURL(TunSessionLockFilename) path] copy];
}
