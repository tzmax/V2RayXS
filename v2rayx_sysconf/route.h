//
//  route.h
//  V2RayXS
//
//  Created by tzmax on 2023/1/23.
//  Copyright © 2023 Project V2Ray. All rights reserved.
//

#ifndef route_h
#define route_h

@interface SYSRouteHelper : NSObject {}

-(NSString*) getRouteGateway:(NSString*) rule;

-(NSString*) getDefaultRouteGateway;

-(void) upInterface:(NSString*) interfaceName;

-(void) routeAdd:(NSString*) rule gateway:(NSString*) gateway;

-(void) routeDelete:(NSString*) rule gateway:(NSString*) gateway;

@end

#endif /* route_h */
