#ifndef route_whitelist_store_h
#define route_whitelist_store_h

#import <Foundation/Foundation.h>

extern NSString* const ROUTE_STORE_VERSION_KEY;
extern NSString* const ROUTE_STORE_ENTRIES_KEY;
extern NSString* const ENTRY_IP_KEY;
extern NSString* const ENTRY_FAMILY_KEY;
extern NSString* const ENTRY_ENABLED_KEY;
extern NSString* const ENTRY_GATEWAY_KEY;
extern NSString* const ENTRY_INTERFACE_KEY;
extern NSString* const ENTRY_APPLIED_KEY;

NSMutableDictionary* loadRouteStore(void);
BOOL saveRouteStore(NSDictionary* store);

#endif /* route_whitelist_store_h */
