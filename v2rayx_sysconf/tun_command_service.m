#import <Foundation/Foundation.h>
#import <unistd.h>
#import "tun_command_service.h"

static NSString* lastAllocatedLeaseIdentifier = nil;

NSDictionary* tunCommandServiceHandle(NSArray<NSString*>* arguments,
                                      NSDictionary* (^makeResponseBlock)(BOOL ok, NSString* message, NSDictionary* payload),
                                      NSDictionary* (^statusRequestBlock)(void),
                                      NSDictionary* (^startEmbeddedRequestBlock)(int localProxyPort),
                                      NSDictionary* (^allocateFDRequestBlock)(NSString* preferredTunName, int* receivedFDOut),
                                      NSDictionary* (^activateLeaseRequestBlock)(NSString* leaseId),
                                      NSDictionary* (^stopRequestBlock)(void)) {
    if (arguments.count < 2) {
        return makeResponseBlock(NO, @"Missing tun subcommand.", nil);
    }
    NSString* subcommand = arguments[1];
    NSMutableArray<NSString*>* positionalArguments = [[NSMutableArray alloc] init];
    for (NSUInteger index = 2; index < arguments.count; index++) {
        NSString* argument = arguments[index];
        if (![argument isEqualToString:@"--json"] && ![argument isEqualToString:@"--debug"]) {
            [positionalArguments addObject:argument];
        }
    }

    if ([subcommand isEqualToString:@"status"]) {
        return statusRequestBlock();
    }

    if ([subcommand isEqualToString:@"cleanup"]) {
        return stopRequestBlock();
    }

    if ([subcommand isEqualToString:@"allocate"]) {
        NSString* preferredTunName = nil;
        if (positionalArguments.count >= 1 && [positionalArguments[0] hasPrefix:@"utun"]) {
            preferredTunName = positionalArguments[0];
        }
        int receivedFD = -1;
        NSDictionary* response = allocateFDRequestBlock(preferredTunName, &receivedFD);
        if ([response[@"ok"] boolValue] && receivedFD >= 0) {
            NSString* leaseId = response[@"leaseId"];
            if ([leaseId isKindOfClass:[NSString class]] && leaseId.length > 0) {
                lastAllocatedLeaseIdentifier = leaseId;
            }
            close(receivedFD);
        }
        return response;
    }

    if ([subcommand isEqualToString:@"activate"]) {
        NSString* leaseId = positionalArguments.count >= 1 ? positionalArguments[0] : lastAllocatedLeaseIdentifier;
        return activateLeaseRequestBlock(leaseId);
    }

    if ([subcommand isEqualToString:@"deactivate"]) {
        return stopRequestBlock();
    }

    if ([subcommand isEqualToString:@"stop"]) {
        return stopRequestBlock();
    }

    if ([subcommand isEqualToString:@"start"]) {
        if (arguments.count < 3) {
            return makeResponseBlock(NO, @"Missing socks port for tun start.", nil);
        }
        int localProxyPort = 0;
        if (sscanf([arguments[2] UTF8String], "%i", &localProxyPort) != 1 || localProxyPort <= 0 || localProxyPort > 65535) {
            return makeResponseBlock(NO, @"Invalid socks port for tun start.", nil);
        }
        return startEmbeddedRequestBlock(localProxyPort);
    }

    return makeResponseBlock(NO, @"Unknown tun subcommand.", nil);
}
