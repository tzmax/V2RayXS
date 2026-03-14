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

@interface SYSRouteHelper : NSObject {}

-(NSString*) getRouteGateway:(NSString*) rule;

-(NSString*) getDefaultRouteGateway;

-(BOOL) isValidGateway:(NSString*) gateway;

-(BOOL) hasRoute:(NSString*) rule gateway:(NSString*) gateway;

-(BOOL) upInterface:(NSString*) interfaceName;

-(BOOL) routeAdd:(NSString*) rule gateway:(NSString*) gateway;

-(BOOL) routeDelete:(NSString*) rule gateway:(NSString*) gateway;

@end

#endif /* route_h */
