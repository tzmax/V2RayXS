#ifndef daemon_state_h
#define daemon_state_h

#import <Foundation/Foundation.h>
#import <unistd.h>

extern NSString* const DAEMON_DATA_PLANE_NONE;
extern NSString* const DAEMON_DATA_PLANE_EMBEDDED;
extern NSString* const DAEMON_DATA_PLANE_FD_HANDOFF;

void daemonStateReset(void);
NSString* daemonStateSessionStatus(void);
NSString* daemonStateDataPlaneKind(void);
NSString* daemonStateTunName(void);
NSString* daemonStateLeaseIdentifier(void);
NSString* daemonStateSocksPort(void);
void daemonStateActivateEmbeddedSession(NSString* tunName, NSInteger socksPort);
BOOL daemonStateStoreFDLease(NSString* leaseId, NSString* tunName, int tunFD, NSString** errorMessage);
BOOL daemonStateHasPendingLease(void);
BOOL daemonStateResolvePendingLease(NSString* requestedLeaseId, NSString** tunNameOut, NSString** leaseIdOut, NSString** errorMessage);
void daemonStateActivatePendingLease(void);
void daemonStateClearLease(void);
BOOL daemonStateIsActive(void);

#endif /* daemon_state_h */
