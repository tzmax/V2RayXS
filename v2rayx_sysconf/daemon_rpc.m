#import <Foundation/Foundation.h>
#import "daemon_rpc.h"

NSDictionary* daemonRPCMakeRequest(NSString* command, NSDictionary* payload) {
    return @{
        @"version": @1,
        @"cmd": command ?: @"",
        @"payload": payload ?: @{},
    };
}

NSString* daemonRPCCommand(NSDictionary* request) {
    NSString* command = request[@"cmd"];
    return [command isKindOfClass:[NSString class]] ? command : @"";
}

NSDictionary* daemonRPCPayload(NSDictionary* request) {
    NSDictionary* payload = request[@"payload"];
    return [payload isKindOfClass:[NSDictionary class]] ? payload : @{};
}
