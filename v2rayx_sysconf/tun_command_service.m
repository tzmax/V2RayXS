#import <Foundation/Foundation.h>
#import "tun_command_service.h"

NSDictionary* tunCommandServiceHandle(NSArray<NSString*>* arguments,
                                      BOOL (^isExternalFDSessionBlock)(void),
                                      NSDictionary* (^makeResponseBlock)(BOOL ok, NSString* message, NSDictionary* payload),
                                      NSDictionary* (^tunStatusPayloadBlock)(void),
                                      NSDictionary* (^allocateTunFDSessionBlock)(NSString* tunName, int sendSocketFD),
                                      BOOL (^activateExternalTunSessionBlock)(NSString* tunName, NSString** errorMessage),
                                      NSDictionary* (^deactivateExternalTunSessionBlock)(NSString* tunName),
                                      NSDictionary* (^requestActiveSessionBlock)(NSDictionary* request),
                                      void (^syncRuntimeSessionFromBackupBlock)(void),
                                      NSString* (^currentSessionStateBlock)(void),
                                      NSDictionary* (^stopTunSessionBlock)(void),
                                      BOOL (^setupTunSessionBlock)(int localProxyPort, NSString** errorMessage),
                                      BOOL (^startControlSocketServerBlock)(NSString** errorMessage),
                                      NSDictionary* (^onStartSocketFailureBlock)(NSString* errorMessage),
                                      NSDictionary* (^syncWhitelistAfterStartBlock)(void),
                                      void (^runControlSocketLoopBlock)(void),
                                      void (^releaseTunSessionLockBlock)(void)) {
    if (arguments.count < 2) {
        return makeResponseBlock(NO, @"Missing tun subcommand.", nil);
    }
    NSString* subcommand = arguments[1];

    if ([subcommand isEqualToString:@"status"]) {
        return makeResponseBlock(YES, @"Tun session status.", tunStatusPayloadBlock());
    }

    if ([subcommand isEqualToString:@"allocate"]) {
        NSString* tunName = nil;
        NSString* socketFDString = nil;
        if (arguments.count >= 4) {
            tunName = arguments[2];
            socketFDString = arguments[3];
        } else if (arguments.count >= 3) {
            socketFDString = arguments[2];
        }
        int sendSocketFD = -1;
        if (socketFDString.length == 0 || sscanf([socketFDString UTF8String], "%d", &sendSocketFD) != 1 || sendSocketFD < 0) {
            return makeResponseBlock(NO, @"Missing or invalid tun fd transport socket fd.", nil);
        }
        return allocateTunFDSessionBlock(tunName, sendSocketFD);
    }

    if ([subcommand isEqualToString:@"activate"]) {
        if (arguments.count < 3) {
            return makeResponseBlock(NO, @"Missing utun interface name for tun activate.", nil);
        }
        NSString* errorMessage = nil;
        BOOL didActivate = activateExternalTunSessionBlock(arguments[2], &errorMessage);
        return makeResponseBlock(didActivate, didActivate ? @"External tun session activated." : (errorMessage ?: @"Failed to activate external tun session."), didActivate ? tunStatusPayloadBlock() : nil);
    }

    if ([subcommand isEqualToString:@"deactivate"]) {
        NSString* tunName = arguments.count >= 3 ? arguments[2] : nil;
        return deactivateExternalTunSessionBlock(tunName);
    }

    if ([subcommand isEqualToString:@"stop"]) {
        if (isExternalFDSessionBlock()) {
            return makeResponseBlock(NO, @"Use `tun deactivate` for external tun sessions.", nil);
        }
        NSDictionary* response = requestActiveSessionBlock(@{@"cmd": @"stop"});
        if ([response[@"ok"] boolValue]) {
            return response;
        }
        syncRuntimeSessionFromBackupBlock();
        NSString* sessionState = currentSessionStateBlock();
        if (![sessionState isEqualToString:@"inactive"]) {
            return stopTunSessionBlock();
        }
        return makeResponseBlock(NO, response[@"message"] ?: @"No active tun session.", nil);
    }

    if ([subcommand isEqualToString:@"start"]) {
        NSString* errorMessage = nil;
        if (arguments.count < 3) {
            return makeResponseBlock(NO, @"Missing socks port for tun start.", nil);
        }
        int localProxyPort = 0;
        if (sscanf([arguments[2] UTF8String], "%i", &localProxyPort) != 1 || localProxyPort <= 0 || localProxyPort > 65535) {
            return makeResponseBlock(NO, @"Invalid socks port for tun start.", nil);
        }
        if (!setupTunSessionBlock(localProxyPort, &errorMessage)) {
            return makeResponseBlock(NO, errorMessage ?: @"Failed to start tun session.", nil);
        }
        if (!startControlSocketServerBlock(&errorMessage)) {
            return onStartSocketFailureBlock(errorMessage ?: @"Failed to start tun control socket.");
        }
        syncWhitelistAfterStartBlock();
        runControlSocketLoopBlock();
        releaseTunSessionLockBlock();
        return makeResponseBlock(YES, @"Tun session exited.", tunStatusPayloadBlock());
    }

    return makeResponseBlock(NO, @"Unknown tun subcommand.", nil);
}
