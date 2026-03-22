#ifndef route_command_service_h
#define route_command_service_h

#import <Foundation/Foundation.h>
#import "route_helper.h"

NSDictionary* routeCommandServiceHandle(NSArray<NSString*>* arguments,
                                        SYSRouteHelper* routeHelper,
                                        NSString* defaultRouteGatewayV4,
                                        NSString* defaultRouteGatewayV6,
                                        NSString* defaultRouteInterfaceV4,
                                        NSString* defaultRouteInterfaceV6,
                                        NSMutableDictionary<NSString*, NSDictionary*>* __strong *activeWhitelistRoutes,
                                        NSString* activeTunName,
                                        BOOL isExternalFDSession,
                                        NSDictionary* (^requestActiveSessionBlock)(NSDictionary* request),
                                        NSString* (^currentSessionStateBlock)(void),
                                        NSDictionary* (^routeListPayloadBlock)(void),
                                        NSDictionary* (^makeResponseBlock)(BOOL ok, NSString* message, NSDictionary* payload),
                                        NSDictionary* (^updateBackupForActiveRoutesBlock)(NSString* state, NSString* lastError));

#endif /* route_command_service_h */
