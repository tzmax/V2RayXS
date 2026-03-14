//
//  route.m
//  v2rayx_sysconf
//
//  Created by tzmax on 2023/1/23.
//  Copyright © 2023 Project V2Ray. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import "route.h"

static NSString* escapeShellArgument(NSString* value);
static NSString* runCommandScript(NSString* script, NSDictionary** errorInfo);
static BOOL commandSucceeded(NSDictionary* errorInfo);

@implementation SYSRouteHelper : NSObject


-(BOOL) upInterface:(NSString*) interfaceName {
    if (interfaceName == NULL) {
        return NO;
    }
    NSString* escapedInterfaceName = escapeShellArgument(interfaceName);
    NSString* cmd = [[NSString alloc] initWithFormat: @"/sbin/ifconfig %@ up", escapedInterfaceName];
    NSDictionary* errorInfo = nil;
    runCommandScript(cmd, &errorInfo);
    if (!commandSucceeded(errorInfo)) {
        NSLog(@"Failed to bring up interface %@: %@", interfaceName, errorInfo);
        return NO;
    }

    return YES;
}

-(BOOL) routeAdd:(NSString*) rule gateway:(NSString*) gateway {
    if (rule == NULL || gateway == NULL) {
        return NO;
    }
    if (![self isValidGateway:gateway]) {
        NSLog(@"Skip adding route %@ with invalid gateway %@", rule, gateway);
        return NO;
    }
    if ([self hasRoute:rule gateway:gateway]) {
        return YES;
    }

    NSString* escapedRule = escapeShellArgument(rule);
    NSString* escapedGateway = escapeShellArgument(gateway);
    NSString* cmd = [[NSString alloc] initWithFormat: @"/sbin/route add -net %@ %@", escapedRule, escapedGateway];
    NSDictionary* errorInfo = nil;
    runCommandScript(cmd, &errorInfo);
    if (!commandSucceeded(errorInfo) && ![self hasRoute:rule gateway:gateway]) {
        NSLog(@"Failed to add route %@ via %@: %@", rule, gateway, errorInfo);
        return NO;
    }

    return YES;
}

-(BOOL) routeDelete:(NSString*) rule gateway:(NSString*) gateway {
    if (rule == NULL || gateway == NULL) {
        return NO;
    }
    if (![self hasRoute:rule gateway:gateway]) {
        return YES;
    }

    NSString* escapedRule = escapeShellArgument(rule);
    NSString* escapedGateway = escapeShellArgument(gateway);
    NSString* cmd = [[NSString alloc] initWithFormat: @"/sbin/route delete -net %@ %@", escapedRule, escapedGateway];
    NSDictionary* errorInfo = nil;
    runCommandScript(cmd, &errorInfo);
    if (!commandSucceeded(errorInfo) && [self hasRoute:rule gateway:gateway]) {
        NSLog(@"Failed to delete route %@ via %@: %@", rule, gateway, errorInfo);
        return NO;
    }

    return YES;
}

-(NSString*) getRouteGateway:(NSString*) rule {
    if (rule == NULL) {
        rule = @"default";
    }
    NSString* escapedRule = escapeShellArgument(rule);
    NSString* cmd = [[NSString alloc] initWithFormat: @"/sbin/route -n get %@ | /usr/bin/grep 'gateway' | /usr/bin/awk '{print $2}'", escapedRule];
    NSDictionary* errorInfo = nil;
    NSString* outStr = [runCommandScript(cmd, &errorInfo) stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!commandSucceeded(errorInfo) && ![outStr isEqualToString:@""]) {
        NSLog(@"Route lookup for %@ returned output with error: %@", rule, errorInfo);
    }
    return outStr;
}

-(NSString*) getDefaultRouteGateway {
    return [self getRouteGateway:@"default"];
}

-(BOOL) isValidGateway:(NSString*) gateway {
    if (gateway == NULL) {
        return NO;
    }

    NSString* trimmedGateway = [gateway stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmedGateway isEqualToString:@""]) {
        return NO;
    }

    struct in_addr ipv4Addr;
    struct in6_addr ipv6Addr;
    return inet_pton(AF_INET, [trimmedGateway UTF8String], &ipv4Addr) == 1 || inet_pton(AF_INET6, [trimmedGateway UTF8String], &ipv6Addr) == 1;
}

-(BOOL) hasRoute:(NSString*) rule gateway:(NSString*) gateway {
    if (rule == NULL || gateway == NULL) {
        return NO;
    }

    NSString* currentGateway = [self getRouteGateway:rule];
    return currentGateway != NULL && [currentGateway isEqualToString:gateway];
}

static NSString* escapeShellArgument(NSString* value)
{
    NSString* escapedValue = [value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escapedValue = [escapedValue stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return [NSString stringWithFormat:@"\"%@\"", escapedValue];
}

static BOOL commandSucceeded(NSDictionary* errorInfo)
{
    return errorInfo == nil;
}

static NSString* runCommandScript(NSString* script, NSDictionary** errorInfo)
{
    NSString* escapedScript = [script stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escapedScript = [escapedScript stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *scriptSource = [NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges", escapedScript];
    NSAppleScript *appleScript = [[NSAppleScript new] initWithSource:scriptSource];

    NSAppleEventDescriptor *eventDescriptor = nil;
    NSDictionary* executeErrorInfo = nil;
    eventDescriptor = [appleScript executeAndReturnError:&executeErrorInfo];
    if (errorInfo != NULL) {
        *errorInfo = executeErrorInfo;
    }
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
