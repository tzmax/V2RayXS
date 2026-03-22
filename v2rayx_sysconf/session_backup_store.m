#import "session_backup_store.h"
#import "helper_paths.h"

NSString* const ROUTE_BACKUP_VERSION_KEY = @"Version";
NSString* const ROUTE_BACKUP_STATE_KEY = @"RouteState";
NSString* const ROUTE_BACKUP_STATE_IDLE = @"idle";
NSString* const ROUTE_BACKUP_STATE_SWITCHING = @"switching";
NSString* const ROUTE_BACKUP_STATE_ACTIVE = @"active";
NSString* const ROUTE_BACKUP_TUN_NAME_KEY = @"TunName";
NSString* const ROUTE_BACKUP_WHITELIST_ROUTES_KEY = @"WhitelistRoutes";
NSString* const ROUTE_BACKUP_IPV4_TAKEOVER_ROUTES_KEY = @"IPv4TakeoverRoutes";
NSString* const ROUTE_BACKUP_LAST_ERROR_KEY = @"LastError";
NSString* const ROUTE_BACKUP_SESSION_TYPE_KEY = @"SessionType";
NSString* const ROUTE_BACKUP_SESSION_OWNER_KEY = @"SessionOwner";
NSString* const ROUTE_BACKUP_CONTROL_PLANE_KEY = @"ControlPlane";

NSString* const SESSION_TYPE_NONE = @"none";
NSString* const SESSION_TYPE_INTERNAL = @"internal";
NSString* const SESSION_TYPE_EXTERNAL_FD = @"external_fd";
NSString* const SESSION_OWNER_NONE = @"none";
NSString* const SESSION_OWNER_HELPER = @"helper";
NSString* const SESSION_OWNER_EXTERNAL = @"external";
NSString* const CONTROL_PLANE_NONE = @"none";
NSString* const CONTROL_PLANE_SOCKET = @"socket";
NSString* const CONTROL_PLANE_STATELESS = @"stateless";

NSMutableDictionary* loadRouteBackup(void) {
    NSMutableDictionary* backup = [NSMutableDictionary dictionaryWithContentsOfURL:helperRouteBackupFileURL()] ?: [[NSMutableDictionary alloc] init];
    backup = sanitizeLegacyRouteBackup(backup);
    backup[ROUTE_BACKUP_VERSION_KEY] = @2;
    if (backup[ROUTE_BACKUP_STATE_KEY] == nil) {
        backup[ROUTE_BACKUP_STATE_KEY] = ROUTE_BACKUP_STATE_IDLE;
    }
    if (backup[ROUTE_BACKUP_TUN_NAME_KEY] == nil) {
        backup[ROUTE_BACKUP_TUN_NAME_KEY] = @"";
    }
    if (backup[ROUTE_BACKUP_WHITELIST_ROUTES_KEY] == nil) {
        backup[ROUTE_BACKUP_WHITELIST_ROUTES_KEY] = @[];
    }
    if (backup[ROUTE_BACKUP_IPV4_TAKEOVER_ROUTES_KEY] == nil) {
        backup[ROUTE_BACKUP_IPV4_TAKEOVER_ROUTES_KEY] = @[];
    }
    if (backup[ROUTE_BACKUP_LAST_ERROR_KEY] == nil) {
        backup[ROUTE_BACKUP_LAST_ERROR_KEY] = @"";
    }
    if (backup[ROUTE_BACKUP_SESSION_TYPE_KEY] == nil) {
        backup[ROUTE_BACKUP_SESSION_TYPE_KEY] = SESSION_TYPE_NONE;
    }
    if (backup[ROUTE_BACKUP_SESSION_OWNER_KEY] == nil) {
        backup[ROUTE_BACKUP_SESSION_OWNER_KEY] = SESSION_OWNER_NONE;
    }
    if (backup[ROUTE_BACKUP_CONTROL_PLANE_KEY] == nil) {
        backup[ROUTE_BACKUP_CONTROL_PLANE_KEY] = CONTROL_PLANE_NONE;
    }
    return backup;
}

BOOL saveRouteBackup(NSMutableDictionary* backup) {
    helperEnsureAppSupportDirectory();
    backup = sanitizeLegacyRouteBackup(backup);
    return [backup writeToURL:helperRouteBackupFileURL() atomically:NO];
}

NSMutableDictionary* sanitizeLegacyRouteBackup(NSMutableDictionary* backup) {
    if (backup == nil) {
        return [[NSMutableDictionary alloc] init];
    }

    NSArray<NSString*>* legacyKeys = @[@"DefaultRouteGateway", @"DefaultRouteSwitched", @"DefaultRouteGatewayV4", @"DefaultRouteGatewayV6", @"DefaultRouteInterfaceV4", @"DefaultRouteInterfaceV6"];
    for (NSString* key in legacyKeys) {
        [backup removeObjectForKey:key];
    }

    if (!backupRepresentsRecoverableActiveSession(backup)) {
        backup[ROUTE_BACKUP_STATE_KEY] = ROUTE_BACKUP_STATE_IDLE;
        backup[ROUTE_BACKUP_TUN_NAME_KEY] = @"";
        backup[ROUTE_BACKUP_SESSION_TYPE_KEY] = SESSION_TYPE_NONE;
        backup[ROUTE_BACKUP_SESSION_OWNER_KEY] = SESSION_OWNER_NONE;
        backup[ROUTE_BACKUP_CONTROL_PLANE_KEY] = CONTROL_PLANE_NONE;
        backup[ROUTE_BACKUP_IPV4_TAKEOVER_ROUTES_KEY] = @[];
        backup[ROUTE_BACKUP_WHITELIST_ROUTES_KEY] = @[];
        if (![backup[ROUTE_BACKUP_LAST_ERROR_KEY] isKindOfClass:[NSString class]]) {
            backup[ROUTE_BACKUP_LAST_ERROR_KEY] = @"";
        }
    }

    return backup;
}

BOOL backupRepresentsRecoverableActiveSession(NSDictionary* backup) {
    (void)backup;
    return NO;
}
