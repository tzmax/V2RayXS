#ifndef tun_session_controller_h
#define tun_session_controller_h

#import <Foundation/Foundation.h>
#import "route_helper.h"

BOOL loadDefaultRouteBaseline(SYSRouteHelper* routeHelper,
                              NSString* activeTunName,
                              NSString* tunWg,
                              NSString* __strong *defaultRouteGatewayV4,
                              NSString* __strong *defaultRouteGatewayV6,
                              NSString* __strong *defaultRouteInterfaceV4,
                              NSString* __strong *defaultRouteInterfaceV6,
                              void (^syncRuntimeSessionFromBackupBlock)(void),
                              void (^syncRuntimeRouteBaselineFromBackupBlock)(void),
                              void (^hydrateBaselineRuntimeFromBackupBlock)(NSMutableDictionary* backup),
                              NSString** errorMessage);

BOOL installIPv4TakeoverRoutes(NSString* tunName,
                               SYSRouteHelper* routeHelper,
                               NSMutableArray<NSDictionary*>* __strong *activeIPv4TakeoverRoutes,
                               NSMutableDictionary* backup,
                               void (^updateRouteBackupStateBlock)(NSMutableDictionary* backup, NSString* state, NSString* lastError),
                               NSString** errorMessage);

BOOL removeIPv4TakeoverRoutes(NSString* tunName,
                              SYSRouteHelper* routeHelper,
                              NSString* defaultRouteGatewayV4,
                              NSMutableArray<NSDictionary*>* __strong *activeIPv4TakeoverRoutes,
                              NSDictionary* backup,
                              NSString** errorMessage);

void syncRuntimeSessionFromBackup(NSString* __strong *activeTunName,
                                  NSMutableArray<NSDictionary*>* __strong *activeIPv4TakeoverRoutes,
                                  NSMutableDictionary* (^loadRouteBackupBlock)(void));

void syncRuntimeRouteBaselineFromBackup(NSString* activeTunName,
                                        NSString* tunWg,
                                        SYSRouteHelper* routeHelper,
                                        NSString* __strong *defaultRouteGatewayV4,
                                        NSString* __strong *defaultRouteGatewayV6,
                                        NSString* __strong *defaultRouteInterfaceV4,
                                        NSString* __strong *defaultRouteInterfaceV6,
                                        NSMutableDictionary* (^loadRouteBackupBlock)(void));

BOOL hasUsableIPv4Baseline(SYSRouteHelper* routeHelper,
                           NSString* defaultRouteGatewayV4,
                           NSString* defaultRouteInterfaceV4);

NSDictionary* preferredNonTunDefaultRoute(SYSRouteHelper* routeHelper,
                                          NSString* defaultRouteGatewayV4,
                                          NSString* defaultRouteInterfaceV4);

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
                          void (^syncRuntimeRouteBaselineFromBackupBlock)(void),
                          void (^updateRouteBackupStateBlock)(NSMutableDictionary* backup, NSString* state, NSString* lastError));

NSString* tunSessionCurrentState(NSString* activeTunName,
                                 NSString* (^currentSessionTypeBlock)(void),
                                 NSString* (^currentSessionOwnerBlock)(void),
                                 NSString* (^currentControlPlaneBlock)(void),
                                 NSMutableDictionary* (^loadRouteBackupBlock)(void));

#endif /* tun_session_controller_h */
