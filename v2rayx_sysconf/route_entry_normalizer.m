#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import "route_entry_normalizer.h"
#import "route_whitelist_store.h"

static NSDictionary* makeResponse(BOOL ok, NSString* message, NSDictionary* payload);
static NSString* familyStringForFamily(SYSRouteAddressFamily family);
static NSString* normalizedIPAddressString(NSString* ipAddress, SYSRouteAddressFamily family);

NSArray<NSDictionary*>* normalizedEntriesFromArray(NSArray* rawEntries, SYSRouteHelper* routeHelper, NSArray<NSString*>** invalidItems) {
    NSMutableArray<NSDictionary*>* entries = [[NSMutableArray alloc] init];
    NSMutableArray<NSString*>* invalid = [[NSMutableArray alloc] init];
    NSMutableSet<NSString*>* seenKeys = [[NSMutableSet alloc] init];
    for (id item in rawEntries) {
        NSString* ipAddress = nil;
        NSString* familyString = nil;
        if ([item isKindOfClass:[NSString class]]) {
            ipAddress = item;
        } else if ([item isKindOfClass:[NSDictionary class]]) {
            ipAddress = item[ENTRY_IP_KEY];
            familyString = item[ENTRY_FAMILY_KEY];
        }
        SYSRouteAddressFamily family = SYSRouteAddressFamilyIPv4;
        if (familyString.length > 0) {
            family = routeEntryFamilyFromString(familyString);
        } else {
            SYSRouteAddressFamily detectedFamily = SYSRouteAddressFamilyIPv4;
            if (![routeHelper isValidIPAddress:ipAddress family:&detectedFamily]) {
                [invalid addObject:(ipAddress ?: @"<invalid>")];
                continue;
            }
            family = detectedFamily;
        }
        NSString* normalizedIP = normalizedIPAddressString(ipAddress, family);
        if (normalizedIP.length == 0) {
            [invalid addObject:(ipAddress ?: @"<invalid>")];
            continue;
        }
        NSDictionary* entry = @{
            ENTRY_IP_KEY: normalizedIP,
            ENTRY_FAMILY_KEY: familyStringForFamily(family),
            ENTRY_ENABLED_KEY: @YES,
        };
        NSString* key = routeKeyForEntry(entry);
        if ([seenKeys containsObject:key]) {
            continue;
        }
        [seenKeys addObject:key];
        [entries addObject:entry];
    }
    if (invalidItems != NULL) {
        *invalidItems = invalid;
    }
    return entries;
}

NSString* routeKeyForEntry(NSDictionary* entry) {
    return [NSString stringWithFormat:@"%@:%@", entry[ENTRY_FAMILY_KEY] ?: @"ipv4", entry[ENTRY_IP_KEY] ?: @""];
}

SYSRouteAddressFamily routeEntryFamilyFromString(NSString* familyString) {
    return [familyString isEqualToString:@"ipv6"] ? SYSRouteAddressFamilyIPv6 : SYSRouteAddressFamilyIPv4;
}

NSArray<NSDictionary*>* storeEntries(void) {
    return [loadRouteStore()[ROUTE_STORE_ENTRIES_KEY] copy] ?: @[];
}

BOOL replaceStoreEntries(NSArray<NSDictionary*>* entries) {
    NSMutableDictionary* store = loadRouteStore();
    store[ROUTE_STORE_ENTRIES_KEY] = entries ?: @[];
    return saveRouteStore(store);
}

NSDictionary* addEntriesToStore(NSArray<NSDictionary*>* entries) {
    NSMutableArray<NSDictionary*>* mergedEntries = [[storeEntries() mutableCopy] ?: [NSMutableArray array] mutableCopy];
    NSMutableSet<NSString*>* existingKeys = [[NSMutableSet alloc] init];
    for (NSDictionary* entry in mergedEntries) {
        [existingKeys addObject:routeKeyForEntry(entry)];
    }
    NSMutableArray* added = [[NSMutableArray alloc] init];
    for (NSDictionary* entry in entries) {
        NSString* key = routeKeyForEntry(entry);
        if ([existingKeys containsObject:key]) {
            continue;
        }
        [existingKeys addObject:key];
        [mergedEntries addObject:entry];
        [added addObject:entry];
    }
    if (!replaceStoreEntries(mergedEntries)) {
        return makeResponse(NO, @"Failed to update route whitelist store.", nil);
    }
    return makeResponse(YES, @"Routes added to whitelist store.", @{@"persisted": added, @"entries": mergedEntries});
}

NSDictionary* removeEntriesFromStore(NSArray<NSDictionary*>* entries) {
    NSMutableSet<NSString*>* keysToRemove = [[NSMutableSet alloc] init];
    for (NSDictionary* entry in entries) {
        [keysToRemove addObject:routeKeyForEntry(entry)];
    }
    NSMutableArray<NSDictionary*>* updatedEntries = [[NSMutableArray alloc] init];
    NSMutableArray<NSDictionary*>* removed = [[NSMutableArray alloc] init];
    for (NSDictionary* entry in storeEntries()) {
        if ([keysToRemove containsObject:routeKeyForEntry(entry)]) {
            [removed addObject:entry];
        } else {
            [updatedEntries addObject:entry];
        }
    }
    if (!replaceStoreEntries(updatedEntries)) {
        return makeResponse(NO, @"Failed to update route whitelist store.", nil);
    }
    return makeResponse(YES, @"Routes removed from whitelist store.", @{@"removed": removed, @"entries": updatedEntries});
}

NSDictionary* clearStoreEntries(void) {
    NSArray<NSDictionary*>* previousEntries = storeEntries();
    if (!replaceStoreEntries(@[])) {
        return makeResponse(NO, @"Failed to clear route whitelist store.", nil);
    }
    return makeResponse(YES, @"Route whitelist store cleared.", @{@"removed": previousEntries});
}

NSArray<NSString*>* ipLiteralAddressesFromPath(NSString* path) {
    NSData* data = [NSData dataWithContentsOfFile:path];
    if (data == nil) {
        return @[];
    }
    id jsonObject = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([jsonObject isKindOfClass:[NSArray class]]) {
        return jsonObject;
    }
    if ([jsonObject isKindOfClass:[NSDictionary class]]) {
        NSArray* entries = jsonObject[@"entries"];
        if ([entries isKindOfClass:[NSArray class]]) {
            return entries;
        }
    }
    return @[];
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

static NSString* familyStringForFamily(SYSRouteAddressFamily family) {
    return family == SYSRouteAddressFamilyIPv6 ? @"ipv6" : @"ipv4";
}

static NSString* normalizedIPAddressString(NSString* ipAddress, SYSRouteAddressFamily family) {
    if (ipAddress.length == 0) {
        return nil;
    }
    char buffer[INET6_ADDRSTRLEN] = {0};
    if (family == SYSRouteAddressFamilyIPv4) {
        struct in_addr ipv4Addr;
        if (inet_pton(AF_INET, [ipAddress UTF8String], &ipv4Addr) != 1) {
            return nil;
        }
        if (inet_ntop(AF_INET, &ipv4Addr, buffer, sizeof(buffer)) == NULL) {
            return nil;
        }
    } else {
        struct in6_addr ipv6Addr;
        if (inet_pton(AF_INET6, [ipAddress UTF8String], &ipv6Addr) != 1) {
            return nil;
        }
        if (inet_ntop(AF_INET6, &ipv6Addr, buffer, sizeof(buffer)) == NULL) {
            return nil;
        }
    }
    return [NSString stringWithUTF8String:buffer];
}
