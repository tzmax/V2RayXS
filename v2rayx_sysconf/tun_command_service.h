#ifndef tun_command_service_h
#define tun_command_service_h

#import <Foundation/Foundation.h>

NSDictionary* tunCommandServiceHandle(NSArray<NSString*>* arguments,
                                      NSDictionary* (^makeResponseBlock)(BOOL ok, NSString* message, NSDictionary* payload),
                                      NSDictionary* (^statusRequestBlock)(void),
                                      NSDictionary* (^startEmbeddedRequestBlock)(int localProxyPort),
                                      NSDictionary* (^allocateFDRequestBlock)(NSString* preferredTunName, int* receivedFDOut),
                                      NSDictionary* (^activateLeaseRequestBlock)(NSString* leaseId),
                                      NSDictionary* (^stopRequestBlock)(void));

#endif /* tun_command_service_h */
