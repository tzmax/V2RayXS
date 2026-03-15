//
//  route.m
//  v2rayx_sysconf
//
//  Created by tzmax on 2023/1/23.
//  Copyright © 2023 Project V2Ray. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <errno.h>
#import <spawn.h>
#import <string.h>
#import <sys/wait.h>
#import <unistd.h>
#import "route.h"

static NSDictionary* runTask(NSString* launchPath, NSArray<NSString*>* arguments);
static BOOL taskSucceeded(NSDictionary* taskResult);
static NSString* taskOutput(NSDictionary* taskResult);
static NSString* taskErrorOutput(NSDictionary* taskResult);
static NSNumber* taskExitCode(NSDictionary* taskResult);
static NSString* readPipeOutput(int fileDescriptor);
static NSArray<NSString*>* routeArgumentsForAction(NSString* action, NSString* target, NSString* gateway, SYSRouteAddressFamily family, BOOL isHost);
static NSArray<NSString*>* routeArgumentsForInterfaceAction(NSString* action, NSString* target, NSString* interfaceName, SYSRouteAddressFamily family, BOOL isHost);
static NSString* normalizedIPAddress(NSString* ipAddress, SYSRouteAddressFamily family);

extern char **environ;

@implementation SYSRouteHelper : NSObject

-(BOOL) upInterface:(NSString*) interfaceName {
    if (interfaceName == NULL) {
        return NO;
    }
    NSDictionary* taskResult = runTask(@"/sbin/ifconfig", @[interfaceName, @"up"]);
    if (!taskSucceeded(taskResult)) {
        NSLog(@"Failed to bring up interface %@ (exit %@): %@", interfaceName, taskExitCode(taskResult), taskErrorOutput(taskResult));
        return NO;
    }

    return YES;
}

-(NSString*) getRouteGateway:(NSString*) rule {
    return [self getRouteGateway:rule family:SYSRouteAddressFamilyIPv4];
}

-(NSString*) getRouteGateway:(NSString*) rule family:(SYSRouteAddressFamily)family {
    if (rule == NULL) {
        rule = @"default";
    }

    NSMutableArray<NSString*>* arguments = [NSMutableArray arrayWithObject:@"-n"];
    if (family == SYSRouteAddressFamilyIPv6) {
        [arguments addObject:@"-inet6"];
    }
    [arguments addObjectsFromArray:@[@"get", rule]];

    NSDictionary* taskResult = runTask(@"/sbin/route", arguments);
    NSString* outStr = [taskOutput(taskResult) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!taskSucceeded(taskResult) && [outStr isEqualToString:@""]) {
        return @"";
    }

    __block NSString* gateway = @"";
    [outStr enumerateLinesUsingBlock:^(NSString * _Nonnull line, BOOL * _Nonnull stop) {
        NSString* trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmedLine hasPrefix:@"gateway:"]) {
            NSString* value = [[trimmedLine substringFromIndex:[@"gateway:" length]] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            gateway = value ?: @"";
            *stop = YES;
        }
    }];

    return gateway;
}

-(NSString*) getDefaultRouteGateway {
    return [self getDefaultRouteGatewayForFamily:SYSRouteAddressFamilyIPv4];
}

-(NSString*) getDefaultRouteGatewayForFamily:(SYSRouteAddressFamily)family {
    return [self getRouteGateway:@"default" family:family];
}

-(NSString*) getRouteInterface:(NSString*) rule family:(SYSRouteAddressFamily)family {
    if (rule == NULL) {
        rule = @"default";
    }

    NSMutableArray<NSString*>* arguments = [NSMutableArray arrayWithObject:@"-n"];
    if (family == SYSRouteAddressFamilyIPv6) {
        [arguments addObject:@"-inet6"];
    }
    [arguments addObjectsFromArray:@[@"get", rule]];

    NSDictionary* taskResult = runTask(@"/sbin/route", arguments);
    NSString* outStr = [taskOutput(taskResult) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!taskSucceeded(taskResult) && [outStr isEqualToString:@""]) {
        return @"";
    }

    __block NSString* routeInterface = @"";
    [outStr enumerateLinesUsingBlock:^(NSString * _Nonnull line, BOOL * _Nonnull stop) {
        NSString* trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmedLine hasPrefix:@"interface:"]) {
            NSString* value = [[trimmedLine substringFromIndex:[@"interface:" length]] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            routeInterface = value ?: @"";
            *stop = YES;
        }
    }];

    return routeInterface;
}

-(NSString*) getDefaultRouteInterfaceForFamily:(SYSRouteAddressFamily)family {
    return [self getRouteInterface:@"default" family:family];
}

-(BOOL) isValidGateway:(NSString*) gateway {
    return [self isValidIPAddress:gateway family:NULL];
}

-(BOOL) isValidIPAddress:(NSString*) ipAddress family:(SYSRouteAddressFamily*)familyOut {
    if (ipAddress == NULL) {
        return NO;
    }

    NSString* trimmedIPAddress = [ipAddress stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmedIPAddress isEqualToString:@""]) {
        return NO;
    }

    struct in_addr ipv4Addr;
    if (inet_pton(AF_INET, [trimmedIPAddress UTF8String], &ipv4Addr) == 1) {
        if (familyOut != NULL) {
            *familyOut = SYSRouteAddressFamilyIPv4;
        }
        return YES;
    }

    struct in6_addr ipv6Addr;
    if (inet_pton(AF_INET6, [trimmedIPAddress UTF8String], &ipv6Addr) == 1) {
        if (familyOut != NULL) {
            *familyOut = SYSRouteAddressFamilyIPv6;
        }
        return YES;
    }

    return NO;
}

-(BOOL) hasRoute:(NSString*) rule gateway:(NSString*) gateway {
    return [self hasDefaultRouteViaGateway:gateway family:SYSRouteAddressFamilyIPv4] && [rule isEqualToString:@"default"];
}

-(BOOL) hasDefaultRouteViaGateway:(NSString*) gateway family:(SYSRouteAddressFamily)family {
    NSString* currentGateway = [self getDefaultRouteGatewayForFamily:family];
    return currentGateway != NULL && [currentGateway isEqualToString:gateway];
}

-(BOOL) hasHostRouteToDestination:(NSString*) destination gateway:(NSString*) gateway family:(SYSRouteAddressFamily)family {
    if (destination == NULL || gateway == NULL) {
        return NO;
    }
    NSString* currentGateway = [self getRouteGateway:destination family:family];
    return currentGateway != NULL && [currentGateway isEqualToString:gateway];
}

-(BOOL) routeAdd:(NSString*) rule gateway:(NSString*) gateway {
    return [self addDefaultRouteViaGateway:gateway family:SYSRouteAddressFamilyIPv4] && [rule isEqualToString:@"default"];
}

-(BOOL) routeDelete:(NSString*) rule gateway:(NSString*) gateway {
    return [self deleteDefaultRouteViaGateway:gateway family:SYSRouteAddressFamilyIPv4] && [rule isEqualToString:@"default"];
}

-(BOOL) addDefaultRouteViaGateway:(NSString*) gateway family:(SYSRouteAddressFamily)family {
    if (![self isValidGateway:gateway]) {
        return NO;
    }
    if ([self hasDefaultRouteViaGateway:gateway family:family]) {
        return YES;
    }
    NSDictionary* taskResult = runTask(@"/sbin/route", routeArgumentsForAction(@"add", @"default", gateway, family, NO));
    if (!taskSucceeded(taskResult) && ![self hasDefaultRouteViaGateway:gateway family:family]) {
        NSLog(@"Failed to add default route via %@ (exit %@): %@", gateway, taskExitCode(taskResult), taskErrorOutput(taskResult));
        return NO;
    }
    return YES;
}

-(BOOL) deleteDefaultRouteViaGateway:(NSString*) gateway family:(SYSRouteAddressFamily)family {
    if (![self hasDefaultRouteViaGateway:gateway family:family]) {
        return YES;
    }
    NSDictionary* taskResult = runTask(@"/sbin/route", routeArgumentsForAction(@"delete", @"default", gateway, family, NO));
    if (!taskSucceeded(taskResult) && [self hasDefaultRouteViaGateway:gateway family:family]) {
        NSLog(@"Failed to delete default route via %@ (exit %@): %@", gateway, taskExitCode(taskResult), taskErrorOutput(taskResult));
        return NO;
    }
    return YES;
}

-(BOOL) deleteDefaultRouteForFamily:(SYSRouteAddressFamily)family {
    NSDictionary* taskResult = runTask(@"/sbin/route", routeArgumentsForAction(@"delete", @"default", @"0.0.0.0", family, NO));
    if (taskSucceeded(taskResult)) {
        return YES;
    }

    NSString* taskError = taskErrorOutput(taskResult);
    if ([taskError containsString:@"not in table"] || [taskError containsString:@"No such process"] || [taskError containsString:@"not found"]) {
        return YES;
    }

    NSString* currentGateway = [self getDefaultRouteGatewayForFamily:family];
    NSString* currentInterface = [self getDefaultRouteInterfaceForFamily:family];
    return currentGateway.length == 0 && currentInterface.length == 0;
}

-(BOOL) hasDefaultRouteViaInterface:(NSString*) interfaceName family:(SYSRouteAddressFamily)family {
    if (interfaceName == NULL || [interfaceName length] == 0) {
        return NO;
    }
    NSMutableArray<NSString*>* arguments = [NSMutableArray arrayWithObject:@"-n"];
    if (family == SYSRouteAddressFamilyIPv6) {
        [arguments addObject:@"-inet6"];
    }
    [arguments addObjectsFromArray:@[@"get", @"default"]];
    NSDictionary* taskResult = runTask(@"/sbin/route", arguments);
    NSString* outStr = [taskOutput(taskResult) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!taskSucceeded(taskResult) && [outStr isEqualToString:@""]) {
        return NO;
    }
    __block BOOL matched = NO;
    [outStr enumerateLinesUsingBlock:^(NSString * _Nonnull line, BOOL * _Nonnull stop) {
        NSString* trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmedLine hasPrefix:@"interface:"]) {
            NSString* value = [[trimmedLine substringFromIndex:[@"interface:" length]] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            matched = [value isEqualToString:interfaceName];
            *stop = YES;
        }
    }];
    return matched;
}

-(BOOL) addDefaultRouteViaInterface:(NSString*) interfaceName family:(SYSRouteAddressFamily)family {
    if (interfaceName == NULL || [interfaceName length] == 0) {
        return NO;
    }
    if ([self hasDefaultRouteViaInterface:interfaceName family:family]) {
        return YES;
    }
    NSDictionary* taskResult = runTask(@"/sbin/route", routeArgumentsForInterfaceAction(@"add", @"default", interfaceName, family, NO));
    if (!taskSucceeded(taskResult) && ![self hasDefaultRouteViaInterface:interfaceName family:family]) {
        NSLog(@"Failed to add default route via interface %@ (exit %@): %@", interfaceName, taskExitCode(taskResult), taskErrorOutput(taskResult));
        return NO;
    }
    return YES;
}

-(BOOL) deleteDefaultRouteViaInterface:(NSString*) interfaceName family:(SYSRouteAddressFamily)family {
    if (interfaceName == NULL || [interfaceName length] == 0) {
        return NO;
    }
    if (![self hasDefaultRouteViaInterface:interfaceName family:family]) {
        return YES;
    }
    NSDictionary* taskResult = runTask(@"/sbin/route", routeArgumentsForInterfaceAction(@"delete", @"default", interfaceName, family, NO));
    if (!taskSucceeded(taskResult) && [self hasDefaultRouteViaInterface:interfaceName family:family]) {
        NSLog(@"Failed to delete default route via interface %@ (exit %@): %@", interfaceName, taskExitCode(taskResult), taskErrorOutput(taskResult));
        return NO;
    }
    return YES;
}

-(BOOL) addHostRouteToDestination:(NSString*) destination gateway:(NSString*) gateway family:(SYSRouteAddressFamily)family {
    if (destination == NULL || gateway == NULL) {
        return NO;
    }
    NSString* normalizedDestination = normalizedIPAddress(destination, family);
    if (normalizedDestination == NULL || ![self isValidGateway:gateway]) {
        return NO;
    }
    if ([self hasHostRouteToDestination:normalizedDestination gateway:gateway family:family]) {
        return YES;
    }
    NSDictionary* taskResult = runTask(@"/sbin/route", routeArgumentsForAction(@"add", normalizedDestination, gateway, family, YES));
    if (!taskSucceeded(taskResult) && ![self hasHostRouteToDestination:normalizedDestination gateway:gateway family:family]) {
        NSLog(@"Failed to add host route %@ via %@ (exit %@): %@", normalizedDestination, gateway, taskExitCode(taskResult), taskErrorOutput(taskResult));
        return NO;
    }
    return YES;
}

-(BOOL) deleteHostRouteToDestination:(NSString*) destination gateway:(NSString*) gateway family:(SYSRouteAddressFamily)family {
    if (destination == NULL || gateway == NULL) {
        return NO;
    }
    NSString* normalizedDestination = normalizedIPAddress(destination, family);
    if (normalizedDestination == NULL) {
        return NO;
    }
    if (![self hasHostRouteToDestination:normalizedDestination gateway:gateway family:family]) {
        return YES;
    }
    NSDictionary* taskResult = runTask(@"/sbin/route", routeArgumentsForAction(@"delete", normalizedDestination, gateway, family, YES));
    if (!taskSucceeded(taskResult) && [self hasHostRouteToDestination:normalizedDestination gateway:gateway family:family]) {
        NSLog(@"Failed to delete host route %@ via %@ (exit %@): %@", normalizedDestination, gateway, taskExitCode(taskResult), taskErrorOutput(taskResult));
        return NO;
    }
    return YES;
}

-(BOOL) addHostRouteToDestination:(NSString*) destination interface:(NSString*) interfaceName family:(SYSRouteAddressFamily)family {
    if (destination == NULL || interfaceName == NULL || [interfaceName length] == 0) {
        return NO;
    }
    NSString* normalizedDestination = normalizedIPAddress(destination, family);
    if (normalizedDestination == NULL) {
        return NO;
    }
    if ([self hasHostRouteToDestination:normalizedDestination gateway:interfaceName family:family]) {
        return YES;
    }
    NSDictionary* taskResult = runTask(@"/sbin/route", routeArgumentsForInterfaceAction(@"add", normalizedDestination, interfaceName, family, YES));
    if (!taskSucceeded(taskResult)) {
        NSString* currentInterface = [self getRouteInterface:normalizedDestination family:family];
        if (![currentInterface isEqualToString:interfaceName]) {
            NSLog(@"Failed to add host route %@ via interface %@ (exit %@): %@", normalizedDestination, interfaceName, taskExitCode(taskResult), taskErrorOutput(taskResult));
            return NO;
        }
    }
    return YES;
}

-(BOOL) deleteHostRouteToDestination:(NSString*) destination interface:(NSString*) interfaceName family:(SYSRouteAddressFamily)family {
    if (destination == NULL || interfaceName == NULL || [interfaceName length] == 0) {
        return NO;
    }
    NSString* normalizedDestination = normalizedIPAddress(destination, family);
    if (normalizedDestination == NULL) {
        return NO;
    }
    NSString* currentInterface = [self getRouteInterface:normalizedDestination family:family];
    if (![currentInterface isEqualToString:interfaceName]) {
        return YES;
    }
    NSDictionary* taskResult = runTask(@"/sbin/route", routeArgumentsForInterfaceAction(@"delete", normalizedDestination, interfaceName, family, YES));
    if (!taskSucceeded(taskResult)) {
        NSString* updatedInterface = [self getRouteInterface:normalizedDestination family:family];
        if ([updatedInterface isEqualToString:interfaceName]) {
            NSLog(@"Failed to delete host route %@ via interface %@ (exit %@): %@", normalizedDestination, interfaceName, taskExitCode(taskResult), taskErrorOutput(taskResult));
            return NO;
        }
    }
    return YES;
}

@end

static NSArray<NSString*>* routeArgumentsForAction(NSString* action, NSString* target, NSString* gateway, SYSRouteAddressFamily family, BOOL isHost)
{
    NSMutableArray<NSString*>* arguments = [[NSMutableArray alloc] init];
    [arguments addObject:action];
    if (family == SYSRouteAddressFamilyIPv6) {
        [arguments addObject:@"-inet6"];
    }
    [arguments addObject:(isHost ? @"-host" : @"-net")];
    [arguments addObject:target];
    [arguments addObject:gateway];
    return arguments;
}

static NSArray<NSString*>* routeArgumentsForInterfaceAction(NSString* action, NSString* target, NSString* interfaceName, SYSRouteAddressFamily family, BOOL isHost)
{
    NSMutableArray<NSString*>* arguments = [[NSMutableArray alloc] init];
    [arguments addObject:action];
    if (family == SYSRouteAddressFamilyIPv6) {
        [arguments addObject:@"-inet6"];
    }
    [arguments addObject:(isHost ? @"-host" : @"-net")];
    [arguments addObject:target];
    [arguments addObject:@"-iface"];
    [arguments addObject:interfaceName];
    return arguments;
}

static NSString* normalizedIPAddress(NSString* ipAddress, SYSRouteAddressFamily family)
{
    if (ipAddress == NULL) {
        return nil;
    }
    NSString* trimmedIPAddress = [ipAddress stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmedIPAddress isEqualToString:@""]) {
        return nil;
    }

    char buffer[INET6_ADDRSTRLEN] = {0};
    if (family == SYSRouteAddressFamilyIPv4) {
        struct in_addr ipv4Addr;
        if (inet_pton(AF_INET, [trimmedIPAddress UTF8String], &ipv4Addr) != 1) {
            return nil;
        }
        if (inet_ntop(AF_INET, &ipv4Addr, buffer, sizeof(buffer)) == NULL) {
            return nil;
        }
    } else {
        struct in6_addr ipv6Addr;
        if (inet_pton(AF_INET6, [trimmedIPAddress UTF8String], &ipv6Addr) != 1) {
            return nil;
        }
        if (inet_ntop(AF_INET6, &ipv6Addr, buffer, sizeof(buffer)) == NULL) {
            return nil;
        }
    }

    return [NSString stringWithUTF8String:buffer];
}

static NSDictionary* runTask(NSString* launchPath, NSArray<NSString*>* arguments)
{
    int stdoutPipe[2] = {-1, -1};
    int stderrPipe[2] = {-1, -1};
    if (pipe(stdoutPipe) != 0 || pipe(stderrPipe) != 0) {
        if (stdoutPipe[0] != -1) {
            close(stdoutPipe[0]);
        }
        if (stdoutPipe[1] != -1) {
            close(stdoutPipe[1]);
        }
        if (stderrPipe[0] != -1) {
            close(stderrPipe[0]);
        }
        if (stderrPipe[1] != -1) {
            close(stderrPipe[1]);
        }
        return @{
            @"stdout": @"",
            @"stderr": @"Failed to create pipes for task",
            @"exitCode": @(-1),
        };
    }

    posix_spawn_file_actions_t fileActions;
    posix_spawn_file_actions_init(&fileActions);
    posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0]);
    posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0]);
    posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[1]);
    posix_spawn_file_actions_addclose(&fileActions, stderrPipe[1]);

    NSUInteger argCount = [arguments count] + 2;
    char** argv = calloc(argCount, sizeof(char*));
    if (argv == NULL) {
        posix_spawn_file_actions_destroy(&fileActions);
        close(stdoutPipe[0]);
        close(stdoutPipe[1]);
        close(stderrPipe[0]);
        close(stderrPipe[1]);
        return @{
            @"stdout": @"",
            @"stderr": @"Failed to allocate task arguments",
            @"exitCode": @(-1),
        };
    }

    argv[0] = (char*)[launchPath fileSystemRepresentation];
    for (NSUInteger index = 0; index < [arguments count]; index++) {
        argv[index + 1] = (char*)[[arguments objectAtIndex:index] UTF8String];
    }
    argv[argCount - 1] = NULL;

    pid_t pid = 0;
    int spawnStatus = posix_spawn(&pid, [launchPath fileSystemRepresentation], &fileActions, NULL, argv, environ);
    free(argv);
    posix_spawn_file_actions_destroy(&fileActions);

    close(stdoutPipe[1]);
    close(stderrPipe[1]);

    if (spawnStatus != 0) {
        NSString* stdoutString = readPipeOutput(stdoutPipe[0]);
        NSString* stderrString = readPipeOutput(stderrPipe[0]);
        close(stdoutPipe[0]);
        close(stderrPipe[0]);
        NSString* spawnError = [NSString stringWithUTF8String:strerror(spawnStatus)] ?: @"Failed to spawn task";
        NSString* combinedError = [stderrString isEqualToString:@""] ? spawnError : [NSString stringWithFormat:@"%@ (%@)", stderrString, spawnError];
        return @{
            @"stdout": stdoutString,
            @"stderr": combinedError,
            @"exitCode": @(spawnStatus),
        };
    }

    NSString* stdoutString = readPipeOutput(stdoutPipe[0]);
    NSString* stderrString = readPipeOutput(stderrPipe[0]);
    close(stdoutPipe[0]);
    close(stderrPipe[0]);

    int waitStatus = 0;
    if (waitpid(pid, &waitStatus, 0) == -1) {
        NSString* waitError = [NSString stringWithUTF8String:strerror(errno)] ?: @"waitpid failed";
        return @{
            @"stdout": stdoutString,
            @"stderr": waitError,
            @"exitCode": @(-1),
        };
    }

    int exitCode = -1;
    if (WIFEXITED(waitStatus)) {
        exitCode = WEXITSTATUS(waitStatus);
    } else if (WIFSIGNALED(waitStatus)) {
        exitCode = 128 + WTERMSIG(waitStatus);
    }

    return @{
        @"stdout": stdoutString,
        @"stderr": stderrString,
        @"exitCode": @(exitCode),
    };
}

static BOOL taskSucceeded(NSDictionary* taskResult)
{
    return [taskExitCode(taskResult) intValue] == 0;
}

static NSString* taskOutput(NSDictionary* taskResult)
{
    return taskResult[@"stdout"] ?: @"";
}

static NSString* taskErrorOutput(NSDictionary* taskResult)
{
    return taskResult[@"stderr"] ?: @"";
}

static NSNumber* taskExitCode(NSDictionary* taskResult)
{
    return taskResult[@"exitCode"] ?: @(1);
}

static NSString* readPipeOutput(int fileDescriptor)
{
    NSMutableData* outputData = [[NSMutableData alloc] init];
    uint8_t buffer[4096];
    ssize_t bytesRead = 0;
    while ((bytesRead = read(fileDescriptor, buffer, sizeof(buffer))) > 0) {
        [outputData appendBytes:buffer length:(NSUInteger)bytesRead];
    }

    NSString* output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
    if (output == NULL) {
        output = [[NSString alloc] initWithData:outputData encoding:NSISOLatin1StringEncoding];
    }
    return output ?: @"";
}
