#ifndef route_entry_normalizer_h
#define route_entry_normalizer_h

#import <Foundation/Foundation.h>
#import "route_helper.h"

NSArray<NSDictionary*>* normalizedEntriesFromArray(NSArray* rawEntries, SYSRouteHelper* routeHelper, NSArray<NSString*>** invalidItems);
NSString* routeKeyForEntry(NSDictionary* entry);
SYSRouteAddressFamily routeEntryFamilyFromString(NSString* familyString);
NSArray<NSDictionary*>* storeEntries(void);
BOOL replaceStoreEntries(NSArray<NSDictionary*>* entries);
NSDictionary* addEntriesToStore(NSArray<NSDictionary*>* entries);
NSDictionary* removeEntriesFromStore(NSArray<NSDictionary*>* entries);
NSDictionary* clearStoreEntries(void);
NSArray<NSString*>* ipLiteralAddressesFromPath(NSString* path);

#endif /* route_entry_normalizer_h */
