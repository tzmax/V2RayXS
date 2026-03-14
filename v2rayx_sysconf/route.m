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

    NSDictionary* taskResult = runTask(@"/sbin/route", @[@"add", @"-net", rule, gateway]);
    if (!taskSucceeded(taskResult) && ![self hasRoute:rule gateway:gateway]) {
        NSLog(@"Failed to add route %@ via %@ (exit %@): %@", rule, gateway, taskExitCode(taskResult), taskErrorOutput(taskResult));
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

    NSDictionary* taskResult = runTask(@"/sbin/route", @[@"delete", @"-net", rule, gateway]);
    if (!taskSucceeded(taskResult) && [self hasRoute:rule gateway:gateway]) {
        NSLog(@"Failed to delete route %@ via %@ (exit %@): %@", rule, gateway, taskExitCode(taskResult), taskErrorOutput(taskResult));
        return NO;
    }

    return YES;
}

-(NSString*) getRouteGateway:(NSString*) rule {
    if (rule == NULL) {
        rule = @"default";
    }
    NSDictionary* taskResult = runTask(@"/sbin/route", @[@"-n", @"get", rule]);
    NSString* outStr = [taskOutput(taskResult) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!taskSucceeded(taskResult) && [outStr isEqualToString:@""]) {
        NSLog(@"Route lookup for %@ failed (exit %@): %@", rule, taskExitCode(taskResult), taskErrorOutput(taskResult));
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

    if ([gateway isEqualToString:@""] && ![outStr isEqualToString:@""]) {
        NSLog(@"Route lookup for %@ did not return gateway in output: %@", rule, outStr);
    }

    return gateway;
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



@end
