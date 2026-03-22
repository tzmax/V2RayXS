#ifndef daemon_service_h
#define daemon_service_h

#import <Foundation/Foundation.h>
#import "control_socket_transport.h"

NSDictionary* daemonServiceStatusPayload(void);
void daemonServiceResetRuntimeState(void);
NSDictionary* daemonServiceHandleCommand(NSArray<NSString*>* arguments,
                                         NSDictionary* (^makeResponseBlock)(BOOL ok, NSString* message, NSDictionary* payload),
                                         BOOL (^startServerBlock)(NSString** errorMessage),
                                         void (^runLoopBlock)(void),
                                         NSDictionary* (^statusPayloadBlock)(void),
                                         void (^resetRuntimeBlock)(void));

#endif /* daemon_service_h */
