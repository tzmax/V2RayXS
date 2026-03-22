#import <Foundation/Foundation.h>
#import "active_route_reconciler.h"
#import "session_backup_store.h"
#import "tun_session_controller.h"

static NSArray<NSString*>* const IPv4TakeoverCIDRs = @[@"0.0.0.0/1", @"128.0.0.0/1"];

static BOOL isTunManagedIPv4Route(NSString* gateway, NSString* interfaceName, NSString* activeTunName, NSString* tunWg);

BOOL loadDefaultRouteBaseline(SYSRouteHelper* routeHelper,
                              NSString* activeTunName,
                              NSString* tunWg,
                              NSString* __strong *defaultRouteGatewayV4,
                              NSString* __strong *defaultRouteGatewayV6,
                              NSString* __strong *defaultRouteInterfaceV4,
                              NSString* __strong *defaultRouteInterfaceV6,
                              void (^syncRuntimeSessionFromBackupBlock)(void),
                              NSString** errorMessage) {
    if (syncRuntimeSessionFromBackupBlock != nil) {
        syncRuntimeSessionFromBackupBlock();
    }
    NSDictionary* preferredDefaultRouteV4 = preferredNonTunDefaultRoute(routeHelper, defaultRouteGatewayV4 != NULL ? *defaultRouteGatewayV4 : @"", defaultRouteInterfaceV4 != NULL ? *defaultRouteInterfaceV4 : @"");
    if (defaultRouteGatewayV4 != NULL) *defaultRouteGatewayV4 = preferredDefaultRouteV4[@"gateway"] ?: @"";
    if (defaultRouteGatewayV6 != NULL) *defaultRouteGatewayV6 = [routeHelper getDefaultRouteGatewayForFamily:SYSRouteAddressFamilyIPv6] ?: @"";
    if (defaultRouteInterfaceV4 != NULL) *defaultRouteInterfaceV4 = preferredDefaultRouteV4[@"interface"] ?: @"";
    if (defaultRouteInterfaceV6 != NULL) *defaultRouteInterfaceV6 = [routeHelper getDefaultRouteInterfaceForFamily:SYSRouteAddressFamilyIPv6] ?: @"";

    if (isTunManagedIPv4Route(defaultRouteGatewayV4 != NULL ? *defaultRouteGatewayV4 : @"", defaultRouteInterfaceV4 != NULL ? *defaultRouteInterfaceV4 : @"", activeTunName, tunWg)) {
        if (defaultRouteGatewayV4 != NULL) *defaultRouteGatewayV4 = @"";
        if (defaultRouteInterfaceV4 != NULL) *defaultRouteInterfaceV4 = @"";
    }

    if (defaultRouteGatewayV4 != NULL && ![routeHelper isValidGateway:*defaultRouteGatewayV4]) {
        *defaultRouteGatewayV4 = @"";
    }

    if (!hasUsableIPv4Baseline(routeHelper, defaultRouteGatewayV4 != NULL ? *defaultRouteGatewayV4 : @"", defaultRouteInterfaceV4 != NULL ? *defaultRouteInterfaceV4 : @"")) {
        if (errorMessage != NULL) {
            *errorMessage = @"Unable to determine current default IPv4 route baseline.";
        }
        return NO;
    }

    return YES;
}

BOOL installIPv4TakeoverRoutes(NSString* tunName,
                               SYSRouteHelper* routeHelper,
                               NSMutableArray<NSDictionary*>* __strong *activeIPv4TakeoverRoutes,
                               NSMutableDictionary* backup,
                               void (^updateRouteBackupStateBlock)(NSMutableDictionary* backup, NSString* state, NSString* lastError),
                               NSString** errorMessage) {
    if (tunName.length == 0) {
        if (errorMessage != NULL) {
            *errorMessage = @"Missing tun interface for IPv4 takeover routes.";
        }
        return NO;
    }
    *activeIPv4TakeoverRoutes = [[NSMutableArray alloc] init];
    for (NSString* cidr in IPv4TakeoverCIDRs) {
        if (![routeHelper addNetworkRouteToDestination:cidr interface:tunName family:SYSRouteAddressFamilyIPv4]) {
            if (errorMessage != NULL) {
                *errorMessage = [NSString stringWithFormat:@"Failed to install IPv4 takeover route %@.", cidr];
            }
            if (backup != nil && updateRouteBackupStateBlock != nil) {
                updateRouteBackupStateBlock(backup, ROUTE_BACKUP_STATE_SWITCHING, @"ipv4 takeover install failed");
            }
            return NO;
        }
        [*activeIPv4TakeoverRoutes addObject:@{@"cidr": cidr, @"interface": tunName, @"family": @"ipv4"}];
    }
    updateRouteBackupTakeoverRoutes(backup, *activeIPv4TakeoverRoutes);
    return YES;
}

BOOL removeIPv4TakeoverRoutes(NSString* tunName,
                              SYSRouteHelper* routeHelper,
                              NSString* defaultRouteGatewayV4,
                              NSMutableArray<NSDictionary*>* __strong *activeIPv4TakeoverRoutes,
                              NSDictionary* backup,
                              NSString** errorMessage) {
    BOOL ok = YES;
    NSArray<NSDictionary*>* takeoverEntries = activeIPv4TakeoverRouteEntries(*activeIPv4TakeoverRoutes, backup);
    for (NSDictionary* entry in takeoverEntries) {
        NSString* cidr = entry[@"cidr"] ?: @"";
        NSString* entryInterface = entry[@"interface"] ?: tunName ?: @"";
        BOOL removed = NO;
        if (entryInterface.length > 0) {
            removed = [routeHelper deleteNetworkRouteToDestination:cidr interface:entryInterface family:SYSRouteAddressFamilyIPv4];
        } else {
            removed = YES;
        }
        if (!removed && defaultRouteGatewayV4.length > 0) {
            removed = [routeHelper deleteNetworkRouteToDestination:cidr gateway:defaultRouteGatewayV4 family:SYSRouteAddressFamilyIPv4];
        }
        ok = removed && ok;
        if (!removed && errorMessage != NULL) {
            *errorMessage = [NSString stringWithFormat:@"Failed to remove IPv4 takeover route %@.", cidr];
        }
    }
    if (*activeIPv4TakeoverRoutes == nil) {
        *activeIPv4TakeoverRoutes = [[NSMutableArray alloc] init];
    } else {
        [*activeIPv4TakeoverRoutes removeAllObjects];
    }
    return ok;
}

void syncRuntimeSessionFromBackup(NSString* __strong *activeTunName,
                                  NSMutableArray<NSDictionary*>* __strong *activeIPv4TakeoverRoutes,
                                  NSMutableDictionary* (^loadRouteBackupBlock)(void)) {
    NSMutableDictionary* backup = loadRouteBackupBlock != nil ? loadRouteBackupBlock() : loadRouteBackup();
    if ((*activeTunName).length == 0 && backupRepresentsRecoverableActiveSession(backup)) {
        *activeTunName = backup[ROUTE_BACKUP_TUN_NAME_KEY] ?: @"";
    }
    if (*activeIPv4TakeoverRoutes == nil) {
        NSArray* storedRoutes = backup[ROUTE_BACKUP_IPV4_TAKEOVER_ROUTES_KEY];
        *activeIPv4TakeoverRoutes = [storedRoutes isKindOfClass:[NSArray class]] ? [storedRoutes mutableCopy] : [[NSMutableArray alloc] init];
    }
}

BOOL hasUsableIPv4Baseline(SYSRouteHelper* routeHelper,
                           NSString* defaultRouteGatewayV4,
                           NSString* defaultRouteInterfaceV4) {
    return (defaultRouteGatewayV4.length > 0 && [routeHelper isValidGateway:defaultRouteGatewayV4]) || defaultRouteInterfaceV4.length > 0;
}

NSDictionary* preferredNonTunDefaultRoute(SYSRouteHelper* routeHelper,
                                          NSString* defaultRouteGatewayV4,
                                          NSString* defaultRouteInterfaceV4) {
    NSArray<NSDictionary*>* defaults = [routeHelper defaultRoutesForFamily:SYSRouteAddressFamilyIPv4];
    for (NSDictionary* route in defaults) {
        NSString* interfaceName = route[@"interface"] ?: @"";
        NSString* gateway = route[@"gateway"] ?: @"";
        if ([interfaceName hasPrefix:@"utun"]) {
            continue;
        }
        if (interfaceName.length == 0 && gateway.length == 0) {
            continue;
        }
        return route;
    }
    return @{@"gateway": defaultRouteGatewayV4 ?: @"", @"interface": defaultRouteInterfaceV4 ?: @""};
}

void resetTunRuntimeState(NSMutableDictionary* routeBackup,
                          NSString* state,
                          NSString* lastError,
                          NSMutableDictionary<NSString*, NSDictionary*>* activeWhitelistRoutes,
                          NSMutableArray<NSDictionary*>* __strong *activeIPv4TakeoverRoutes,
                          NSString* __strong *activeTunName,
                          NSString* __strong *defaultRouteGatewayV4,
                          NSString* __strong *defaultRouteGatewayV6,
                          NSString* __strong *defaultRouteInterfaceV4,
                          NSString* __strong *defaultRouteInterfaceV6,
                          void (^updateRouteBackupStateBlock)(NSMutableDictionary* backup, NSString* state, NSString* lastError)) {
    if (activeTunName != NULL) *activeTunName = @"";
    if (defaultRouteGatewayV4 != NULL) *defaultRouteGatewayV4 = @"";
    if (defaultRouteGatewayV6 != NULL) *defaultRouteGatewayV6 = @"";
    if (defaultRouteInterfaceV4 != NULL) *defaultRouteInterfaceV4 = @"";
    if (defaultRouteInterfaceV6 != NULL) *defaultRouteInterfaceV6 = @"";
    [activeWhitelistRoutes removeAllObjects];
    if (*activeIPv4TakeoverRoutes == nil) {
        *activeIPv4TakeoverRoutes = [[NSMutableArray alloc] init];
    } else {
        [*activeIPv4TakeoverRoutes removeAllObjects];
    }
    if (updateRouteBackupStateBlock != nil) {
        updateRouteBackupStateBlock(routeBackup, state ?: ROUTE_BACKUP_STATE_IDLE, lastError ?: @"");
    }
}

NSString* tunSessionCurrentState(NSString* activeTunName,
                                 NSString* (^currentSessionTypeBlock)(void),
                                 NSString* (^currentSessionOwnerBlock)(void),
                                 NSString* (^currentControlPlaneBlock)(void),
                                 NSMutableDictionary* (^loadRouteBackupBlock)(void)) {
    NSMutableDictionary* backup = loadRouteBackupBlock != nil ? loadRouteBackupBlock() : loadRouteBackup();
    NSString* state = activeTunName.length > 0 ? ROUTE_BACKUP_STATE_ACTIVE : backup[ROUTE_BACKUP_STATE_KEY];
    NSString* backupTunName = backup[ROUTE_BACKUP_TUN_NAME_KEY];
    NSArray* backupTakeoverRoutes = [backup[ROUTE_BACKUP_IPV4_TAKEOVER_ROUTES_KEY] isKindOfClass:[NSArray class]] ? backup[ROUTE_BACKUP_IPV4_TAKEOVER_ROUTES_KEY] : @[];
    NSString* currentSessionTypeValue = currentSessionTypeBlock != nil ? currentSessionTypeBlock() : SESSION_TYPE_NONE;
    NSString* currentSessionOwnerValue = currentSessionOwnerBlock != nil ? currentSessionOwnerBlock() : SESSION_OWNER_NONE;
    NSString* currentControlPlaneValue = currentControlPlaneBlock != nil ? currentControlPlaneBlock() : CONTROL_PLANE_NONE;
    if ((state.length == 0 || [state isEqualToString:ROUTE_BACKUP_STATE_IDLE]) && ![currentSessionTypeValue isEqualToString:SESSION_TYPE_NONE] && backupTakeoverRoutes.count > 0 && [backupTunName isKindOfClass:[NSString class]] && backupTunName.length > 0) {
        state = ROUTE_BACKUP_STATE_ACTIVE;
    }
    if ([state isEqualToString:ROUTE_BACKUP_STATE_SWITCHING] && [currentSessionTypeValue isEqualToString:SESSION_TYPE_NONE] && [currentSessionOwnerValue isEqualToString:SESSION_OWNER_NONE] && [currentControlPlaneValue isEqualToString:CONTROL_PLANE_NONE] && backupTakeoverRoutes.count == 0) {
        state = ROUTE_BACKUP_STATE_IDLE;
    }
    if (state.length == 0 || [state isEqualToString:ROUTE_BACKUP_STATE_IDLE]) {
        return @"inactive";
    }
    return state;
}

static BOOL isTunManagedIPv4Route(NSString* gateway, NSString* interfaceName, NSString* activeTunName, NSString* tunWg) {
    if ([gateway isKindOfClass:[NSString class]] && [gateway isEqualToString:tunWg]) {
        return YES;
    }
    if ([interfaceName isKindOfClass:[NSString class]] && interfaceName.length > 0 && activeTunName.length > 0 && [interfaceName isEqualToString:activeTunName]) {
        return YES;
    }
    return NO;
}
