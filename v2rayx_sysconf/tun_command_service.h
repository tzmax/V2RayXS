#ifndef tun_command_service_h
#define tun_command_service_h

#import <Foundation/Foundation.h>

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
                                      void (^releaseTunSessionLockBlock)(void));

#endif /* tun_command_service_h */
