#ifndef session_state_h
#define session_state_h

#import <Foundation/Foundation.h>

NSString* currentSessionType(void);
NSString* currentSessionOwner(void);
NSString* currentControlPlane(void);
BOOL canTreatSessionAsActiveResponse(NSDictionary* response);

#endif /* session_state_h */
