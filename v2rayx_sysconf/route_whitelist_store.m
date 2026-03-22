#import "route_whitelist_store.h"
#import "helper_paths.h"

NSString* const ROUTE_STORE_VERSION_KEY = @"Version";
NSString* const ROUTE_STORE_ENTRIES_KEY = @"Entries";
NSString* const ENTRY_IP_KEY = @"ip";
NSString* const ENTRY_FAMILY_KEY = @"family";
NSString* const ENTRY_ENABLED_KEY = @"enabled";
NSString* const ENTRY_GATEWAY_KEY = @"gateway";
NSString* const ENTRY_INTERFACE_KEY = @"interface";
NSString* const ENTRY_APPLIED_KEY = @"applied";

NSMutableDictionary* loadRouteStore(void) {
    NSMutableDictionary* store = [NSMutableDictionary dictionaryWithContentsOfURL:helperRouteStoreFileURL()] ?: [[NSMutableDictionary alloc] init];
    store[ROUTE_STORE_VERSION_KEY] = @1;
    if (store[ROUTE_STORE_ENTRIES_KEY] == nil) {
        store[ROUTE_STORE_ENTRIES_KEY] = @[];
    }
    return store;
}

BOOL saveRouteStore(NSDictionary* store) {
    helperEnsureAppSupportDirectory();
    return [store writeToURL:helperRouteStoreFileURL() atomically:NO];
}
