//
//  route.m
//  v2rayx_sysconf
//
//  Created by tzmax on 2023/1/23.
//  Copyright © 2023 Project V2Ray. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "route.h"


@implementation SYSRouteHelper : NSObject


-(void) upInterface:(NSString*) interfaceName {
    if (interfaceName == NULL) {
        return;
    }
    NSString* cmd = [[NSString alloc] initWithFormat: @"/sbin/ifconfig %@ up", interfaceName];
    runCommandScript(cmd);
}

-(void) routeAdd:(NSString*) rule gateway:(NSString*) gateway {
    if (rule == NULL || gateway == NULL) {
        return;
    }
    NSString* cmd = [[NSString alloc] initWithFormat: @"/sbin/route add -net %@ %@", rule, gateway];
    runCommandScript(cmd);
}

-(void) routeDelete:(NSString*) rule gateway:(NSString*) gateway {
    if (rule == NULL || gateway == NULL) {
        return;
    }
    NSString* cmd = [[NSString alloc] initWithFormat: @"/sbin/route delete -net %@ %@", rule, gateway];
    runCommandScript(cmd);
}

-(NSString*) getRouteGateway:(NSString*) rule {
    if (rule == NULL) {
        rule = @"default";
    }
    NSString* cmd = [[NSString alloc] initWithFormat: @"/sbin/route -n get %@ | /usr/bin/grep 'gateway' | /usr/bin/awk '{print $2}'", rule];
    NSString* outStr = [runCommandScript(cmd) stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return outStr;
}

-(NSString*) getDefaultRouteGateway {
    return [self getRouteGateway:@"default"];
}

NSString* runCommandScript(NSString* script)
{
    
    NSString *scriptSource = [NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges", script];
    NSAppleScript *appleScript = [[NSAppleScript new] initWithSource:scriptSource];
    
    NSAppleEventDescriptor *eventDescriptor = nil;
    NSBundle *bunlde = [NSBundle mainBundle];
    eventDescriptor = [appleScript executeAndReturnError:nil];
    if (eventDescriptor)
    {
        return [eventDescriptor stringValue];
    }
    
    return @"";
    
    
   
//    NSLog(@"runCommandScript: %@", script);
//    NSPipe* pipe = [NSPipe pipe];
//    NSTask* task = [[NSTask alloc] init];
//    [task setLaunchPath: @"/bin/sh"];
//    [task setArguments:@[@"-c",[NSString stringWithFormat:@"%@", script]]];
//    [task setStandardOutput:pipe];
//    NSFileHandle* file = [pipe fileHandleForReading];
//    [task launch];
//    return [[NSString alloc] initWithData:[file readDataToEndOfFile] encoding:NSUTF8StringEncoding];
    
}



@end

