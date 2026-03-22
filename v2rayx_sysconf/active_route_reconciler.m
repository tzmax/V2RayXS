#import <Foundation/Foundation.h>
#import "active_route_reconciler.h"
#import "route_entry_normalizer.h"
#import "route_whitelist_store.h"
#import "session_backup_store.h"

static NSDictionary* makeResponse(BOOL ok, NSString* message, NSDictionary* payload);

NSArray<NSDictionary*>* activeIPv4TakeoverRouteEntries(NSMutableArray<NSDictionary*>* activeIPv4TakeoverRoutes, NSDictionary* backup) {
    if (activeIPv4TakeoverRoutes != nil) {
        return [activeIPv4TakeoverRoutes copy];
    }
    NSArray* storedEntries = backup[ROUTE_BACKUP_IPV4_TAKEOVER_ROUTES_KEY];
    return [storedEntries isKindOfClass:[NSArray class]] ? storedEntries : @[];
}

void updateRouteBackupTakeoverRoutes(NSMutableDictionary* backup, NSMutableArray<NSDictionary*>* activeIPv4TakeoverRoutes) {
    if (backup == nil) {
        return;
    }
    backup[ROUTE_BACKUP_IPV4_TAKEOVER_ROUTES_KEY] = activeIPv4TakeoverRoutes != nil ? [activeIPv4TakeoverRoutes copy] : @[];
}

BOOL applyWhitelistEntries(NSArray<NSDictionary*>* entries,
                           SYSRouteHelper* routeHelper,
                           NSString* defaultRouteGatewayV4,
                           NSString* defaultRouteGatewayV6,
                           NSString* defaultRouteInterfaceV4,
                           NSString* defaultRouteInterfaceV6,
                           NSMutableDictionary<NSString*, NSDictionary*>* __strong *activeWhitelistRoutes,
                           NSMutableArray* appliedEntries,
                           NSMutableArray* failedEntries) {
    if (entries.count == 0) {
        return YES;
    }
    for (NSDictionary* entry in entries) {
        SYSRouteAddressFamily family = routeEntryFamilyFromString(entry[ENTRY_FAMILY_KEY]);
        NSString* gateway = family == SYSRouteAddressFamilyIPv6 ? defaultRouteGatewayV6 : defaultRouteGatewayV4;
        NSString* routeInterface = family == SYSRouteAddressFamilyIPv6 ? defaultRouteInterfaceV6 : defaultRouteInterfaceV4;
        if (family == SYSRouteAddressFamilyIPv6 && routeInterface.length == 0 && defaultRouteInterfaceV4.length > 0) {
            routeInterface = defaultRouteInterfaceV4;
        }
        BOOL didApply = NO;
        if (gateway.length > 0) {
            didApply = [routeHelper addHostRouteToDestination:entry[ENTRY_IP_KEY] gateway:gateway family:family];
        } else if (routeInterface.length > 0) {
            didApply = [routeHelper addHostRouteToDestination:entry[ENTRY_IP_KEY] interface:routeInterface family:family];
        } else {
            NSString* reason = family == SYSRouteAddressFamilyIPv6 ? @"missing IPv6 baseline gateway/interface" : @"missing IPv4 baseline gateway/interface";
            [failedEntries addObject:@{ENTRY_IP_KEY: entry[ENTRY_IP_KEY] ?: @"", @"reason": reason, ENTRY_FAMILY_KEY: entry[ENTRY_FAMILY_KEY] ?: @""}];
            continue;
        }
        if (!didApply) {
            [failedEntries addObject:@{ENTRY_IP_KEY: entry[ENTRY_IP_KEY] ?: @"", @"reason": @"failed to add route", ENTRY_FAMILY_KEY: entry[ENTRY_FAMILY_KEY] ?: @""}];
            continue;
        }
        NSMutableDictionary* appliedEntry = [entry mutableCopy];
        if (gateway.length > 0) {
            appliedEntry[ENTRY_GATEWAY_KEY] = gateway;
        }
        if (routeInterface.length > 0) {
            appliedEntry[ENTRY_INTERFACE_KEY] = routeInterface;
        }
        appliedEntry[ENTRY_APPLIED_KEY] = @YES;
        if (*activeWhitelistRoutes == nil) {
            *activeWhitelistRoutes = [[NSMutableDictionary alloc] init];
        }
        (*activeWhitelistRoutes)[routeKeyForEntry(entry)] = appliedEntry;
        [appliedEntries addObject:appliedEntry];
    }
    return [failedEntries count] == 0;
}

BOOL removeWhitelistEntries(NSArray<NSDictionary*>* entries,
                            SYSRouteHelper* routeHelper,
                            NSMutableDictionary<NSString*, NSDictionary*>* __strong *activeWhitelistRoutes,
                            NSMutableArray* removedEntries,
                            NSMutableArray* failedEntries) {
    for (NSDictionary* entry in entries) {
        NSDictionary* activeEntry = (*activeWhitelistRoutes)[routeKeyForEntry(entry)];
        if (activeEntry == nil) {
            continue;
        }
        SYSRouteAddressFamily family = routeEntryFamilyFromString(activeEntry[ENTRY_FAMILY_KEY]);
        NSString* gateway = activeEntry[ENTRY_GATEWAY_KEY];
        NSString* routeInterface = activeEntry[ENTRY_INTERFACE_KEY];
        BOOL deleted = NO;
        if ([gateway isKindOfClass:[NSString class]] && gateway.length > 0) {
            deleted = [routeHelper deleteHostRouteToDestination:activeEntry[ENTRY_IP_KEY] gateway:gateway family:family];
        } else if ([routeInterface isKindOfClass:[NSString class]] && routeInterface.length > 0) {
            deleted = [routeHelper deleteHostRouteToDestination:activeEntry[ENTRY_IP_KEY] interface:routeInterface family:family];
        }
        if (!deleted) {
            [failedEntries addObject:@{ENTRY_IP_KEY: activeEntry[ENTRY_IP_KEY] ?: @"", @"reason": @"failed to delete route"}];
            continue;
        }
        [*activeWhitelistRoutes removeObjectForKey:routeKeyForEntry(entry)];
        [removedEntries addObject:activeEntry];
    }
    return [failedEntries count] == 0;
}

NSDictionary* syncActiveWhitelistWithEntries(NSArray<NSDictionary*>* entries,
                                             BOOL replaceExisting,
                                             SYSRouteHelper* routeHelper,
                                             NSString* defaultRouteGatewayV4,
                                             NSString* defaultRouteGatewayV6,
                                             NSString* defaultRouteInterfaceV4,
                                             NSString* defaultRouteInterfaceV6,
                                             NSMutableDictionary<NSString*, NSDictionary*>* __strong *activeWhitelistRoutes,
                                             NSString* activeTunName,
                                             NSDictionary* (^backupUpdater)(NSString* state, NSString* lastError)) {
    if (*activeWhitelistRoutes == nil) {
        *activeWhitelistRoutes = [[NSMutableDictionary alloc] init];
    }
    NSMutableArray* removed = [[NSMutableArray alloc] init];
    NSMutableArray* applied = [[NSMutableArray alloc] init];
    NSMutableArray* failed = [[NSMutableArray alloc] init];
    if (replaceExisting) {
        NSMutableSet<NSString*>* desiredKeys = [[NSMutableSet alloc] init];
        for (NSDictionary* entry in entries) {
            [desiredKeys addObject:routeKeyForEntry(entry)];
        }
        NSMutableArray<NSDictionary*>* staleEntries = [[NSMutableArray alloc] init];
        for (NSDictionary* activeEntry in [*activeWhitelistRoutes allValues]) {
            if (![desiredKeys containsObject:routeKeyForEntry(activeEntry)]) {
                [staleEntries addObject:activeEntry];
            }
        }
        removeWhitelistEntries(staleEntries, routeHelper, activeWhitelistRoutes, removed, failed);
    }
    NSMutableArray<NSDictionary*>* newEntries = [[NSMutableArray alloc] init];
    for (NSDictionary* entry in entries) {
        if ((*activeWhitelistRoutes)[routeKeyForEntry(entry)] == nil) {
            [newEntries addObject:entry];
        }
    }
    applyWhitelistEntries(newEntries, routeHelper, defaultRouteGatewayV4, defaultRouteGatewayV6, defaultRouteInterfaceV4, defaultRouteInterfaceV6, activeWhitelistRoutes, applied, failed);
    if (backupUpdater != nil) {
        backupUpdater(activeTunName.length > 0 ? ROUTE_BACKUP_STATE_ACTIVE : ROUTE_BACKUP_STATE_IDLE, failed.count > 0 ? @"whitelist sync failed" : @"");
    }
    return makeResponse([failed count] == 0, [failed count] == 0 ? @"Whitelist synchronized." : @"Whitelist synchronization completed with failures.", @{@"applied": applied, @"removed": removed, @"failed": failed, @"active": [*activeWhitelistRoutes allValues] ?: @[]});
}

static NSDictionary* makeResponse(BOOL ok, NSString* message, NSDictionary* payload) {
    NSMutableDictionary* response = [[NSMutableDictionary alloc] init];
    response[@"ok"] = @(ok);
    response[@"message"] = message ?: @"";
    if (payload != nil) {
        [response addEntriesFromDictionary:payload];
    }
    return response;
}
