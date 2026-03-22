#import <Foundation/Foundation.h>
#import "daemon_service.h"
#import "daemon_state.h"

NSDictionary* daemonServiceStatusPayload(void) {
    return @{
        @"daemon": @"available",
        @"session": daemonStateSessionStatus(),
        @"dataPlaneKind": daemonStateDataPlaneKind(),
        @"tunName": daemonStateTunName(),
        @"leaseId": daemonStateLeaseIdentifier(),
        @"socksPort": daemonStateSocksPort(),
    };
}

void daemonServiceResetRuntimeState(void) {
    daemonStateReset();
}

NSDictionary* daemonServiceHandleCommand(NSArray<NSString*>* arguments,
                                         NSDictionary* (^makeResponseBlock)(BOOL ok, NSString* message, NSDictionary* payload),
                                         BOOL (^startServerBlock)(NSString** errorMessage),
                                         void (^runLoopBlock)(void),
                                         NSDictionary* (^statusPayloadBlock)(void),
                                         void (^resetRuntimeBlock)(void)) {
    if (arguments.count < 2) {
        return makeResponseBlock(NO, @"Missing daemon subcommand.", nil);
    }
    NSString* subcommand = arguments[1];
    if ([subcommand isEqualToString:@"status"]) {
        return makeResponseBlock(YES, @"Daemon status.", statusPayloadBlock != nil ? statusPayloadBlock() : daemonServiceStatusPayload());
    }
    if ([subcommand isEqualToString:@"stop"]) {
        return makeResponseBlock(NO, @"Daemon stop must be handled by the active daemon instance.", nil);
    }
    if (![subcommand isEqualToString:@"run"]) {
        return makeResponseBlock(NO, @"Unknown daemon subcommand.", nil);
    }
    if (resetRuntimeBlock != nil) {
        resetRuntimeBlock();
        daemonServiceResetRuntimeState();
    }
    NSString* errorMessage = nil;
    if (!startServerBlock(&errorMessage)) {
        return makeResponseBlock(NO, errorMessage ?: @"Failed to start daemon socket.", nil);
    }
    if (runLoopBlock != nil) {
        runLoopBlock();
    }
    return makeResponseBlock(YES, @"Daemon exited.", statusPayloadBlock != nil ? statusPayloadBlock() : daemonServiceStatusPayload());
}
