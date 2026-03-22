#ifndef active_route_reconciler_h
#define active_route_reconciler_h

#import <Foundation/Foundation.h>
#import "route_helper.h"

NSArray<NSDictionary*>* activeIPv4TakeoverRouteEntries(NSMutableArray<NSDictionary*>* activeIPv4TakeoverRoutes, NSDictionary* backup);
void updateRouteBackupTakeoverRoutes(NSMutableDictionary* backup, NSMutableArray<NSDictionary*>* activeIPv4TakeoverRoutes);
BOOL applyWhitelistEntries(NSArray<NSDictionary*>* entries,
                           SYSRouteHelper* routeHelper,
                           NSString* defaultRouteGatewayV4,
                           NSString* defaultRouteGatewayV6,
                           NSString* defaultRouteInterfaceV4,
                           NSString* defaultRouteInterfaceV6,
                           NSMutableDictionary<NSString*, NSDictionary*>* __strong *activeWhitelistRoutes,
                           NSMutableArray* appliedEntries,
                           NSMutableArray* failedEntries);
BOOL removeWhitelistEntries(NSArray<NSDictionary*>* entries,
                            SYSRouteHelper* routeHelper,
                            NSMutableDictionary<NSString*, NSDictionary*>* __strong *activeWhitelistRoutes,
                            NSMutableArray* removedEntries,
                            NSMutableArray* failedEntries);
NSDictionary* syncActiveWhitelistWithEntries(NSArray<NSDictionary*>* entries,
                                             BOOL replaceExisting,
                                             SYSRouteHelper* routeHelper,
                                             NSString* defaultRouteGatewayV4,
                                             NSString* defaultRouteGatewayV6,
                                             NSString* defaultRouteInterfaceV4,
                                             NSString* defaultRouteInterfaceV6,
                                             NSMutableDictionary<NSString*, NSDictionary*>* __strong *activeWhitelistRoutes,
                                             NSString* activeTunName,
                                             NSDictionary* (^backupUpdater)(NSString* state, NSString* lastError));

#endif /* active_route_reconciler_h */
