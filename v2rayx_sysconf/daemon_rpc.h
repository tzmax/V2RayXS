#ifndef daemon_rpc_h
#define daemon_rpc_h

#import <Foundation/Foundation.h>

NSDictionary* daemonRPCMakeRequest(NSString* command, NSDictionary* payload);
NSString* daemonRPCCommand(NSDictionary* request);
NSDictionary* daemonRPCPayload(NSDictionary* request);

#endif /* daemon_rpc_h */
