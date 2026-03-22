#import <Foundation/Foundation.h>
#import "session_backup_store.h"
#import "session_state.h"

NSString* currentSessionType(void) {
    NSMutableDictionary* backup = loadRouteBackup();
    NSString* value = backup[ROUTE_BACKUP_SESSION_TYPE_KEY];
    return [value isKindOfClass:[NSString class]] && value.length > 0 ? value : SESSION_TYPE_NONE;
}

NSString* currentSessionOwner(void) {
    NSMutableDictionary* backup = loadRouteBackup();
    NSString* value = backup[ROUTE_BACKUP_SESSION_OWNER_KEY];
    return [value isKindOfClass:[NSString class]] && value.length > 0 ? value : SESSION_OWNER_NONE;
}

NSString* currentControlPlane(void) {
    NSMutableDictionary* backup = loadRouteBackup();
    NSString* value = backup[ROUTE_BACKUP_CONTROL_PLANE_KEY];
    return [value isKindOfClass:[NSString class]] && value.length > 0 ? value : CONTROL_PLANE_NONE;
}

BOOL canTreatSessionAsActiveResponse(NSDictionary* response) {
    if (![response[@"ok"] boolValue]) {
        return NO;
    }
    NSString* session = response[@"session"];
    return [session isKindOfClass:[NSString class]] && ![session isEqualToString:@"inactive"];
}
