#import <Foundation/Foundation.h>
#import "active_route_reconciler.h"
#import "route_command_service.h"
#import "route_entry_normalizer.h"
#import "session_state.h"

NSDictionary* routeCommandServiceHandle(NSArray<NSString*>* arguments,
                                        SYSRouteHelper* routeHelper,
                                        NSString* defaultRouteGatewayV4,
                                        NSString* defaultRouteGatewayV6,
                                        NSString* defaultRouteInterfaceV4,
                                        NSString* defaultRouteInterfaceV6,
                                        NSMutableDictionary<NSString*, NSDictionary*>* __strong *activeWhitelistRoutes,
                                        NSString* activeTunName,
                                        BOOL isExternalFDSessionValue,
                                        NSDictionary* (^requestActiveSessionBlock)(NSDictionary* request),
                                        NSString* (^currentSessionStateBlock)(void),
                                        NSDictionary* (^routeListPayloadBlock)(void),
                                        NSDictionary* (^makeResponseBlock)(BOOL ok, NSString* message, NSDictionary* payload),
                                        NSDictionary* (^updateBackupForActiveRoutesBlock)(NSString* state, NSString* lastError)) {
    (void)routeHelper;
    (void)defaultRouteGatewayV4;
    (void)defaultRouteGatewayV6;
    (void)defaultRouteInterfaceV4;
    (void)defaultRouteInterfaceV6;
    (void)activeWhitelistRoutes;
    (void)activeTunName;
    (void)isExternalFDSessionValue;
    (void)currentSessionStateBlock;
    (void)updateBackupForActiveRoutesBlock;
    if (arguments.count < 2) {
        return makeResponseBlock(NO, @"Missing route subcommand.", nil);
    }
    NSString* subcommand = arguments[1];
    BOOL requireActive = [arguments containsObject:@"--require-active"];
    NSMutableArray<NSString*>* filteredArguments = [[NSMutableArray alloc] init];
    for (NSString* argument in arguments) {
        if (![argument isEqualToString:@"--json"] && ![argument isEqualToString:@"--require-active"]) {
            [filteredArguments addObject:argument];
        }
    }
    if ([subcommand isEqualToString:@"list"]) {
        return makeResponseBlock(YES, @"Route whitelist entries.", routeListPayloadBlock());
    }
    if ([subcommand isEqualToString:@"apply"]) {
        return requestActiveSessionBlock(@{@"cmd": @"route-sync", @"entries": storeEntries()});
    }

    NSArray* rawEntries = nil;
    if ([subcommand isEqualToString:@"sync-file"]) {
        if (filteredArguments.count < 3) {
            return makeResponseBlock(NO, @"Missing path for route sync-file.", nil);
        }
        rawEntries = ipLiteralAddressesFromPath(filteredArguments[2]);
    } else if ([subcommand isEqualToString:@"clear"]) {
        rawEntries = @[];
    } else {
        if (filteredArguments.count < 3) {
            return makeResponseBlock(NO, @"Missing route IP arguments.", nil);
        }
        rawEntries = [filteredArguments subarrayWithRange:NSMakeRange(2, filteredArguments.count - 2)];
    }

    NSArray<NSString*>* invalidItems = nil;
    NSArray<NSDictionary*>* entries = normalizedEntriesFromArray(rawEntries, routeHelper, &invalidItems);
    if (invalidItems.count > 0) {
        return makeResponseBlock(NO, @"Some route entries are invalid.", @{@"invalid": invalidItems});
    }

    if ([subcommand isEqualToString:@"add"]) {
        if (requireActive) {
            NSDictionary* response = requestActiveSessionBlock(@{@"cmd": @"route-add", @"entries": entries});
            if (![response[@"ok"] boolValue] || !canTreatSessionAsActiveResponse(response)) {
                return response;
            }
            return addEntriesToStore(entries);
        }
        NSDictionary* storeResponse = addEntriesToStore(entries);
        NSDictionary* activeResponse = requestActiveSessionBlock(@{@"cmd": @"route-add", @"entries": entries});
        if ([activeResponse[@"ok"] boolValue]) {
            return makeResponseBlock(YES, @"Routes added to whitelist store and active session.", @{@"persisted": storeResponse[@"persisted"] ?: @[], @"applied": activeResponse[@"applied"] ?: @[], @"pending": @[]});
        }
        return makeResponseBlock(YES, @"Routes added to whitelist store and pending active tun session.", @{@"persisted": storeResponse[@"persisted"] ?: @[], @"applied": @[], @"pending": entries});
    }

    if ([subcommand isEqualToString:@"del"]) {
        if (requireActive) {
            NSDictionary* response = requestActiveSessionBlock(@{@"cmd": @"route-del", @"entries": entries});
            if (![response[@"ok"] boolValue] || !canTreatSessionAsActiveResponse(response)) {
                return response;
            }
            return removeEntriesFromStore(entries);
        }
        NSDictionary* storeResponse = removeEntriesFromStore(entries);
        NSDictionary* activeResponse = requestActiveSessionBlock(@{@"cmd": @"route-del", @"entries": entries});
        return makeResponseBlock(YES, [activeResponse[@"ok"] boolValue] ? @"Routes removed from whitelist store and active session." : @"Routes removed from whitelist store.", @{@"removed": storeResponse[@"removed"] ?: @[], @"activeRemoved": activeResponse[@"removed"] ?: @[]});
    }

    if ([subcommand isEqualToString:@"clear"]) {
        if (requireActive) {
            NSDictionary* response = requestActiveSessionBlock(@{@"cmd": @"route-clear"});
            if (![response[@"ok"] boolValue] || !canTreatSessionAsActiveResponse(response)) {
                return response;
            }
            return clearStoreEntries();
        }
        NSDictionary* storeResponse = clearStoreEntries();
        NSDictionary* activeResponse = requestActiveSessionBlock(@{@"cmd": @"route-clear"});
        return makeResponseBlock(YES, [activeResponse[@"ok"] boolValue] ? @"Route whitelist cleared from store and active session." : @"Route whitelist store cleared.", @{@"removed": storeResponse[@"removed"] ?: @[], @"activeRemoved": activeResponse[@"removed"] ?: @[]});
    }

    if ([subcommand isEqualToString:@"sync-file"]) {
        if (requireActive) {
            NSDictionary* response = requestActiveSessionBlock(@{@"cmd": @"route-sync", @"entries": entries});
            if (![response[@"ok"] boolValue] || !canTreatSessionAsActiveResponse(response)) {
                return response;
            }
            if (!replaceStoreEntries(entries)) {
                return makeResponseBlock(NO, @"Failed to update route whitelist store.", nil);
            }
            return makeResponseBlock(YES, @"Route whitelist synchronized to store and active session.", @{@"entries": entries, @"applied": response[@"applied"] ?: @[]});
        }
        if (!replaceStoreEntries(entries)) {
            return makeResponseBlock(NO, @"Failed to update route whitelist store.", nil);
        }
        NSDictionary* activeResponse = requestActiveSessionBlock(@{@"cmd": @"route-sync", @"entries": entries});
        return makeResponseBlock(YES, [activeResponse[@"ok"] boolValue] ? @"Route whitelist synchronized to store and active session." : @"Route whitelist stored and pending active session.", @{@"entries": entries, @"applied": activeResponse[@"applied"] ?: @[], @"pending": [activeResponse[@"ok"] boolValue] ? @[] : entries});
    }

    return makeResponseBlock(NO, @"Unknown route subcommand.", nil);
}
