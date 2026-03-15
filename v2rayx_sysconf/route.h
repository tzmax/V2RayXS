//
//  route.h
//  V2RayXS
//
//  Created by tzmax on 2023/1/23.
//  Copyright © 2023 Project V2Ray. All rights reserved.
//

#ifndef route_h
#define route_h

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SYSRouteAddressFamily) {
    SYSRouteAddressFamilyIPv4 = 4,
    SYSRouteAddressFamilyIPv6 = 6,
};

@interface SYSRouteHelper : NSObject {}

-(NSString*) getRouteGateway:(NSString*) rule;

-(NSString*) getRouteGateway:(NSString*) rule family:(SYSRouteAddressFamily)family;

-(NSString*) getDefaultRouteGateway;

-(NSString*) getDefaultRouteGatewayForFamily:(SYSRouteAddressFamily)family;

-(NSString*) getRouteInterface:(NSString*) rule family:(SYSRouteAddressFamily)family;

-(NSString*) getDefaultRouteInterfaceForFamily:(SYSRouteAddressFamily)family;

-(BOOL) isValidGateway:(NSString*) gateway;

-(BOOL) isValidIPAddress:(NSString*) ipAddress family:(SYSRouteAddressFamily*)familyOut;

-(BOOL) hasRoute:(NSString*) rule gateway:(NSString*) gateway;

-(BOOL) hasDefaultRouteViaGateway:(NSString*) gateway family:(SYSRouteAddressFamily)family;

-(BOOL) hasHostRouteToDestination:(NSString*) destination gateway:(NSString*) gateway family:(SYSRouteAddressFamily)family;

-(BOOL) upInterface:(NSString*) interfaceName;

-(BOOL) routeAdd:(NSString*) rule gateway:(NSString*) gateway;

-(BOOL) routeDelete:(NSString*) rule gateway:(NSString*) gateway;

-(BOOL) addDefaultRouteViaGateway:(NSString*) gateway family:(SYSRouteAddressFamily)family;

-(BOOL) deleteDefaultRouteViaGateway:(NSString*) gateway family:(SYSRouteAddressFamily)family;

-(BOOL) deleteDefaultRouteForFamily:(SYSRouteAddressFamily)family;

-(BOOL) hasDefaultRouteViaInterface:(NSString*) interfaceName family:(SYSRouteAddressFamily)family;

-(BOOL) addDefaultRouteViaInterface:(NSString*) interfaceName family:(SYSRouteAddressFamily)family;

-(BOOL) deleteDefaultRouteViaInterface:(NSString*) interfaceName family:(SYSRouteAddressFamily)family;

-(BOOL) addHostRouteToDestination:(NSString*) destination gateway:(NSString*) gateway family:(SYSRouteAddressFamily)family;

-(BOOL) deleteHostRouteToDestination:(NSString*) destination gateway:(NSString*) gateway family:(SYSRouteAddressFamily)family;

-(BOOL) addHostRouteToDestination:(NSString*) destination interface:(NSString*) interfaceName family:(SYSRouteAddressFamily)family;

-(BOOL) deleteHostRouteToDestination:(NSString*) destination interface:(NSString*) interfaceName family:(SYSRouteAddressFamily)family;

@end

#endif /* route_h */
